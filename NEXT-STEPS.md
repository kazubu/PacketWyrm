# NEXT-STEPS — handoff to the next agent

The agent-to-agent baton. Read top to bottom; everything you need to keep
moving is here or one link away. `CHANGELOG.md` (Unreleased) is the
ground truth for "what's working"; this file is "what's left and how to
not relearn the hazards".

## Current state

**Phase 3 is complete on the AS02MC04 (silicon).** The 64-bit AXIS
streaming data plane runs at **32 flows / 16 classifier rows / 16 latency
bins, loss=0 at line rate**, booting from the onboard flash. Implemented
and HW-validated:

- Multi-flow generator + per-port RX checkers (loss / dup / OOO / latency)
- **BRAM latency histogram** (`pw_lat_histogram`)
- **Egress hardware timestamping** (per-flow DUT latency)
- **CSR data-plane soft-reset**; live **SPI-flash write** (`pktwyrm flash`
  / `pw_flash`); in-band **ICAP reboot** (`pw_reboot`)
- **Classifier FORWARD_PORT** — host-selectable egress port; programmable
  from YAML (`forwards:`) or the backend
- **Full slow path**: PUNT/MIRROR RX (`pw_punt_rx_window`) and host→FPGA
  TX inject (`pw_inject_tx_window`), both HW round-tripped; the daemon
  `host_plane` bridges TAP ↔ wire in both directions
- **BRAM RX checker** (`pw_test_rx_checker_bram`) + **per-flow jitter** +
  **per-port link-health/FCS** stats; **TEST_RX flow-id map**
  (`pw_flowid_map`): test flows are classified by a BRAM flow_id→slot index,
  not classifier rules, so the measured-flow count is bounded by the
  checker/generator (NUM_FLOWS), not the ~16-entry classifier routability wall.
  The parallel classifier carries only non-test rules (PUNT/FORWARD). First
  back-end of the generic slice classifier — `docs/design/generic-classifier.md`.

As-built design: `docs/design/csr-map.md`, `docs/design/rtl-modules.md`,
`docs/design/generic-classifier.md`, `docs/design/hw-architecture-freeze.md`.

## Branch / tree state

All work is **merged to `main`** (the user pushes — `main` is unpushed).
Recent tip (newest first):

```
Merge phase3-varlen-rfc2544: variable frame length + RFC 2544 driver
Merge phase3-inject-txts: inject TX wire-timestamp -> completes #60
Merge phase3-punt-rxts: punt RX wire-timestamp (servo PTP hook) [#60]
Merge phase3-tool-migration: standalone HW tools -> field classifier
(earlier) hash exact classifier, unified field+UDF classifier, IPv4/IPv6 parity
```

Three classification paths coexist (precedence map > hash > field): the flow-id
map (structured test flows), the hash exact table (high-count payload-agnostic),
and the field+UDF comparator classifier (punt/forward/few-rule). The generator
honors `frame_len_min/max/step` (fixed RFC2544 size + IMIX sweep). HW state:
WNS ~0 (design at its Fmax ceiling, 89% LUT) — a dedicated timing-recovery pass
(pipeline the hash multiply->BRAM + token-bucket paths) is recommended before
adding more dp_clk logic.

Standalone HW tools (`sw/tests/`, run via `sudo env PW_BACKEND=vfio
sw/build/<tool> <bdf>`): `pw_card_probe`, `pw_sfp_test`,
`pw_phase3_loopback`, `pw_phase3_forward`, `pw_phase3_punt`,
`pw_phase3_inject`, `pw_rfc2544`, `pw_tcp_syn`, `pw_flash`, `pw_reboot`.

## Remaining / next

Gated on a **second card** (can't proceed on the single-card rig):

1. **RX ingress wire-stamp + full two-clock PTP servo.** The servo-facing
   TX/RX wire-timestamp exposure is done (#60: punt RX SOF stamp + inject TX
   egress stamp); the servo loop (offset/delay + disciplining) and a true RX
   ingress stamp in the MAC clock domain need a second card.
2. **Multi-card** — cross-card flows + orchestration.

Optional RTL features (each a bitstream rebuild):

3. **Line-rate TCP generation.** `pw_tcp_syn` generates TCP SYNs via the
   slow-path inject (SW-built frame + SW checksum, ~tens of k pps). Line rate
   needs `pw_flow_gen_multi` to emit a TCP header + checksum (like the UDP/test
   path) — the bigger item.
4. **Field-modifier extensions:** full 128-bit IPv6-address rotation (low 32
   bits done) and independent per-field rotation (currently a shared,
   correlated sequence).
5. **Classifier extensions:** bitwise IPv6 dst masking + IPv6 *src* match (v4
   bitwise + v6 dst-exact are done; the field/UDF + hash engines replaced the
   old single `pw_classifier`).
6. **Further LUT reduction** if headroom is needed: the parser (~36K LUT over
   2 ports) is now the largest consumer (generator ~27K, field classifier
   ~15K, flow table ~15K).

Classification is three coexisting paths (precedence map > hash > field): the
flow-id map (structured test flows), the hash exact table (high-count,
payload-agnostic), and the field+UDF comparator classifier (punt/forward/
few-rule). Variable frame length (RFC2544 + IMIX), the RFC2544 driver, and the
slow-path TCP SYN generator are done.

**Timing:** post-route **WNS +0.132 ns @156.25 MHz, LUT ~88%** after the
timing-recovery pass (hash classifier pipelined + SPI flash buffers → block
RAM). The design sits near its Fmax ceiling, so multiple `dp_clk` paths hover
near zero; cutting LUT (congestion) lifts them all, while pipelining fixes one
named path. Read timing **post-route** (`report_timing` on the routed dcp) —
the post-*place* estimate runs ~0.5 ns optimistic and the project tcl has no
timing gate, so `write_bitstream` completing does NOT imply closure. Full
hard-won detail is in the `dp-clk-timing-lessons` memory.

## Test surface

| Command                       | Result                              |
|-------------------------------|-------------------------------------|
| `make -C sw test`             | host unit assertions                |
| `make -C sw e2e`              | daemon ↔ CLI smoke                  |
| `make -C sim sim_all`         | Verilator testbench sweep; see `sim/README.md` |
| `make -C fpga/as02mc04 lint`  | clean (Verilator + Xilinx blackbox) |
| `make -C sim/cocotb all`      | parser/classifier/flow_gen checks (Icarus) |
| `make -C tools/pktwyrm-tinet test` | lab generator / orchestrator checks |

CI (`.github/workflows/ci.yml`) runs the host job (build + test + e2e +
staged install) and the rtl-sim job (`sim_all` + AS02MC04 lint).

## Verilator / RTL hazards (known, still in tree)

1. **Continuous assigns into unpacked-array elements may silently drop.**
   Keep internal byte buffers as *packed* (`logic [N-1:0][7:0]`).
2. **`always_comb` may not sense packed-array element changes coming
   through a continuous-assign chain.** Do parsing in `always_ff` and
   register the output (1-cycle latency is the cost of robustness).
3. **Procedural assignment to a typedef'd-struct output port silently
   fails to update the port.** Drive a local `logic` and `assign` it out.
4. **A RAM whose write sits in an async-reset `always_ff` will not infer
   BRAM** — it dissolves into FFs + a wide mux (this is the `pw_frame_saf`
   issue above; fixed for `pw_punt_rx_window` by a reset-less write).
5. **`// Verilator` at a file's start triggers a parse error** — reword.

## Sanity ritual before pushing

```sh
make -C sw test
make -C sw e2e
make -C sim sim_all
make -C fpga/as02mc04 lint
```

If any regresses, the bug is in the diff. The unit tests catch
packed-struct layout drift and host_plane wiring mistakes; the SV +
wire-vector sims catch C↔RTL wire-format drift.

## Documentation map

- `README.md` — what it is, status, "try it".
- `docs/guides/getting-started.md` — short walkthrough.
- `docs/design/architecture.md` — big picture.
- `docs/design/csr-map.md` — BAR layout / CSR windows (host ↔ RTL contract).
- `docs/design/rtl-modules.md` — as-built RTL hierarchy.
- `docs/design/yaml-schema.md` — config schema (`forwards:` included).
- `docs/design/daemon.md`, `docs/design/rpc-protocol.md` — daemon / CLI.
- `CHANGELOG.md` — ground truth for "what's working".

Welcome aboard.
