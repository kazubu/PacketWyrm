# `packetwyrmd` design

`packetwyrmd` is the userspace daemon that owns control / management of
all AS02MC04 cards in a host. It exposes a local Unix-socket API
consumed by `pktwyrm`, exports stats, programs the FPGAs, and shovels
slow-path packets between FPGA punt rings and Linux TAP devices.

## Process model

A single `packetwyrmd` process per host. The threading model below is the
TARGET; **as implemented today** it is a main-thread `poll()` loop plus one
worker thread per card (the host packet plane is merged into the card worker,
and stats are snapshotted on the main thread -- there is no separate `epoll`
reactor or stats-aggregator thread yet):

- **main thread** &mdash; `poll()` loop: control socket, CLI / IPC, config
  reload, cross-card latency servo, stats print. (Target: an `epoll` reactor.)
- **card workers** &mdash; one thread per card, owning that card's TAP fds and
  running the host-plane bridge (slow-path punt/inject). No card-to-card
  sharing except through the main thread.
- **host packet plane** &mdash; bridges TAP fds to per-card slow-path rings;
  **today merged into the card worker** (a `pw_host_plane` per card).
- **stats aggregator** &mdash; **today a main-thread snapshot** on the stats
  print / `stats` RPC path (target: a dedicated thread or timer).

Locking — **as implemented today:** each card's host-plane worker owns its TAP
fds and runs independently; control RPCs (including `config.load`'s
compile/program/swap) are handled synchronously on the main thread, which owns
the `pw_config`/`pw_program` pointers, so there is no cross-thread mutation of
them while a worker runs. **Design intent (not yet implemented):** decouple the
two with lock-free SPSC command queues and an RCU-style swap of the global
tables, so a reload never briefly blocks the workers. The current synchronous
swap is fine at today's reload cadence.

## Subsystems

### Global controller (main thread)

- PCIe device discovery via `pw_pci_discover()` in `libpacketwyrm`,
  which walks `/sys/bus/pci/devices/` and matches `vendor` / `device`
  files. No `libpci` dependency.
- `card_id` assignment in stable BDF order (the sysfs walk is sorted
  in `pw_pci_discover()`).
- BAR0 mmap via `pw_bar_backend_open()` &rarr;
  `/sys/bus/pci/devices/<bdf>/resource0`. The same backend interface
  has a path-variant used by unit tests against a tmpfs file. A BAR-open
  failure is a hard error by default; pass `-F`/`--allow-fake` to fall back to
  the no-op fake backend (dev/CI only — it drops all CSR writes, so a real
  deployment would look healthy while transmitting nothing).
- `device_id` / `version` / `capabilities` / port-count read through
  the backend's `card_info` op.

Non-root operation: install `scripts/99-packetwyrm.rules` and add the
operator user to the `packetwyrm` group. Otherwise the daemon needs
root for BAR0 mmap.
- YAML config load + validation via `libpacketwyrm`. The config splits into an
  **environment** part (`-e ENV`, default `/etc/packetwyrm/packetwyrm.yaml`:
  system / cards / logical_interfaces / `secret` — rarely changed) and a **test**
  part (`-t TEST` and `pktwyrm load`: flows / forwards — changed often). A
  combined single file still works via `-e`. `config.load` merges a test-only
  body onto the running environment.
- **Access control:** if the environment config sets `system.secret`, the daemon
  requires it on every control-socket request (constant-time compare; see
  `rpc-protocol.md`). Read permission on the environment config file is thus the
  access gate. No secret configured &rarr; auth off.
- **Environment file editing:** `config.get_raw` returns the `-e` file text
  (secret redacted) and `config.save` writes a validated full config back to
  that path atomically. These back the Web GUI's Environment tab; see
  `rpc-protocol.md`.
- **Web GUI / remote access is a separate process.** `packetwyrmd` itself only
  listens on the Unix control socket (plus the optional Prometheus port). The
  Web GUI and `pktwyrm --host` are served by `packetwyrm-proxyd`, a stateless
  TLS-terminating gateway that relays `POST /api/rpc` onto this socket. Keeping
  it out-of-process means TLS/HTTP work never blocks the daemon's
  control/servo loop. See `web-gui.md`.
- Builds:
  - logical interface map (`logical_if_id` &harr; TAP fd &harr;
    `(card_id, local_port_id, vlan)`),
  - port map (`global_port_id` &harr; `(card_id, local_port_id)`),
  - flow map (`global_flow_id` &rarr; per-card programming).
- Owns test orchestration state machine (`armed`, `running`, ...).

### Card worker

One thread per card. Steady state work:

- Drain slow-path RX ring &rarr; dispatch to the right TAP fd via
  `logical_if_id`.
- Drain per-card TX command queue &rarr; write to FPGA slow-path TX
  ring.
- Periodic stats snapshot (`stats_snapshot_trigger` &rarr; read snapshot
  window).
- Link monitoring; bubble up `link up/down` events.
- Programs classifier / flow tables on instruction from the main
  thread (via SPSC queue).
- Handles fatal error registers (sticky bits, W1C clear).

If a card disappears (BAR read returns all-ones, or PCIe rescan flags
removal), the worker marks the card `degraded` / `failed`, drops its
flows out of the active set, and continues. The daemon does **not**
crash.

### Flow compiler

Lives in `libpacketwyrm`, called from the global controller. Input: a
validated `pw_config`. Output: a list of per-card programming actions
(`pw_card_program`), each containing classifier rows to write, flow
rows to write, and which slots to commit.

Compilation rules:

1. Resolve `tx_global_port` and `rx_global_port` to `(card_id,
   local_port_id)`.
2. Same-card flow: program one TX flow row and one RX classifier rule
   on the same card. `latency_valid = true` (same-card method: exact,
   single FPGA counter).
3. Cross-card flow: program a TX flow row on the TX card, an RX
   classifier rule + RX-only flow row (no generator) on the RX card.
   `latency_valid = false` here is the **method** flag (cross-card), not
   "no latency": cross-card latency IS measured, corrected per flow in
   hardware via the J5 GPIO sync + the per-flow `lat_correction` table
   (the daemon servo maintains each cross-card slot). `flow.stats` reports
   it with `latency_method: "gpio-corrected"`. The servo re-writes each
   cross-card slot's offset every `-S SERVO_MS` (default 10 ms; smaller =
   less ~1.6 ppm-skew residual between updates — ~16 ns at 10 ms, ~1.6 ns
   at 1 ms; the J5 edge refreshes every ~210 µs so below that is moot). It
   reads an edge-coherent offset and skips the write on an incoherent read.
4. Allocate `local_flow_id`s from a per-card free list.
5. Build classifier match keys deterministically: ingress port, VLAN,
   UDP destination port, test magic, `global_flow_id`. Ties are
   broken by priority (lower number = higher priority).

### Classifier compiler

Builds classifier rows for two reasons:

- **Test RX rules** &mdash; emitted by the flow compiler for each
  cross-card or same-card flow's RX side.
- **Punt rules** &mdash; emitted from each logical interface's `punt:`
  block (ARP, ND, LLDP, ICMP, BGP, OSPF, IS-IS), tagged with the
  matching `logical_if_id`.

A small number of low-priority catch-all rules:

- ARP / ND for any logical interface MAC &rarr; `PUNT_TO_HOST`.
- IPv4 / IPv6 destined to a logical interface's IP &rarr;
  `PUNT_TO_HOST`.
- All else &rarr; `DROP`.

### Logical interface manager

Owns TAP creation, naming, MAC programming, MTU, and namespace
movement (when requested by config). Names are built from
`global_port_id` + `vlan_id`:

```
tap-pw-p<global_port>-v<vlan>
```

Each TAP is opened with `IFF_TAP | IFF_NO_PI`; the daemon retains an
fd and adds it to its epoll set. Packets read from the TAP get
prepended with a small descriptor (`logical_if_id`, egress
`local_port_id`, optional VLAN tag) and pushed onto the card worker's
TX queue.

### Host packet plane

The TAP &harr; FPGA bridge.

- **TAP &rarr; FPGA (Linux TX inject):** read from TAP fd, validate /
  rewrite VLAN per logical interface config, enqueue to the right
  card worker's TX ring with a slow-path descriptor.
- **FPGA &rarr; TAP (punt):** card worker reads slow-path RX ring;
  dispatches by `logical_if_id` to the right TAP fd. Optional VLAN
  pop if the logical interface owns the tag.

Backpressure on TAP side: TAP fds are non-blocking. If a TAP would
block, the daemon drops with a counter; control-plane protocols
retransmit. Slow-path packet plane is intentionally not lossless.

Observability: the `tap.stats` RPC (see `rpc-protocol.md`) reports each TAP's
kernel state (name, admin/oper up, IP addresses, netdev rx/tx/dropped) via
`pw_tap_query()` plus the host-plane bridge counters (`to_tap`/`from_tap`
ok+dropped). This surfaces the punt/inject TAPs and their traffic — notably the
auto link-local IPv6 whose ND/MLD loops back to the loopback ports and is counted
there as `rx_unmatched` (informational, not a drop). Shown by the GUI Host-plane
TAPs panel and `pktwyrm tap`.

Both directions are live on the real card as of Phase 3. On the shipped
**DMA bitstream** (`CAP_HAS_DMA`) the backend `slow_path_rx` / `slow_path_tx`
ride the **PCIe-DMA slow path** (`pw_dma_slowpath`, XDMA AXI-Stream), and
`pw_host_plane` calls both — HW-validated end-to-end by the cRPD dual-stack
control plane across the DUT. (On the older non-DMA bitstream the same ops
drive the BAR-polled `pw_punt_rx_window` @ 0x1000 / `pw_inject_tx_window` @
0x0D00 windows instead; those are legacy.)

Implementation: `pw_host_plane` in `libpacketwyrm` is the concrete
data-mover. `pw_tap_open()` / `pw_tap_set_*()` create the TAP
devices via `/dev/net/tun` and ioctl; the host plane binds each
logical interface to its FD and drains both directions on each
`pw_host_plane_step()` call. The fake card backend implements
`slow_path_rx` / `slow_path_tx` so the entire host plane runs in
unit tests against a software model (`make -C sw test`); a real
TAP integration is also covered (Linux kernel TAP device created,
host plane writes a synthesised punt frame to it).

### Stats aggregator

Polls each card on a configurable interval (default 100 ms). Steps:

1. Card worker writes `stats_snapshot_trigger`.
2. Worker reads back the snapshot window into a card-local struct.
3. Pushes the struct to the aggregator via SPSC queue.
4. Aggregator merges into the global view keyed by `global_flow_id`
   and `global_port_id`.
5. Aggregator computes:
   - `lost = sum(card.lost_est)` over flow's RX cards,
   - same for duplicate / out-of-order / sequence_gap,
   - latency / jitter only if **all** RX cards report
     `latency_valid = true` for this flow.

Exports: human table (CLI), JSON, optional Prometheus endpoint.

## IPC: control socket

`packetwyrmd` listens on a Unix socket (default
`/var/run/packetwyrm/packetwyrmd.sock`). `pktwyrm` connects, sends
length-prefixed JSON requests, reads JSON responses. The wire schema
is versioned (`schema_version`).

Initial RPCs:

| RPC                  | Purpose                                       |
|----------------------|-----------------------------------------------|
| `cards.list`         | back `pktwyrm cards`                          |
| `ports.list`         | back `pktwyrm ports`                          |
| `map.show`           | back `pktwyrm map`                            |
| `link.show`          | per-port link / SFP / PCS state               |
| `config.load`        | load + validate + activate a YAML config      |
| `config.get_raw`     | read the env config file (secret redacted)    |
| `config.get_test`    | read the active test config (flows/forwards)  |
| `config.save`        | validate + atomically write the env config    |
| `flow.list`          | global flow table snapshot                    |
| `flow.start`/`stop`  | per-flow lifecycle                            |
| `test.arm/start/stop/snapshot` | tester-wide lifecycle               |
| `stats.snapshot`     | aggregated stats (filterable)                 |
| `hist.read`          | per-flow latency histogram                    |
| `classifier.dump`    | debug dump of per-card classifier             |
| `debug.regs`         | raw register read window                      |
| `card.reset/disable/enable` | card-level lifecycle                   |

All RPCs are idempotent where it makes sense. Access control is the
`system.secret` model described above (constant-time secret check; when no
secret is configured, the Unix-socket file permissions are the ACL). Remote
access adds TLS + the same secret via `packetwyrm-proxyd`.

## Configuration lifecycle

```
                +-> validate -> compile -> stage -> commit -+
   YAML --> parse                                            +-> active
                +----- error (rollback, keep old config) ----+
```

- `parse` accepts YAML and produces a `pw_config`.
- `validate` rejects duplicates, missing references, illegal
  cross-card latency requests, unknown cards.
- `compile` produces per-card `pw_card_program` records.
- `stage` writes classifier / flow rows into the FPGA shadow regions.
  Each table is written to its **full capacity**: the configured entries
  are enabled and every remaining slot is invalidated (flow rows zeroed,
  rules `enable=0`, hash buckets + flow-id-map entries `valid=0`). This is
  what makes a reload that *shrinks* the config safe — the RTL commit only
  copies shadow&rarr;live, so without invalidating the un-written slots the
  old (now-deleted) flows / rules / classifier entries would stay live.
- `commit` toggles the commit bits on each affected card.
- On any failure during `stage`, the daemon rolls back: it restores
  the previous shadow rows and refuses to commit. The previous active
  configuration keeps running.

## Failure modes

- **Card disappears:** worker marks `degraded`, drops the card's flows
  from active, keeps daemon up.
- **TAP creation fails:** config rejected at validate time when
  possible; at runtime, error response + rollback.
- **Slow-path TX backed up:** TAP injection drops with counter
  (`tap_tx_dropped`), no daemon stall.
- **Stats poll falls behind:** the aggregator drops the lagged
  snapshot and logs once per minute; counters are 64-bit so they do
  not wrap silently.
- **YAML reload requests latency on cross-card flow:** rejected at
  validate time.
