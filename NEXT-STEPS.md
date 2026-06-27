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
honors `frame_len_min/max/step` (fixed RFC2544 size + IMIX sweep).

**HW state (current = the A+B IPv6-classifier+modifier build):** post-route
**WNS +0.084 ns (all clocks ≥0), LUT 84.0%**, flashed + booting. To fit A+B the
device needed **two impl changes**: PLACE directive `AltSpreadLogic_high` →
`Explore` (the former manufactures congestion at ~90%), and **`HDR_BYTES` 160 →
128** (parser var-offset muxes scale with it; this freed ~9K LUT). The device is
at its absolute routability/timing ceiling (~88%): the pre-A+B baseline was
+0.132 / 87.9%, and A+B+C together overflowed routing (~93% LUT) — so **TCP (C)
is held out** until a LUT-reduction pass, and **any further dp_clk feature is now
gated on LUT, not just timing**. The biggest blocks: parser ~32K (now 128 B),
generator ~28K, field classifier ~17K. The classifier-winner select is O(N²) on
purpose (shallow parallel one-hot mux); a "leaner" linear/tree rewrite is DEEPER
and regresses timing (see the `dp-clk-timing-lessons` memory).

**HDR_BYTES=128 capability boundary:** RX test-header classification spans
≤128 B — non-encap + single-encap v4/v6 are fine; the deepest v6-in-v6 *encap*
test header (>128 B) is no longer RX-classified (TX generation is unaffected).

**Known: single/low-flow IPv6 loopback is low-volume on this rig** (the stock
`phase3-ipv6.yaml` reproduces rx≈2 while IPv4 multiflow runs at 345K frames,
loss=0). Pre-existing (the generator rate logic is family-agnostic and unchanged;
IPv6 frames loop clean — loss=0, fcs=0). Worth a separate investigation (DAC /
MAC-PCS / classification behavior with IPv6); not introduced by A+B.

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

Optional RTL features:

3. **Line-rate stateless TCP segment generation — IMPLEMENTED, deferred on
   LUT.** Done on branch `phase3-tcp-gen` (generator TCP header + dual-family L4
   checksum, egress tx_ts fold, RX parser offset, `protocol: tcp`). But A+B+C
   together hit **~93% LUT and would not route** (congestion) on the xcku3p, so
   TCP is **held out of this build**. Ships after a dedicated LUT-reduction pass
   — biggest levers: the parser (HDR_BYTES 176; ~35K LUT over 2 ports) and the
   generator (~35K). `pw_tcp_syn` (slow-path inject) remains for one-off SYNs.
4. **Field-modifier extensions — DONE.** Full 128-bit IPv6-address rotation
   (v6-literal mask) with field+lane salts (four distinct lanes, src≠dst,
   de-duplicated deterministic streams, ~2³² period); low-32 hex masks stay
   back-compatible.
5. **Classifier extensions — DONE.** IPv6 *src* match (all four words now
   selectable) + masked IPv6 dst/src in forward rules (auto `is_ipv6` guard);
   `match.ipv6_*_prefix` for `classify: header` (hash, per-card-global mask).
6. **Further LUT reduction** — now on the critical path for shipping TCP (see 3).
   Largest blocks: parser ~35K LUT (2 ports), generator ~35K, field classifier
   ~16K.

Classification is three coexisting paths (precedence map > hash > field): the
flow-id map (structured test flows), the hash exact table (high-count,
payload-agnostic), and the field+UDF comparator classifier (punt/forward/
few-rule). Variable frame length (RFC2544 + IMIX), the RFC2544 driver, and the
slow-path TCP SYN generator are done.

**Timing:** post-route **WNS +0.014 ns @156.25 MHz** on a FULL (non-incremental)
resynth — the canonical build is build_id `0x6a3f40f3` / git `1c152435`. The
earlier **+0.132** figure was an *incremental*-synth build that reused a lucky
placement; it also masked that the per-build build_id never reached the netlist
(incremental reused `pw_csr_full`). Disabling incremental synth (so build_id is
real — see `flash-reconfig-hw-facts` memory) exposed the true ceiling at -0.059,
fixed by **pipelining the hash classifier 3→4** (register the XOR-fold `k32` so
fold/multiply/BRAM-addr no longer share a dp_clk cone). The new WNS limiter is no
longer dp_clk — it's the `axi_aclk` (250 MHz) `hash_acc_key` CSR-write path
(config-time only). The design still sits near its Fmax ceiling, so cutting LUT
(congestion) lifts all near-zero paths while pipelining fixes one named path.
Build identity is now also readable over JTAG (`REGISTER.USERCODE`=git,
`USR_ACCESS`=build_id; `BITSTREAM.CONFIG.USERID/USR_ACCESS` stamped). Read timing
**post-route** (`report_timing` on the routed dcp) — the post-*place* estimate
runs ~0.5 ns optimistic and the project tcl has no timing gate, so
`write_bitstream` completing does NOT imply closure (it now also gates on run
STATUS). Full hard-won detail is in the `dp-clk-timing-lessons` memory
(UPDATE 10) + `flash-reconfig-hw-facts`.

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
