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
- **Encapsulation** generate+decap (IPIP/GRE/EtherIP, v4/v6 inner+outer), the
  **unified field+UDF classifier** (retired the legacy parallel classifier), the
  **hash exact table** (high-count payload-agnostic flows), **variable frame
  length / RFC2544 / IMIX**, **IPv6 src/dst classifier match**, and **full 128-bit
  IPv6 + field/lane-salted modifiers**.
- **Stateless TCP segment generation** (`tcp:` vs `udp:`, dual-family L4 csum,
  L4-proto-aware egress stamp, TCP-20 RX offset) — HW-validated loss=0.
- **Flow-table CSR staging → BRAM** (word-serial commit walk): freed ~15.7K LUT,
  which unblocked TCP and let **HDR_BYTES go to 176** (deepest v6-encap TCP RX).
- **Cross-card time sync over J5 GPIO** (`pw_gpio_sync`): HW path in (master pulse
  + edge-latch + CSR 0x0130..0x0140); single-card non-regression only — the SW
  servo + the daisy-chain test need a 2nd card (see Remaining).

As-built design: `docs/design/csr-map.md`, `docs/design/rtl-modules.md`,
`docs/design/generic-classifier.md`, `docs/design/hw-architecture-freeze.md`.

## Branch / tree state

All work is **merged to `main`** (the user pushes — `main` is unpushed).
Recent tip (newest first):

```
Merge phase3-gpio-sync-review: pw_gpio_sync review fixes (2 rounds)
Merge phase3-gpio-sync: J5 GPIO cross-card time sync (pw_gpio_sync)
Merge phase3-flowtable-word-guard / -review2: post-reset staging guard (per-word)
Merge phase3-hdr176: HDR_BYTES 160->176 (deepest v6-encap TCP RX)
Merge phase3-tcp-revival: stateless TCP segment generation (Part C, HW-validated)
Merge phase3-generator-lut: flow-table CSR staging -> BRAM (-15.7K LUT)
(earlier) inject/punt wire-timestamps, varlen/RFC2544, hash+field classifiers
```
NOTE: `main` is many commits ahead of `origin/main` — the user pushes.

Three classification paths coexist (precedence map > hash > field): the flow-id
map (structured test flows), the hash exact table (high-count payload-agnostic),
and the field+UDF comparator classifier (punt/forward/few-rule). The generator
honors `frame_len_min/max/step` (fixed RFC2544 size + IMIX sweep).

**HW state (history of how the ceiling was beaten):** the A+B IPv6-classifier+
modifier build closed at WNS +0.084 / LUT 84.0% only after two impl changes: PLACE
directive `AltSpreadLogic_high` → `Explore` (the former manufactures congestion at
~90%), and **`HDR_BYTES` 160 → 128** (parser var-offset muxes scale with it; freed
~9K LUT). A+B+C (TCP) then overflowed routing (~93% LUT). The LUT-reduction pass
that unblocked TCP was **moving the flow-table CSR staging from a register
double-buffer to BRAM** (a word-serial commit walk): freed **~15.7K LUT**
(84.6% → 74.9%) and *improved* dp_clk WNS (congestion relief). That headroom let
HDR_BYTES go back to 160 then **176** (deep v6-encap UDP *and* TCP RX recovered),
and **A+B+C including TCP builds + routes, HW-validated (loss=0)**. The current
flashed build adds GPIO sync (build_id `0x6a41dbaf`, see Timing below). The
biggest blocks now: parser ~39K (176 B), generator ~28K, field classifier ~17K
(flow-table dropped to ~4K LUT). The classifier-winner select is O(N²) on purpose
(shallow parallel one-hot mux); a "leaner" linear/tree rewrite is DEEPER and
regresses timing (see the `dp-clk-timing-lessons` memory). **HDR_BYTES was then
raised 160 → 176** so the deepest v6-encap TCP test header (166 B) RX-classifies
too: build LUT 83.45%, dp_clk WNS +0.082, HW-validated (etherip-v6-in-v6 TCP
loopback loss=0 + RX-classified, UDP/TCP no regression) — no LUT/timing penalty,
so all encap depths now classify for both UDP and TCP.

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

**Cross-card time sync via J5 GPIO (alternative to PTP, HW done):** rather than
discipline to a grandmaster over PTP packets, the cards share a clean hardware
sync edge over the J5 header (`pw_gpio_sync`): a master drives a periodic pulse, every
card latches its free-running counter at the edge (no counter step → Gray-CDC
safe) + an edge sequence, exposed at CSR 0x0130..0x0140. Software pairs equal
sequence numbers across cards to get the inter-card offset/skew and corrects raw
timestamps — same SW-correction model as the PTP plan but with a deterministic
sub-ns edge instead of packet jitter. RTL + CSR + sim done (single-card,
non-regression verified); the daisy-chain wiring + the SW offset/skew servo need a
2nd card (and a J5 jumper to validate the loopback).

Gated on a **second card** (can't proceed on the single-card rig):

1. **RX ingress wire-stamp + full two-clock servo.** The servo-facing
   TX/RX wire-timestamp exposure is done (#60: punt RX SOF stamp + inject TX
   egress stamp) and the GPIO sync edge-capture HW is in; the servo loop
   (offset/skew correction) and a true RX ingress stamp in the MAC clock domain
   need a second card. (Sync can come from the J5 GPIO daisy-chain above OR PTP.)
2. **Multi-card** — cross-card flows + orchestration.

Optional RTL features:

3. **Line-rate stateless TCP segment generation — DONE (shipped + HW-validated).**
   Generator emits a fixed-form 20-byte TCP header (data-offset 5, `flags` byte
   default 0x02 SYN, window 0xFFFF, seq = test seq) with a correct dual-family L4
   checksum; egress tx_ts fold is L4-proto-aware (csum field at L4+16, no UDP
   zero-rule); the RX parser offsets the test header by the 20-byte TCP header so
   TCP flows RX-classify. A flow picks `tcp:` vs `udp:` (mutually exclusive). This
   was LUT-blocked (A+B+C ~93%) until the flow-table-staging→BRAM pass freed the
   room; it now builds at LUT 84.42% / dp_clk WNS +0.032 and HW-validated (v4/v6
   TCP loopback loss=0, RX-classified). Not a connection engine (no handshake /
   ACK / retransmit). `pw_tcp_syn` (slow-path inject) remains for one-off SYNs.
   HDR_BYTES was then raised to 176 so the deepest v6-encap TCP (166 B) also
   RX-classifies (HW-validated, no penalty) — all encap depths now covered.
4. **Field-modifier extensions — DONE.** Full 128-bit IPv6-address rotation
   (v6-literal mask) with field+lane salts (four distinct lanes, src≠dst,
   de-duplicated deterministic streams, ~2³² period); low-32 hex masks stay
   back-compatible.
5. **Classifier extensions — DONE.** IPv6 *src* match (all four words now
   selectable) + masked IPv6 dst/src in forward rules (auto `is_ipv6` guard);
   `match.ipv6_*_prefix` for `classify: header` (hash, per-card-global mask).
6. **Further LUT reduction** — no longer blocking (TCP shipped after the
   flow-table-staging→BRAM pass). The one proven lever on this KU3P is the
   register-array→BRAM transform (checker, SPI-flash, flow-table staging); the
   parser is NOT a lever (build-confirmed twice — see `dp-clk-timing-lessons`
   UPDATE 11/12). Largest blocks now: parser ~39K LUT (2 ports, 176 B), generator
   ~28K, field classifier ~16K, flow-table down to ~4K.

Classification is three coexisting paths (precedence map > hash > field): the
flow-id map (structured test flows), the hash exact table (high-count,
payload-agnostic), and the field+UDF comparator classifier (punt/forward/
few-rule). Variable frame length (RFC2544 + IMIX), the RFC2544 driver, and the
slow-path TCP SYN generator are done.

**Timing:** the current canonical build (A+B+C TCP + flow-table-staging→BRAM +
HDR_BYTES 176 + GPIO sync) is build_id `0x6a41dbaf` / git `56a31d1f`: post-route
**dp_clk WNS +0.201 ns @156.25 MHz**, LUT 88.80% (the gpio module is 60 LUT; the
rest is run-to-run synth variance — same netlist has landed 83–89%). The worst
path is in the PCIe vendor IP, not the data plane. Earlier reference point: a FULL
(non-incremental) resynth landed **WNS +0.014** at build_id `0x6a3f40f3` / git
`1c152435`. The
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
