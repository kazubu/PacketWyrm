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

As-built design: `docs/design/csr-map.md`, `docs/design/rtl-modules.md`.

## Branch / tree state

Working branch **`phase3-timing-recovery`**, 9 commits ahead of `main`
(not merged — the user pushes/merges). Tip-first:

```
8e2e89c docs: SAF BRAM-backing future task
d03d437 config: FORWARD rules from YAML
f600ab1 phase3: advertise capabilities (0x6C)
36e115e docs: parity sweep (slow-path / FORWARD)
4e3889f phase3: slow-path TX inject (host -> FPGA)
6eb84e9 phase3: PUNT / slow-path RX (FPGA -> host)
7c93ffe phase3: host-selectable FORWARD egress + doc parity
7008e4e docs: FORWARD validated on silicon
9c2a706 phase3: recover timing margin (2-stage parser)
```

Standalone HW tools (`sw/tests/`, run via `sudo env PW_BACKEND=vfio
sw/build/<tool> <bdf>`): `pw_card_probe`, `pw_sfp_test`,
`pw_phase3_loopback`, `pw_phase3_forward`, `pw_phase3_punt`,
`pw_phase3_inject`, `pw_flash`, `pw_reboot`.

## Remaining / next

1. **RX ingress timestamping** (optional) — move RX timestamping to the
   ingress MAC for absolute one-way latency. RTL + bitstream rebuild.
   Deferred by the user ("RX side is fine for now").
2. **Multi-card** — cross-card flows, multi-card orchestration. Needs a
   second card on the bench.
3. **Field modifiers — extend** (v1 done): generator field modifiers
   (inc/random/mask) on `src/dst_ipv4` + `udp_src/dst`, test header kept
   fixed, correct IPv4 checksum. Extensions: MAC/VLAN modifiers (same
   scheme, mechanical); independent per-field rotation (cross-product
   rather than the current shared-sequence, correlated rotation);
   classifier partial-field bitmask (so a rotated field can still be a
   measurement key).
4. **Minor**: the `CAPABILITIES` parameter advertises `0x6C` (the
   currently-flashed build reports it).

Timing: the full feature stack now closes at **WNS +0.198 ns @156.25 MHz**
(was a razor-thin +0.005; BRAM-backing the SAF freed ~24% FF / ~14% LUT
and de-congested the route-dominated paths). Comfortable margin, but still
watch it when adding to the `dp_clk` data plane — the parser pipelining
and SAF BRAM-backing were the levers used to get here.

## Test surface

| Command                       | Result                              |
|-------------------------------|-------------------------------------|
| `make -C sw test`             | **172 / 172** unit assertions       |
| `make -C sw e2e`              | daemon ↔ CLI smoke (18 checks)      |
| `make -C sim sim_all`         | **19 testbenches** (~441 assertions); see `sim/README.md` |
| `make -C fpga/as02mc04 lint`  | clean (Verilator + Xilinx blackbox) |
| `make -C sim/cocotb all`      | 17 parser/classifier/flow_gen checks (Icarus) |
| `make -C tools/pktwyrm-tinet test` | 35 lab generator / orchestrator checks |

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
