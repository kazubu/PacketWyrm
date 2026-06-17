# NEXT-STEPS — handoff to the next agent

This is the agent-to-agent baton. Read top to bottom; everything you
need to keep moving is here or one link away.

> **CURRENT STATE (supersedes the snapshot below).** Phase 3 is done on
> hardware: the 64-bit streaming data plane runs on the AS02MC04 at 32
> flows / 16 classifier rows / 16 latency bins, loss=0 at line rate, with
> a BRAM histogram, egress hardware timestamping, a CSR data-plane
> soft-reset, live SPI-flash write (`pktwyrm flash` / `pw_flash`) and
> in-band ICAP reboot (`pw_reboot`). The full image is flashed as the
> cold-boot image. See `CHANGELOG.md` (Unreleased) for the feature list
> and `docs/design/{csr-map,rtl-modules}.md` for the as-built design. The
> "Where the tree is" / commit-graph / Open-TODO sections below predate
> this work and are kept only for history.
>
> **Remaining / next** (priority): ~~recover timing margin~~ **DONE** —
> the parser key-extract is now 2-stage, WNS +0.003 → +0.020 @156.25 MHz
> (HW-revalidated: 16-flow loopback, 793M frames, loss=0, latency uniform;
> new image flashed as cold-boot). ~~Validate the SAF **FORWARD** path on
> silicon~~ **DONE** — `pw_phase3_forward` on HW (gen[1]→RX0→FWD→SAF→TX0
> →RX1→TEST_RX, frames cross the DAC twice): rx 4.75M, **loss=0**, ooo=0,
> latency uniform (the constant dup=1 / ~27 startup drops are one-time
> pre-commit artifacts). FORWARD egress port is now **host-selectable**
> (`egress_local_port` byte 92 in `pwfpga_classifier_entry`, decoded in
> `pw_classifier_window`; the data plane already routed by the result's
> `egress_port`). ~~Implement the **PUNT/slow-path** to the host~~
> **DONE (RX direction)** — `pw_punt_rx_window` sinks the punt AXIS into a
> CSR-polled frame buffer (PWFPGA_WIN_PUNT_RX); the SAF carries
> `logical_if_id` + ingress port; `bar_slow_path_rx` drains it and the
> daemon routes to TAPs. `sim_punt` + the `sim_top` punt readback cover
> it. ~~host → FPGA `slow_path_tx`~~ **DONE** — `pw_inject_tx_window`
> (CSR frame buffer → AXIS into the egress arbiter) + `bar_slow_path_tx`;
> HW round-trip via `pw_phase3_inject` (inject → DAC → PUNT → read back
> byte-identical). Both slow-path directions now work on silicon, and the
> daemon `host_plane` already calls both `slow_path_rx`/`slow_path_tx`, so
> the TAP ↔ wire bridge is functional end-to-end. Next: optionally move RX
> timestamping to the ingress MAC for absolute accuracy; then multi-card.
> (FORWARD rules now have a YAML/compiler construct — top-level
> `forwards:` -> classifier FORWARD_PORT rows.)

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
| `make -C sw test`             | **164 / 164** unit assertions         |
| `make -C sw e2e`              | **18 / 18** daemon ↔ CLI checks       |
| `make -C sim sim_all`         | **38** dp + **16** axis + **24** cw + **16** fw + **16** ss + **21** hg + **12** csr_full + **4** top + **25** vec |
| `make -C fpga/as02mc04 lint`  | clean (Verilator + Xilinx blackbox)   |
| `make -C sim/cocotb all`      | **17 / 17** parser + classifier + flow_gen unit checks |
| `make -C tools/pktwyrm-tinet test` | **35 / 35** lab generator + lifecycle orchestrator |
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

**Status (done in isolation, integrated under one AXI-Lite slave).**
All four windows exist as RTL modules with per-window TBs, plus
`rtl/phase3/pw_csr_full.sv` integrates them under a single
AXI4-Lite slave (16-bit address space):

- `rtl/shared/pw_csr_window.sv` &mdash; generic shadow + commit.
- `rtl/phase3/pw_classifier_window.sv` &mdash; wire-format
  `pwfpga_classifier_entry` rows → typed `pw_classifier_table_t`.
- `rtl/phase3/pw_flow_window.sv` &mdash; wire-format
  `pwfpga_flow_config` rows → per-port flow_gen inputs.
- `rtl/phase3/pw_stats_snapshot.sv` &mdash; trigger latches
  per-flow counters into `pw_flow_stats` / `pw_port_stats`
  byte layout.
- `rtl/phase3/pw_histogram_snapshot.sv` &mdash; trigger latches
  per-flow histogram buckets.
- `rtl/phase3/pw_csr_full.sv` &mdash; AXI4-Lite slave that
  wraps the identity registers and all four windows. Exercised
  end-to-end by `sim/csr_full_tb` (12 assertions over identity
  reads, classifier write+commit via `axi_write`, snapshot
  trigger, histogram readback).

**Still pending.**

- **Board-level integration of `pwfpga_top_phase3.sv` into the
  AS02MC04 Phase 1 top.** The Phase 3 core itself exists and
  passes an end-to-end loop test (see `sim/phase3_top_tb`).
  What's missing is the board-specific glue: bridging the PCIe
  Gen3 IP's AXI-Lite master into the new slave, wiring the MAC
  TX/RX AXIS to the Phase 2 10G MAC IP, and exposing the punt
  AXIS as a DMA ring. The existing `pwfpga_top_phase1.sv` keeps
  the identity-only `pw_csr_min` for bring-up.
- **Host integration test against the real backend** &mdash;
  **done.** `sw/build/gen_bar_vectors` runs the real
  `pw_bar_backend` ops against a tmpfs BAR and dumps the
  post-write image; `sim/wire_vectors_tb` replays those dwords
  through `pw_csr_full` and checks the decoded classifier table
  and flow-gen inputs match what the host wrote. The vector
  file under `sim/vectors/` is regenerated each `make -C sim
  sim_vec`, so any drift in the C wire layout (csr.h) or the
  SV byte offsets fails the test immediately.
- **Wire it into a real top.** None of this is glued into a
  `pw_csr_full.sv` AXI-Lite slave yet. The current testbench drives
  the `wr_en / wr_addr / wr_data` strobe directly. The next step
  is to write `pw_csr_full.sv` that wraps `pw_csr_min` + the
  windows + a single AXI-Lite slave, instantiate it in a new
  `pwfpga_top_phase3.sv`, and prove it round-trips against the
  host BAR backend (set up a tmpfs-backed BAR like the unit tests
  do, and add an integration test that uses the actual backend
  ops, not raw strobes).

**Test plan.** Add `sim/flow_window_tb` and `sim/stats_window_tb`
following the same shape as `csr_window_tb`. The wire format is
fixed by `csr.h`; the existing host BAR backend round-trips
(`test_bar_backend_window_writes` / `test_bar_backend_stats_reads`)
already serve as the host-side contract.

**Files of interest.**

- `rtl/shared/pw_csr_window.sv` — generic shadow + commit.
- `rtl/phase3/pw_classifier_window.sv` — pattern to mirror for
  flow / stats / histogram.
- `sim/csr_window_tb/tb_csr_window.sv` — reference TB.
- `sw/libpacketwyrm/include/packetwyrm/csr.h` — stride / commit /
  flag register macros.
- `docs/design/csr-map.md` — register / window layout reference.

---

### 2. `pktwyrm load` actually deploys a config to a running daemon  **(done)**

The daemon now exposes `config.load` over JSON-RPC: it parses
the YAML body, validates, compiles, stops old flows, and pushes
the new program to every open backend before swapping cfg+prog
atomically. `pktwyrm load <yaml> --socket PATH` is the
user-facing front-end. Constraints and design notes live in
`docs/design/rpc-protocol.md`. Covered by two new e2e checks
(same-topology accepted, different-topology rejected).

If you build on this: TAP / backend hot-swap is still out of
scope (topology mismatch is rejected on purpose). A future
extension could add `config.diff` so the client previews what
would change before committing.

---

### 3. Per-card worker threads  **(done)**

`packetwyrmd` now spawns one pthread per opened card. Each
worker owns its card's TAP fds, runs its own `poll()`, and
calls `pw_host_plane_step()`. The main thread keeps the
control socket and Prometheus listener, so slow-path latency
on one card cannot be starved by another. Workers exit on a
`stdatomic` stop flag set in the SIGINT/SIGTERM handler.

config.load (TODO #2) and the worker threads are decoupled by
design: the topology-change ban means `hps[i]` and the TAP fds
never change across a reload, so workers never need to
re-synchronise. The host_plane counters are still read from
the main thread for `print_stats` and the Prometheus exporter;
that's a benign best-effort race for stats display.

---

### 4. JSON Schema for the YAML config  **(done)**

`sw/libpacketwyrm/schema/packetwyrm.schema.json` mirrors
`docs/design/yaml-schema.md`. The unit-test suite checks that
the file parses as well-formed JSON and contains the expected
top-level keys (so editor plugins keep working).
`scripts/check-schema.sh` is an optional dev tool that
validates the example configs when `python3 + jsonschema` are
available; CI can opt into it.

If you build on this: register the schema with `schemaStore`
so vscode-yaml picks it up automatically, and add JSON-schema
output as an alternative diagnostic format for `pw_config_validate`.

---

### 5. cocotb / Python testbench  **(done)**

`sim/cocotb/` ships a Scapy + cocotb suite covering the parser,
classifier, and flow generator at the unit level (17 Python
assertions, 3 modules). Driven by `make -C sim/cocotb all`.

Implementation notes:

- cocotb 2.x's VPI shim requires Verilator >= 5.036; this
  environment ships 5.020, so the suite runs under **Icarus
  Verilog** instead.
- Icarus rejects a few constructs the production RTL leans on
  (`automatic` inside `always_ff`, packed-struct ports,
  function-call bit-slicing). Rather than rewrite the production
  RTL for two simulators, `sim/cocotb/rtl/` ships small
  behavioural mirrors (`pw_parser_beh.sv`, `pw_classifier_beh.sv`,
  `pw_flow_gen_beh.sv`) that implement the same spec on flat
  ports.
- The Verilator SV suite (`make -C sim sim_all`) is still the
  gate against the production RTL. cocotb is the spec-level unit
  suite.

If you build on this: extend to `pw_test_rx_checker` (latency
histogram), and once Verilator >= 5.036 is available, retarget
`run_tests.py` at the production RTL directly and drop the
behavioural mirrors.

---

### 6. TX path RTL to the MAC  **(done)**

`rtl/phase3/pwfpga_top_phase3.sv` wires the data plane, an
AXIS serializer/deserializer per port, and a punt-AXIS path
under a single AXI4-Lite slave (`pw_csr_full`). The TB at
`sim/phase3_top_tb/tb_phase3_top.sv` runs the full loop:
AXI-Lite host writes → CSR windows → flow_gen frame emitted
on TX serializer → testbench loops it into RX deserializer →
data plane classifies TEST_RX → stats snapshot reports
rx_frames > 0; an ARP frame on RX raises the punt AXIS.

The remaining work is board-level (PCIe + 10G MAC integration);
covered under "Still pending" above.

---

### 7. Container / tinet integration  **(Phases A + B done)**

`tools/pktwyrm-tinet/pktwyrm-tinet` is a multi-command CLI that
both *renders* a tinet topology from a lab spec and *orchestrates*
the full lifecycle (`up` / `conf` / `down` / `status`).

Design choices:

  - **Lab spec lives outside the PacketWyrm config**, in its own
    YAML that references the PacketWyrm config by path. The core
    daemon and its JSON Schema (`additionalProperties: false` at root)
    are untouched -- `routers:` is a lab concern, not a data-plane
    concern.
  - **TAP attach via `ip link set <tap> netns <ctr>`** under tinet's
    `postinit_cmds`. The TAP fd stays in `packetwyrmd`'s process;
    only the netdev moves. One hop fewer than a veth bridge and
    matches the existing `start-r1.sh` recipe.
  - **FRR per-router config files** are written next to the
    tinet.yaml and bind-mounted into each container. v1 supports
    BGP (asn / router_id / neighbors / advertised networks); OSPF
    fits under the same `routing:` shape when needed.
  - **Single state file** `<out_dir>/.pktwyrm-lab.json` records the
    `packetwyrmd` pid, tinet.yaml path, and TAP list. `down` and
    `status` need nothing else; `down` is idempotent and degrades to
    a best-effort `tinet down` when state is missing but `tinet.yaml`
    is still present.

Tests: `make -C tools/pktwyrm-tinet test` -> 35 / 35 in pure Python
(PyYAML + `unittest.mock`). Golden YAML/FRR rendering, schema
validation, state-file IO, command construction, and the up/down/conf
orchestrator with mocked subprocess.

Worked example: `configs/examples/lab-frr-2node/` -- two FRR
containers peering eBGP across a DUT, brought up with one command:

```sh
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet up \
    configs/examples/lab-frr-2node/lab.yaml -o /tmp/lab-frr/
```

**Phase C (later):** non-FRR templates (BIRD, GoBGP); L2 lab
topologies that bridge multiple LIFs; opt-in CI smoke that runs
the full bring-up in a docker-in-docker runner.

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
