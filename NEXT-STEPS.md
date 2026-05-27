# NEXT-STEPS — handoff to the next agent

This is the agent-to-agent baton. Read top to bottom; everything you
need to keep moving is here or one link away.

## Where the tree is right now

Branch: `claude/brave-bohr-ha75N` (all work pushed). Author identity
already configured for `kazubu@jtime.net`.

Latest commit graph (tip first):

```
597e976 Phase 11 starting point: kernel netdev driver skeleton + scoping doc
666bdcb e2e: shell smoke test launching packetwyrmd, hitting every RPC
3327a73 pktwyrm: pretty table for `flow stats`, with --watch / --json / --flow
b22d017 BAR backend: functional classifier/flow/stats/histogram window ops
6bb84d7 Phase 2 sim: wide <-> 64-bit AXIS serializer / deserializer + tb
5e8390a ci: GitHub Actions for host build/test + RTL sim + lint
1e089b3 docs: CHANGELOG, RPC protocol reference, getting-started guide
20d8aed hist: per-flow latency histogram RPC + pretty-printed CLI
e3929f4 test orchestration: pktwyrm test arm|start|stop and matching RPCs
c9916af packetwyrmd: per-flow stats RPC + `pktwyrm flow stats`
de0b43f parser+classifier: IPv6 support (src/dst, NH, is_ipv6/is_icmp6)
cf0dd83 container-frr example: netns + TAP recipe for a routing daemon
4cd7bdc Packaging: systemd unit, sysusers, tmpfiles, `make install`
843ae2e packetwyrmd: flow lifecycle RPCs + initial program push
ad37bef packetwyrmd: Prometheus /metrics exporter on -p PORT
250760f parser+classifier: QinQ, TCP/UDP unified L4 ports, protocol class flags
55adb5b pktwyrm: pretty-printed `stats` subcommand + README sweep
d6bcf44 packetwyrmd: control socket + JSON RPC; pktwyrm rpc subcommand
f62c47d pw_flow_gen: replace gap_cycles with proper token-bucket rate limit
9aa1f47 packetwyrmd: full event loop with TAPs + host_plane + per-card backends
e57d28c Phase 3 enhancement: per-flow latency stats + power-of-two histogram
2afaf4a Phase 5 sim: TAP API + host packet plane + slow-path FIFO
7cb836c sim: extend data-plane testbench with VLAN / FORWARD_PORT / OOO scenarios
c3a6814 Phase 3 RTL skeleton: end-to-end data plane that passes packets in sim
dd5a478 Phase 4: PCI discovery + real BAR-mmap card backend
5b6e6f6 Phase 0.5: settle PCI vendor / device IDs
d858e39 fpga/as02mc04: real pinout from Essenceia + Taxi reverse engineering
feec1e2 fpga/as02mc04: Phase 1 Vivado project skeleton + bring-up checklist
557779a rtl/shared: Phase 1 RTL primitives (CSR, heartbeat, timestamp)
4372a9d packetwyrmd / pktwyrm / unit tests / build system / example configs
09c4038 libpacketwyrm: data model, YAML loader, flow compiler, fake backend
6e44b7a Phase 0: repository skeleton and design docs
```

## Test surface (all green at handoff)

| Command                       | Result                                |
|-------------------------------|---------------------------------------|
| `make -C sw test`             | **154 / 154** unit assertions         |
| `make -C sw e2e`              | **15 / 15** daemon ↔ CLI checks       |
| `make -C sim sim_all`         | **38 / 38** data plane + **16 / 16** AXIS serial |
| `make -C fpga/as02mc04 lint`  | clean (Verilator + Xilinx blackbox)   |
| `make -C kernel`              | builds with `linux-headers-$(uname -r)` |
| `make -C sw install DESTDIR=…`| stages binaries + service + udev      |

GitHub Actions workflow (`.github/workflows/ci.yml`) runs the host
job (`make + make test + make e2e + staged install`) and the
rtl-sim job (`make sim_all` + AS02MC04 lint).

## What's working today (no FPGA required)

- `packetwyrmd` is a complete, hardened-ish long-running daemon:
  per-card backend open (BAR → fake fallback), Linux TAP creation
  via `pw_tap_*`, `pw_host_plane` punt↔TAP bridge, JSON RPC on a
  Unix socket, Prometheus `/metrics` exporter, systemd unit ready
  to install.
- `pktwyrm` offline commands work on YAML; online commands talk
  to a running daemon: `rpc`, `stats`, `flow {show,start,stop,stats}`,
  `test {arm,start,stop}`, `hist latency --flow N`.
- Phase 3 RTL is a functional packet data plane in simulation: parser
  (Ethernet / VLAN / QinQ / IPv4 / IPv6 / TCP / UDP / test header),
  classifier with priority + per-field masks, test_rx_checker
  (loss / dup / OOO / latency histogram), flow_gen with Q16.16
  token-bucket rate, AXIS serializer/deserializer ↔ 64-bit MAC bus.
- Wire-format `pwfpga_*` structs are `__attribute__((packed))` and
  the BAR backend implements full classifier / flow / stats /
  histogram window ops against the documented layout.
- AS02MC04 Phase 1 Vivado project ships real pin assignments
  (from Essenceia + Taxi reverse engineering) and a JTAG / OpenOCD
  bring-up recipe.

## Documentation roadmap

Start a new contributor here:

1. `README.md` &mdash; what the project is, Status table per phase,
   "Try it" recipe.
2. `docs/guides/getting-started.md` &mdash; 5-minute walkthrough.
3. `docs/design/architecture.md` &mdash; the big picture.
4. `docs/design/rpc-protocol.md` &mdash; daemon ↔ CLI wire spec.
5. `docs/design/csr-map.md` &mdash; BAR layout the host backend and
   future RTL share.
6. `CHANGELOG.md` &mdash; ground truth for "what's working".

Per-phase plans live under `docs/phases/`. Per-board docs live
under `fpga/<board>/`.

## Open TODO (priority order)

These are the items the next agent should pick up next, in the order
the user has been asking for. Each carries enough notes that work
can begin without re-reading the whole conversation.

### 1. Phase 3 RTL: integrate the CSR window into `pw_csr_*`

**Why.** Today `pw_csr_min` exposes only identity / global control /
timestamp. The host BAR backend (commit `b22d017`) writes the
documented `PWFPGA_WIN_CLASSIFIER` / `PWFPGA_WIN_FLOW_TABLE` /
`PWFPGA_WIN_STATS_SNAPSHOT` / `PWFPGA_WIN_HISTOGRAM` windows but
*nothing in the RTL listens*. The data plane in `pw_data_plane.sv`
still takes `cls_table_i` as a top-level parameter port and the
test_rx_checker counters never leave the module.

**Concrete work.**

- New RTL: `rtl/shared/pw_csr_window.sv`. Implements a windowed
  table-slot interface: address register, data registers, commit bit.
  Internally it stores a double-buffered shadow row (write-1-to-
  commit). Parameters: `WIN_BASE`, `WIN_STRIDE`, `WIN_DEPTH`,
  `ROW_BYTES`, `COMMIT_OFFSET`.
- Instantiate it three times inside `pw_csr_min` (or a new
  `pw_csr_full.sv`): classifier (8 rows × 128 B), flow (8 rows ×
  128 B), stats snapshot (read-only, populated by the data
  plane on `STATS_SNAPSHOT_TRIGGER`).
- Wire `cls_table_i` of `pw_data_plane` to the classifier window's
  committed view.
- Add the test_rx_checker outputs (`flow_rx`, `flow_lost`, …,
  `flow_hist`) to the snapshot window. On trigger, copy the
  current per-flow counters into the shadow region.
- Histogram: write the per-flow bucket array into
  `PWFPGA_WIN_HISTOGRAM + lfid * PWFPGA_FLOW_HIST_STRIDE`.

**Test plan.** Extend `sim/data_plane_tb` to drive AXI-Lite
writes through the new CSR fabric, then watch the data plane
actually classify accordingly. The wire format is fixed (see
`csr.h`), so the existing host BAR backend round-trips (commit
`b22d017` test cases) already serve as the host-side contract.

**Files of interest.**

- `rtl/shared/pw_pkg.sv` — CSR offsets already there.
- `rtl/shared/pw_csr_min.sv` — current minimal CSR.
- `sw/libpacketwyrm/include/packetwyrm/csr.h` — stride / commit
  register macros.
- `docs/design/csr-map.md` — register / window layout reference.

---

### 2. `pktwyrm load` actually deploys a config to a running daemon

**Why.** Today `pktwyrm load` parses + validates + compiles offline
and stops. The user-facing model in the design docs is "edit YAML,
`pktwyrm load`, the daemon now applies it". The daemon does
`program_backends()` once at startup but nothing reads new YAML
later.

**Concrete work.**

- RPC `config.load`: body = YAML string (or base64'd). Daemon
  parses, validates, compiles into a *new* `pw_program`, then
  swaps it in atomically:
  - stop old flows (`set_flow_enable` false)
  - push new classifier + flow rows to backends
  - new flow_meta becomes the live one
  - on any failure, restore the previous program from a kept
    snapshot.
- `pktwyrm load <config.yaml>` (already a subcommand) gains a
  second mode: if the path looks like a daemon socket OR a
  `--socket` flag is given, ship the YAML over the RPC instead
  of just compiling locally.
- e2e_smoke.sh: add a `config.load` round-trip to the script.

**Watch out.** Live reload while flows are running is genuinely
hard to make atomic. For the first cut, accept "brief moment
where no flows are running" as the cost of correctness.

---

### 3. Per-card worker threads

**Why.** Right now `packetwyrmd` is single-threaded: one poll loop
drains all TAPs and all card host_planes. For more than a couple of
cards, a per-card thread keeps slow-path RX latency stable and
isolates a stuck card.

**Concrete work.**

- One `pthread_create()` per opened card. The thread runs its
  own `poll()` over that card's TAP fds and calls
  `pw_host_plane_step(hp[i], 16)`.
- Main thread keeps the control socket + Prometheus listener.
- Shared state (`prog`, `cards[]`, `hps[i]`) is read-only after
  startup; reload (Step 2) needs an RCU-style swap.
- Stats aggregation reads atomic counters (currently uint64;
  add `_Atomic` or `__atomic_*` if compile lint complains).

---

### 4. JSON Schema for the YAML config

**Why.** The C validator (`pw_config_validate`) returns precise
errors but is hard to extend safely. A JSON Schema mirror gives
editors (vscode-yaml, etc.) inline validation and is a forcing
function for keeping the C validator and the docs in sync.

**Concrete work.**

- Write `sw/libpacketwyrm/schema/packetwyrm.schema.json` based on
  `docs/design/yaml-schema.md`.
- A new unit test runs the example configs against the schema
  (use a small embedded JSON-schema validator, or fall back to
  shelling out to `python3 -c "import jsonschema; ..."` if
  Python is allowed in CI).
- Document in `docs/design/yaml-schema.md` that the schema is
  informative (the C validator is authoritative) but kept in
  sync.

---

### 5. cocotb / Python testbench

**Why.** The current Verilator SV testbench works but writing more
scenarios is tedious. cocotb lets us reuse Scapy frames as input
and Python asserts, dropping the bespoke `make_frame` /
`make_qinq` / `make_v6_test` helpers.

**Concrete work.**

- Add `sim/cocotb/` with cocotb tests for `pw_parser`,
  `pw_classifier`, `pw_test_rx_checker`, `pw_flow_gen`.
- One Python helper builds a frame with Scapy, drives it into
  the DUT, asserts on the output.
- New `make -C sim cocotb` target.

The existing SV testbench stays as the integration test; cocotb
covers the unit level.

---

### 6. TX path RTL to the MAC

**Why.** Phase 3 currently produces `tx_frame[gp]` (wide single
beat). The MAC TX path uses the AXIS serializer from commit
`6bb84d7`, but there is no wiring from `pw_data_plane` → MAC.

**Concrete work.**

- Top-level `pwfpga_top_phase3.sv` (separate from the Phase 1
  bring-up top): instantiates the data plane, the AXIS serializer
  per port, and a MAC TX stub (eventually the real 10G MAC).
- Reverse direction: MAC RX → AXIS deserializer → `rx_frame[gp]`
  feeding the data plane.
- New sim that drives the AXIS RX side with raw frame bytes and
  watches the AXIS TX side, exercising the whole loop.

This is the natural prerequisite for Phase 2 silicon work.

---

## Things the previous agent learned the hard way

These bit us repeatedly; future Verilator / Phase 3 RTL work
should treat them as known hazards.

1. **Verilator silently drops continuous assigns whose
   destination is an unpacked-array element.** Always keep
   internal byte buffers / sticky arrays as *packed* arrays
   (`logic [N-1:0][7:0] hdr;` not `logic [7:0] hdr [0:N-1];`).
   See the long comment in `rtl/phase3/pw_parser.sv`.
2. **`always_comb` sensitivity does not always pick up packed-
   array element changes coming from a continuous-assign chain
   through a packed-byte-array port.** Move the parsing logic
   into an `always_ff @(posedge clk)` with non-blocking assigns
   into a registered output. One cycle of latency is the cost
   of robustness. Comment in `pw_parser.sv` explains.
3. **Procedural assignment to a typedef'd-struct output port
   silently doesn't update the port.** Drive a *local* `logic`
   register and `assign port = local`.
4. **Verilator can't NBA-in-for-loop to an unpacked array.**
   Initialise via an `initial` block (`pw_test_rx_checker.sv`
   does this for the histogram).
5. **The `// Verilator` string in a comment at file start
   triggers an "unknown verilator comment" parse error.** Pick
   any other wording.

## Sanity ritual before pushing

```sh
make -C sw test
make -C sw e2e
make -C sim sim_all
make -C fpga/as02mc04 lint
```

If any of these regresses, the bug is in the diff. The unit tests
have proven sensitive enough to catch packed-struct layout drift
and host_plane wiring mistakes.

Welcome aboard.
