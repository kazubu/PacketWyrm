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
3. **Field modifiers — extend** (v1 + IPv6 + MAC/VLAN done): generator field
   modifiers (inc/random/mask) on `src/dst_ipv4` (or `src/dst_ipv6`, low 32
   bits) + `udp_src/dst` + `src/dst_mac` (48-bit) + `vlan` (12-bit), test
   header kept fixed, correct IPv4/IPv6 checksum. Remaining extensions: full
   128-bit IPv6-address rotation (v1 rotates the low 32 bits; user said not
   needed); independent per-field rotation (cross-product rather than the
   current shared-sequence, correlated rotation); classifier partial-field
   bitmask (so a rotated field can still be a measurement key).
4. **IPv6 — at full generator parity** (done): generation + egress HW
   timestamping + UDP checksum, DSCP/traffic-class, TTL/hop-limit, and
   src/dst address field modifiers all work for IPv6 (YAML `ipv6:` block,
   `src/dst_ipv6` modifiers). Remaining: **classifier IPv6 dst-address
   matching** — *deferred* (functionally redundant: a TEST_RX IPv6 flow is
   already uniquely classified by udp_dst + flow_id + magic). NOTE for a
   future implementer: the RTL match logic already exists (`pw_classifier`
   computes `m_v6dst` and the parser extracts `ipv6_dst` into the key); the
   only missing pieces are the wire `pwfpga_match_key` IPv6 fields (which
   pushes the classifier row past the 128 B stride → grow to 256 B like the
   flow row), the `pw_classifier_window` decode, and the compiler setting
   `ce.key.ipv6_dst`/`mask` for v6 flows. Watch timing (margin is +0.037 ns).
   Also: IPv6 in the wide-bus legacy sim if ever needed.
4. **Minor**: the `CAPABILITIES` parameter advertises `0x6C` (the
   currently-flashed build reports it).

Timing: the full feature stack **including IPv6 + IPv4/IPv6 parity + MAC/VLAN
modifiers** (DSCP/traffic-class, TTL/hop-limit, address modifiers) closes at
**WNS +0.066 ns @156.25 MHz** (LUT ~75% / FF 60% / BRAM 16% on the KU3P). The
parity round had thinned it to +0.037; a `pw_ts_insert` optimization (pre-sum
the tx_ts words at SOF + register the csum lane/beat so the egress
csum-finalize no longer feeds the MAC CRC through a deep adder) recovered it
to +0.167. Adding the MAC/VLAN field modifiers (eth-header only, off the
checksum cone, but ~110 bits of mask + mod48 logic at LUT ~75%) tightened it
to **+0.066** via congestion — still positive. Watch it before adding to the
generator. The earlier IPv6-only stack closed at +0.116. IPv6
(256-byte flow rows + the mandatory IPv6 UDP checksum) cost ~0.83 ns and
was recovered without cutting flows/scale by, in order of impact: (1) a
**row-latch split** in `pw_flow_gen_multi` — the 32:1 mux of the wide flow
rows was fused with the checksum logic in one cycle (route-bound,
~-0.6 ns); isolating the mux into its own register so it drives only a
register, and feeding the checksum from that compact local latch, was the
decisive fix; (2) a **checksum/field precompute** stage (off the
registered `pick_q`, NOT the combinational pick); (3) **registering the
flow-table decode** (`pw_flow_window`). The margin is thin again — watch
it when adding to the `dp_clk` data plane. Note: timing must be read
**post-route** (`report_timing` on the routed dcp); the post-*place*
estimate ran ~0.5 ns optimistic during this work, and the project tcl has
no timing gate, so `write_bitstream` completing does NOT imply closure.

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
