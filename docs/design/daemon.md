# `packetwyrmd` design

`packetwyrmd` is the userspace daemon that owns control / management of
all AS02MC04 cards in a host. It exposes a local Unix-socket API
consumed by `pktwyrm`, exports stats, programs the FPGAs, and shovels
slow-path packets between FPGA punt rings and Linux TAP devices.

## Process model

A single `packetwyrmd` process per host. It is built around an event
loop (`epoll`) with a small number of long-running threads:

- **main thread** &mdash; event loop, control socket, CLI / IPC, config
  reload, orchestration.
- **card workers** &mdash; one thread per card, owning that card's BAR
  region, slow-path rings and stats polling. No card-to-card sharing
  except through the main thread.
- **host packet plane** &mdash; one or more threads that bridge TAP fds
  to per-card slow-path rings. May be merged with card workers if
  CPU pressure permits.
- **stats aggregator** &mdash; thread (or main-thread timer) that
  snapshots each card's stats and merges them into the global view.

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
- YAML config load + validation via `libpacketwyrm`.
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
   on the same card. `latency_valid = true`.
3. Cross-card flow: program a TX flow row on the TX card, an RX
   classifier rule + RX-only flow row (no generator) on the RX card.
   `latency_valid = false` regardless of YAML `latency: true`.
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

Both directions are live on the real card as of Phase 3: the BAR
backend implements `slow_path_rx` (draining the punt window,
`pw_punt_rx_window` @ 0x1000) and `slow_path_tx` (the inject window,
`pw_inject_tx_window` @ 0x0D00), and `pw_host_plane` calls both. The
FPGA→host direction is HW-validated; the host→FPGA inject path is
HW-validated at the backend op level (`pw_phase3_inject` round-trip).

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
| `flow.list`          | global flow table snapshot                    |
| `flow.start`/`stop`  | per-flow lifecycle                            |
| `test.arm/start/stop/snapshot` | tester-wide lifecycle               |
| `stats.snapshot`     | aggregated stats (filterable)                 |
| `hist.read`          | per-flow latency histogram                    |
| `classifier.dump`    | debug dump of per-card classifier             |
| `debug.regs`         | raw register read window                      |
| `card.reset/disable/enable` | card-level lifecycle                   |

All RPCs are idempotent where it makes sense. Unauthenticated for
Phase 0; access is gated by socket permissions.

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
