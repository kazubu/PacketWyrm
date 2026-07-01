# FPGA RTL module breakdown (AS02MC04)

The AS02MC04 carries a Kintex UltraScale+ KU3P, two SFP+ cages, and a
PCIe endpoint. RTL only deals with **one card at a time**; no global ID
ever crosses the PCIe boundary.

## As-built hierarchy (Phase 3, on silicon)

This is what actually builds and runs today. The original sketch below
(`## Top-level module hierarchy`) is kept for design intent, but the
streaming Phase 3 plane diverged from it (no wide frame bus, no serdes).

```
pwfpga_top_phase3_board           per-board top (fpga/as02mc04/src/)
+-- pcie (XDMA) + axi_clk_conv    BAR -> AXI-Lite, 250 -> 156.25 MHz
+-- pw_sfp_10g + pw_mac_axis_cdc  dual 10GBASE-R (Taxi MAC/GTY) <-> dp_clk
|                                (RX FIFO user widened to 65b: {rx_wire_ts,err})
+-- pw_ts_gray_cdc (x2 dir) + pw_ts_insert       egress + RX-ingress HW timestamping
+-- ICAPE3     <- pw_icap_reboot                 in-band IPROG reload
+-- pwfpga_top_phase3            board-agnostic core
    +-- pw_csr_full              AXI-Lite slave: identity + windows +
    |   +-- pw_stats_snapshot   (flow + field-classifier tables moved to the
    |   |                            data plane; csr_full decodes their write
    |   |                            strobes -- flow window + fc cmp/udf/rule)
    |   +-- pw_spi_flash         CSR SPI master (live config-flash access)
    |   +-- DP_RESET / REBOOT / STATS_CLEAR / SNAPSHOT triggers
    +-- pw_punt_rx_window        punt AXIS -> CSR-polled frame buffer (host RX);
    |                            carries the 64-bit RX wire timestamp (sampled in
    |                            the MAC RX clock at SOF -- the TRUE wire arrival,
    |                            not a post-FIFO dp_clk sample) -> RX_TS regs
    +-- pw_inject_tx_window      CSR frame buffer -> AXIS into egress (host TX);
    |                            latches the egress wire timestamp of the injected
    |                            frame (servo-facing) -> INJECT_TX_TS regs
    +-- pw_data_plane_axis       64-bit AXIS streaming data plane
        +-- pw_flow_table_bram   BRAM flow table (commit-walk decode; per-port
        |                        read port + compact scheduling FF array)
        +-- per ingress port: pw_parser_axis -> pw_field_classifier (field+UDF
        |                      comparators + rules; punt/forward/few-rule) +
        |                      pw_hash_classifier (header-keyed high-count TEST_RX)
        |                      + pw_flowid_map (structured TEST_RX flow_id ->
        |                      checker slot) -> pw_frame_saf
        |                      (effective result: map > hash > field classifier)
        +-- per ingress port: pw_test_rx_checker (loss/dup/ooo/min/max/sum +
        |                      RFC-3393 IPDV jitter min/max/sum; latency =
        |                      rx_wire_ts - tx_wire_ts, i.e. wire-to-wire, free of
        |                      the post-FIFO + parser + classifier pipeline delay)
        +-- link health: per-port 2-FF sync + edge count of MAC link_up /
        |                block_lock; FCS errors from RX tuser-on-tlast
        +-- pw_lat_histogram     shared BRAM latency histogram
        +-- per egress port:  pw_flow_gen_multi (N-slot token-bucket gen)
        +-- egress / punt arbiters
```

Module notes: `pw_parser_axis` is pipelined (3-stage: L2+decap-descent / inner L3-L4 / test extract) and
auto-decapsulates recognized tunnels (outer IP proto 4/41/47/97 →
IPIP/GRE/EtherIP), re-basing the L3/L4 parse onto the inner frame so the
classifier keys on the inner test flow (header capture is 176 B — deep enough for
the deepest TCP test header: VLAN 4 + outer v6 40 + EtherIP 2 + inner eth 14 +
inner v6 40 + TCP 20 + 32 test = 166 B);
`pw_field_classifier` (latency-2, parallel priority winner) replaced the legacy
`pw_classifier`; `pw_lat_histogram` replaced the FF histogram; `pw_frame_saf`
is BRAM-backed (reset-less write + registered read-ahead drain) — freed
~24% FF / ~14% LUT vs the former register array. `pw_flow_gen_multi`
applies per-field modifiers (static/increment/random + bitmask on
src/dst IPv4 (or IPv6 low 32 bits) + UDP ports + src/dst MAC (48-bit) +
VLAN ID, driven by the slot sequence so the DUT sees
many flows while the fixed test header keeps measurement intact), emits
a correct IPv4 header checksum, and can emit IPv4/IPv6 **UDP or TCP** frames for
the flow row (the flow-table row stride is 256 B to carry the 16-byte addresses;
the row's `l4_proto` byte selects 17=UDP / 6=TCP and `tcp_flags` is the fixed TCP
flags byte, default 0x02 SYN). TCP is a STATELESS segment generator — a fixed-form
20-byte TCP header (data-offset 5, flags, window 0xFFFF, seq = test seq, ack 0),
the 32-byte test header riding in the TCP payload — NOT a connection engine. It
emits a *partial* L4 checksum (the mandatory pseudo-header + L4 header + payload
sum, **minus** the tx_timestamp) for both UDP and TCP and both families;
`pw_ts_insert` folds the departure stamp in (see below).
IPv4 and IPv6 are at feature parity: both emit the configured DSCP (IPv4
TOS / IPv6 traffic class) and TTL / hop limit, and both apply the src/dst
address field modifiers — for IPv4 the 32-bit address, for IPv6 the low 32
bits of the address (the modified address is folded into the IPv6 UDP
checksum). The address-modifier wire fields are shared (a flow is one
family).
The modifier-applied header fields and both checksums are **precomputed
one stage ahead**, registered alongside the round-robin `pick` (identical
1-cycle staleness, so they align with the built row) — the frame-build
cycle then only lays out bytes, keeping mod32/scramble + the checksum
adders off the build path. (Excluding tx_timestamp from the IPv6 checksum
is what makes it pick-stable and thus precomputable.)
**Encapsulation:** a flow row can carry a tunnel (`encap_type` 1/2/3 =
IPIP/GRE/EtherIP) with its own outer L3 (`outer_v6` + outer addrs/ttl/dscp,
independent of the inner family). `build()` prepends the outer Ethernet/IP +
tunnel header (GRE 4 B / EtherIP 2 B + a 14-byte inner Ethernet whose MAC
comes from the row's dedicated inner-MAC field) ahead of the
inner IP/UDP/test frame; the outer IPv4 header checksum is precomputed in
parallel with the inner one (`ip_csum16_o`, tunnel proto in the protocol
byte). `HDR_MAX_BYTES` is 176 to hold the deepest layout (VLAN + v6-outer +
EtherIP + v6-inner + **TCP 20** + 32 test = 166 B; TCP's 20-byte L4 is the worst
case, UDP's deepest is 154 B). The inner L4 checksum is unchanged (over
the inner addresses), so egress timestamping still works at the deep offset.
**Variable frame length:** each slot emits a total L2 frame length that sweeps
`frame_len_min → frame_len_max` by `frame_len_step` (wrapping); `min == max`
gives a fixed size (RFC 2544), and a `min < max` range gives IMIX/staircase
sizing. The min/max/step live in the scheduling descriptor (FFs) so the per-slot
sweep position (`cur_len[]`) needs no BRAM read; the effective length is sampled
at `pick` and flows through the precompute pipeline alongside `seq`. The L4
payload = `frame_len − header_overhead` (floored at the 32-byte test header, so
a sub-minimum config clamps to the smallest legal frame, per L4 proto — TCP's
20-byte header raises the minimum vs UDP); the IPv4/IPv6 and L4 (UDP/TCP)
*length fields* and the length-dependent checksum terms track it, while the pad
beyond the 32-byte test region is zero (adds nothing to the L4 checksum). The
header buffer `fb` only holds the built header + test region (`built_len`); the
emit FSM streams zero pad from `built_len` out to `frame_len`, so `fb` never has
to grow to the 1518 B frame size. The token cost meters by the smallest legal
frame (exact for a fixed size; a sweep meters by `min`). Before this, the
generator ignored `frame_len_*` and always emitted a fixed 74 B frame.
`pw_flow_table_bram` holds the flow table in **block RAM** (in the data
plane, next to the generators). The old approach — a 32-wide registered
`pw_flow_row_t` array (`flow_rows_o`) fanning out to both generators, each
muxing the picked row 32:1 — was the routing wall once encap widened the row
(~92% LUT, unroutable). Instead: on commit a single decoder **walks** the
committed rows into a per-generator BRAM copy plus a compact per-slot scheduling
FF array (`flow_sched`: valid/egress/tokens/cap/cost). Each generator schedules
from `flow_sched` (all slots, every cycle) and reads only its **picked** row from
BRAM (`rd_addr`→`rd_row`, 1-cycle, same latency the old register mux had). The
decode happens once (not ×32 in parallel), the wide register array + fan-out
are gone, and the 32:1 mux became a BRAM read — LUT 92%→87%, FF 78%→66%, +34
RAMB36. (BRAM inference needs a flat bit-vector mem read into an internal reg;
a struct-array mem or reading into the output port maps to FFs.)

The **CSR staging** is also block RAM now (it used to be a `pw_csr_window`
shadow+live register double-buffer — ~94 K FFs read by the commit walk through a
32:1 × 2048-bit `live_rows[waddr]` mux, ~17 K LUT, the dominant cost of this
module after the read path went to BRAM). The host writes one 32-bit word per CSR
write into a word-wide staging BRAM; on commit a **word-serial walk** reads it one
word per cycle, reassembles each row, and feeds the same single decoder. So the
walk now takes `DEPTH*ROW_DW` (64 words/row) cycles instead of `DEPTH` — ~13 µs
for 32×256 B at 156.25 MHz. The CSR address map / commit register / wire model are
unchanged, but **one timing contract changed**: the staging BRAM is BOTH the host
write target and the commit-walk read source (the old `pw_csr_window` promoted
shadow→live atomically into a *separate* live copy), so a `flow_write` landing
DURING the walk would tear the in-flight commit — unwalked rows pick up the new
data. **The host must not write flow rows until the walk completes.** Benign for
normal use (configs commit once before a run, long gap before any reconfig), and
the library enforces it: `bar_flow_commit()` posts the commit write then blocks
~200 µs (>> the worst-case walk) so "`flow_commit()` returns ⇒ safe to write the
next config" still holds. Unwritten staging words read back as zero so they walk
in inert (`valid=0`) — by two mechanisms: at power-on/config-load the staging
block RAM is zero-initialised (explicit `initial`), and after a *logic* reset
(which does not re-zero block RAM) a per-word `word_written` guard (reset to 0,
set on each CSR word write) makes the commit walk substitute 0 for any word not
(re)written since reset. So a fully-unwritten or partially-written row decodes
exactly as the old `pw_csr_window` zero-shadow would have (per-word, not just
per-row).
`pw_csr_window` itself is untouched and still backs the legacy flow window + the
classifier window. The legacy
per-port `gen_*_o` single-flow selection was also removed (dead in the
multi-flow data plane). The wide-bus `pw_data_plane` / `pw_parser` /
`pw_flow_gen` and `pw_flow_window` remain only for the legacy sim
(`tb_data_plane`, `tb_flow_window`).

`pw_ts_insert` (per egress port, on the MAC TX clock) overwrites each
generator test frame's tx_timestamp with the true departure time, so
latency measures the DUT, not the tester's TX-FIFO queuing. It detects the
L3 family (IPv4 0x0800 → tx_ts @62; IPv6 0x86DD → tx_ts @82; +4 if VLAN).
For an **encapsulated** frame it decodes the outer IP proto (4/41/47/97) and
tunnel header in-stream to find the *inner* test header's offset, registering
it before the deep csum/tx_ts beats so the MAC-CRC data path still reads a
stable lane. It also **finalizes the L4 checksum** and is L4-proto-aware: it adds
the four departure-stamp 16-bit words to the generator's partial checksum and
writes the result to the L4 csum field — for UDP at L4+6 (@60 non-encap, +4 VLAN,
or the inner offset for a tunnel) applying the RFC 768 `0→0xFFFF` rule; for TCP at
L4+16, and TCP does NOT apply the zero rule (0 is a valid TCP csum). It fixes up
{v6 UDP, v4 TCP, v6 TCP} (v4 UDP stays 0); the inner L4 proto is captured from the
inner IP header so the offsets/rules pick correctly under encap. The fixup is
gated on the *generator test frame* marker (not `magic_ok`), because for v4 TCP the
csum field at L4+16 streams out before the magic bytes. This one-pass fixup works because the csum field
leaves before the tx_ts field, so only the (SOF-latched) *new* stamp is
needed, never the old one. Which frames to rewrite is gated by a
"generator test frame" marker the egress arbiter raises (`sel_gen`),
carried as AXIS `tuser` through the MAC-TX CDC — so forwarded / injected
frames (including genuine IPv6/UDP DUT traffic) are never touched. That
`tuser` is consumed here; the MAC sees `m_tuser=0` (no tx-error).

**RX ingress wire-stamp.** `pw_ts_insert` stamps tx_timestamp with the
**TX SOF** time (latched at beat 0). For a symmetric, frame-size-independent
wire-to-wire latency the RX side must reference the **RX SOF** the same way, so
the board top runs a second `pw_ts_gray_cdc` per port (`u_rxtscdc`, dp_clk →
each MAC `sfp_rx_clk`) and latches the counter at each frame's RX SOF. That
64-bit stamp rides the RX async FIFO as extra `tuser` bits (`pw_mac_axis_cdc`
`RX_USER_W` widened 1→65: `{rx_wire_ts[63:0], fcs_err}`, the FCS/runt error kept
at bit 0 so the FIFO's bad-frame mask is unchanged) — so it stays glued to its
frame across the CDC. `pw_parser_axis` carries `rx_wire_ts` through its 3 stages
aligned with `key_valid_o`; the data plane delays it the same 4 cycles as the
key and feeds it to the RX checker as the "now" — so checker latency =
`rx_wire_ts − tx_timestamp` = **wire-to-wire**, free of the store-and-forward
FIFO + parser + classifier pipeline delay (frame-size independent; the two
Gray-CDC fixed offsets cancel). The same stamp is the servo-facing RX event time
in the punt metadata (RX_TS regs). The dp_clk→rx_clk crossing is constrained in
`xdc/phase3_cdc.xdc` exactly like the egress CDC (per-port `set_max_delay
-datapath_only` + `set_bus_skew`, TIMING-6/7 waived). On a single card the gain
is modest (loopback jitter is already ~0); the real payoff is cross-card one-way
latency, where the two cards share a time base via the J5 GPIO sync.

**Cross-card latency HW correction (per-flow `lat_correction`).** The two cards'
free-running counters differ by an inter-card offset (the J5 GPIO sync measures
it), so a raw cross-card latency `rx_wire_ts_B − tx_ts_A` is in the wrong
timebase (it even wraps negative). The RX checker takes a signed 64-bit
`lat_correction_i` and computes `lat = (rx_wire_ts + lat_correction) − tx_ts`, so
it accumulates the **true** one-way latency *per sample* — min/max/sum and the
histogram all bin the corrected value. This replaces the earlier SW read-time
single-offset correction, which left min/max/avg smeared by the ~1.6 ppm skew.
**Per-flow (Stage 2):** the data plane holds a `lat_corr_table[NUM_FLOWS]`
(written by the CSR window `0x0180 + slot*8`, atomic LO-stage/HI-commit). For
each classified TEST_RX event it looks up `corr[local_flow_id]` and — crucially,
to hold dp_clk timing — **registers it (with the key/wts/result) one extra cycle
(+5) before the checker**, so the 16:1 table mux is off the checker's
latency-calc cone (stage-0 was already +0.17 tight); the SAF/drop/punt consumers
stay at +4. Per-flow means one RX card can mix same-card flows (slot corr 0) with
cross-card flows from different TX cards (each slot its own offset) — lifting the
Stage-1 single-global-per-card restriction. The daemon servo re-writes cross-card
slots every `-S` ms (residual ≈ skew × period); same-card slots stay 0 →
bit-identical to the uncorrected path. The free-running counter itself is
**never** stepped (Gray-CDC safe); only this latency computation is disciplined.

## Top-level module hierarchy (original design sketch)

```
pwfpga_top
+-- pcie_endpoint                  PCIe Gen3 x8 Xilinx IP wrapper
|   +-- bar_csr                    AXI-Lite slave -> CSR fabric
|   +-- slow_path_rx_dma           (Phase 2)
|   +-- slow_path_tx_dma           (Phase 2)
|
+-- csr_fabric                     register decode, write-1-to-clear,
|                                  shadow / commit logic
|   +-- regfile_top
|   +-- classifier_table_window
|   +-- flow_table_window
|   +-- stats_snapshot_window
|   +-- histogram_window
|   +-- slow_path_ring_window
|
+-- timestamp_unit                 free-running 64-bit counter,
|                                  exposed at 0x0108/0x010c
|
+-- port[0]
|   +-- gty_wrapper                GTY quad, 10.3125 Gbps line
|   +-- mac_pcs_10gbaser           10GBASE-R MAC + PCS
|   +-- rx_pipeline
|   |   +-- parser
|   |   +-- classifier
|   |   +-- test_rx_checker
|   |   +-- punt_queue             slow-path RX FIFO (->PCIe)
|   |   +-- per_port_counters
|   |
|   +-- tx_pipeline
|   |   +-- flow_gen_array         N TX flow generators
|   |   +-- tx_arbiter             token-bucket + slow-path priority
|   |   +-- slow_path_tx_fifo      from PCIe
|   |   +-- per_port_tx_counters
|
+-- port[1]                        same as port[0]
|
+-- shared
    +-- flow_table_ram             RAM holding per-flow config / state
    +-- classifier_table_ram       RAM holding classifier rules
    +-- counters_ram               per-flow counter array
    +-- histogram_ram              per-flow latency histogram
```

## Module responsibilities

### pcie_endpoint / bar_csr

- Wrap the Xilinx PCIe Gen3 hard IP.
- Expose BAR0 as a 64 KB CSR space (AXI-Lite).
- Implement the read-latch behaviour for 64-bit counter pairs
  (`_low` read latches `_high`).
- No DMA in Phase 1. Phase 2 adds slow-path RX / TX DMA rings.

### csr_fabric

- Register decode and per-register access policy (`RW`, `R`, `W1C`, `W`).
- Stage / commit logic for the classifier and flow table windows.
- Drives `global_status`, snapshots `timestamp_unit` into the
  `timestamp_*` registers on read.

### timestamp_unit

- 64-bit free-running counter at the MAC clock (or a fixed shared
  reference).
- Used by `test_rx_checker` for ingress latency stamping and by
  `flow_gen` for egress `tx_timestamp` insertion.
- **Local to a single card.** Cross-card latency is meaningless until a
  future `CAP_HAS_TIMESTAMP_SYNC` capability is added.

### gty_wrapper / mac_pcs_10gbaser

- Bring up GTY transceivers for 10.3125 Gbps.
- Standard 10GBASE-R PCS / MAC.
- Expose link state, block-lock, RX fault to `port[N]_status`.
- Phase 1 deliverable: stable link over a DAC.

### SFP I2C management (`REG_SFP_I2C`)

- Per-cage open-drain 2-wire bus (SCL/SDA on C13/C14 for SFP0, D10/D11 for SFP1)
  brought out through board-top IOBUFs. No hardware I2C controller: the CSR
  exposes a drive-low bit + a synchronised pad-in bit per line, and software
  bit-bangs the protocol (reads are on-demand and low-rate). Pad inputs are
  2FF-synced into the CSR clock; the lines idle high via PULLUP.
- Used to read the SFP module EEPROM — identifier / vendor / part / bit-rate
  (0xA0 base ID) and, for DDM-capable optics, live DOM (temperature, Vcc, TX
  bias, TX/RX optical power at 0xA2). SW: `libpacketwyrm/sfp.{c,h}` + the
  `pw_sfp` tool. A passive DAC answers the ID page but has no optical DOM.

### Front-panel status LEDs

- `led_hb` = 1 Hz heartbeat (FPGA alive); `led[1]` = PCIe link up; per-cage
  `sfp_led[0..1]` = SFP link status (`!rx_status`).
- `led_r`/`led_g` (A13/A12, active-low bicolor) = **data-plane health**, NOT link
  (the SFP LEDs cover link). The data plane aggregates two dp_clk-domain levels:
  `err_sticky` (latched on any checker loss-event / RX FCS / port drop since the
  last `stats_clear`) and `activity` (a retriggerable one-shot reloaded on each
  RX/TX frame). The board top 2FF-synchronises them + `pcie_link_up` into the
  100 MHz LED domain: red = up & error; green blink = up & clean & active; green
  solid = up & clean & idle; off = not up (red overrides green).

### rx_pipeline / parser

The parser must reach into at least:

- Ethernet header.
- 802.1Q VLAN (single tag).
- 802.1ad QinQ (optional, capability bit).
- ARP.
- IPv4 (and option skip / drop on options).
- IPv6 (fixed header; ND through IPv6 + ICMPv6).
- UDP, TCP.
- ICMP, ICMPv6.
- LLDP (ethertype 0x88cc).
- OSPF (IP protocol 89).
- BGP TCP destination port 179.
- IS-IS (optional, capability bit).
- LACP (optional).

Output: a flat "header descriptor" with all extracted fields plus a
"hit indicator" for the test header magic.

### classifier

The legacy priority-ordered linear `pw_classifier` (N×~600-bit parallel masked
key compare) is **retired** — it was the xcku3p route wall (~16 entries). It is
replaced by `pw_field_classifier` (see below), with structured high-count
TEST_RX on `pw_flowid_map`. Actions are unchanged: `DROP`, `TEST_RX`,
`PUNT_TO_HOST`, `MIRROR_TO_HOST`, `FORWARD_PORT`.

### hash_classifier (`pw_hash_classifier`)

- Header-keyed exact classification scaling to `NUM_FLOWS`, payload-agnostic
  (no test `flow_id`). Lifts the header-defined-flow cap from the field
  classifier's ~`NCMP` to the checker ceiling.
- Direct-indexed BRAM hash table — **1 read + 1 compare**, not an N-way parallel
  match, so it routes: assemble a **wide** key — 11 field-aligned 32-bit words
  covering the full IPv4/IPv6 5-tuple + VLAN + ethertype — from the parser's
  canonical fields; AND a **global key mask**; XOR-fold to 32 bits; bucket =
  `(k32 * (seed|1)) >> (32-log2 DEPTH)` (Dietzfelbinger multiply-shift); read
  `mem[bucket]`; hit = `valid && stored_key == masked_key` (FULL masked-key
  verify, so no misclassification — the hash only picks the bucket). Latency 4:
  register stages split key→assemble→mask | →XOR-fold | →multiply→BRAM-address so
  no two of those land in one dp_clk cone (the fold+multiply→BRAM cone was the
  dp_clk-critical path); the data plane realigns the field + flow-id-map results
  to match.
- The global key mask (ANDed into hash input + verify) selects which bits
  participate; masking a field/bits lets a generator **modifier randomize** them
  while the flow still classifies. SW computes the identical hash + key + mask,
  builds the mask (relaxing modifier-randomized / match-narrowed bits), and
  searches a **seed** that places the masked keys collision-free. The compiler
  routes `classify: header` flows here; the field classifier carries punt/
  forward. CSR: `PWFPGA_WIN_FC_HASH` @ 0x3000 + mask window @ 0x2F00 + seed reg.

### flowid_map (`pw_flowid_map`)

- Scalable TEST_RX classification: a test frame's parsed `test_flow_id`
  directly indexes a BRAM table (`PWFPGA_WIN_FLOWID_MAP` @ 0x0400) →
  `{valid, local_flow_id}`, gated by the parser's magic/`is_test`. No
  per-flow comparators, so the test-flow count scales with the BRAM
  (`MAP_DEPTH`) and the checker (`NUM_FLOWS`), not classifier routability.
- The data plane combines: a map hit overrides the classifier result with
  `TEST_RX @ mapped slot` (aligned to the classifier's latency); otherwise the
  classifier result stands. All consumers (checker / SAF / drop) use the
  combined `rx_eff`.
- Programmed before traffic via the CSR window (the compiler emits one entry
  per TEST_RX flow). Keying on the stable `flow_id` makes header-field modifiers
  irrelevant to RX classification. The high-count fast path for *structured*
  test frames — see `docs/design/generic-classifier.md`.

### field_classifier (`pw_field_classifier` + `pw_slice_match`)

Replaces the legacy `pw_classifier` (an N×~600-bit parallel masked-key compare
that hit the xcku3p route wall at ~16 entries) AND the interim slice classifier.
Two cheap, routable stages:

- **Comparators** (the cheap part): `NCMP` (12) *field comparators*, each a
  `{src,mask,value}` over a 32-bit lane selected from the parser's canonical
  fields (`pw_match_key_t`). The fields are already extracted + position-
  normalized by the parser, so a comparator is a mux-of-fixed-lanes + a masked
  compare — **no byte-mux over the raw frame**. A 128-bit IPv6 address is matched
  with 4 comparators over its 4 lanes. Plus `NUDF` (2) *UDF comparators*
  (`pw_slice_match`) over the raw inner-frame window for fields the parser
  doesn't name (DSCP/TTL/flow-label/TCP-flags/arbitrary bytes); bounded byte-mux
  (`SLICE_WIN` = 48). → NCMP+NUDF match bits.
- **Rules** (the scalable part): `NRULE` (32), each `{care, action, egress,
  local_flow_id, logical_if_id, prio, enable}`. A rule hits iff enabled & valid &
  `(cmatch & care) == care`; priority winner. Per-rule compare is only NCMP+NUDF
  bits, so NRULE scales far past the legacy ~16 wall. Latency 2.
- Handles every action the legacy classifier did (TEST_RX / PUNT / MIRROR /
  FORWARD / DROP). **Retiring the legacy 600-bit classifier frees the RX-region
  routing budget**, which is what lets the engine + the 32-flow data plane fit on
  the xcku3p. Payload-agnostic: a header-classified flow carries no dependency on
  the test `flow_id`.
- Data-plane precedence: flow-id **map > field classifier**. Programmed via
  `PWFPGA_WIN_FC_CMP` / `_UDF` / `_RULE` (0x2000); the compiler lowers
  `classify: header` test flows + punt + forward to comparators + rules, while
  structured high-count TEST_RX rides the map. See
  `docs/design/generic-classifier.md`.

### test_rx_checker

- Triggered on `TEST_RX` action.
- Counts `rx_frames` for **every** classified frame; sequence (loss/dup/ooo)
  and latency/jitter are derived only when the frame carries a test header
  (`is_test`). So a header-defined flow with arbitrary payload (slice-classified,
  no test header) still gets frame counts — loss is then the tx-vs-rx count
  difference — while structured test frames get full stats.
- Verifies the `pwfpga_test_hdr` magic.
- Tracks per-flow expected sequence, increments
  `lost / duplicate / out_of_order / late` counters.
- Computes `rx_timestamp - tx_timestamp` (both from this card's
  `timestamp_unit`) and updates min / max / sum / sample_count plus
  the histogram bin.
- Per-flow IPDV jitter (RFC-3393): tracks the previous sample's latency
  and accumulates `|latency[n] - latency[n-1]|` into jitter min / max /
  sum (the first sample of a flow only seeds `prev_latency`). Surfaces in
  the flow stats block at jitter_min@104 / jitter_max@108 / jitter_sum@112.
- Cross-card flows are corrected per sample in hardware: the checker computes
  `lat = (rx_wire_ts + lat_correction) - tx_ts`, where the daemon servo keeps
  `lat_correction` at the inter-card offset (J5 GPIO sync). So min/max/sum and
  the histogram hold the true one-way latency for cross-card too; the daemon
  reports `latency_valid = true` with `latency_method = "gpio-corrected"`
  (same-card runs with `lat_correction = 0`). See the "Cross-card latency HW
  correction" note above.

### punt_queue

- Slow-path RX FIFO from RX pipeline to PCIe.
- Per-packet metadata: `logical_if_id`, ingress `local_port_id`,
  ingress timestamp (low 32 bits), action source.
- Backpressures into the RX pipeline only after dropping per the
  classifier's overflow policy (initial: drop and bump
  `punt_drop_counter`).

> **As-built (Phase 3):** implemented as `pw_punt_rx_window` — the punt
> AXIS (PUNT/MIRROR frames from the SAF, which carries `logical_if_id` +
> ingress port as metadata) drains into a single-frame buffer the host
> polls over the CSR BAR (`PWFPGA_WIN_PUNT_RX`); no DMA. `byte_len`,
> `ingress_port`, `logical_if_id`, the frame words and an `overflow` flag
> are exposed; `bar_slow_path_rx` drains it. See `docs/design/csr-map.md`.

### flow_gen_array / tx_arbiter

- N parallel flow generators, each reading one row of the flow table.
- Per-flow token-bucket rate limit (bps and pps).
- Per-port aggregate token bucket on top.
- Slow-path TX FIFO is mixed in at high priority (subject to its own
  rate limit so it cannot starve test traffic either).
- Generators inject the `pwfpga_test_hdr` if `insert_sequence` /
  `insert_timestamp` are set.
- Strict respect of minimum IFG; cannot generate runt frames.

### per_port_counters / counters_ram / histogram_ram

- Per-port counters live next to the MAC.
- Per-flow counters + histogram bins live in BRAM, addressed by
  `local_flow_id`.
- Snapshot to a shadow region on `stats_snapshot_trigger` so the host
  reads a consistent set of counters.

## Build / project layout

`fpga/as02mc04/` contains:

```
fpga/as02mc04/
+-- project.tcl              Vivado project create script
+-- xdc/
|   +-- timing.xdc
|   +-- pinout.xdc
|   +-- physical.xdc
+-- ip/                      Xilinx IP wrappers (GTY, PCIe, MAC)
+-- src/                     board-support RTL (clocking, reset, LEDs)
+-- bd/                      block design (if used)
+-- constraints/             non-pin constraints
+-- README.md
```

Shared, board-agnostic RTL (parser, classifier, flow_gen, csr_fabric,
test_rx_checker) lives in `rtl/` and is included by the AS02MC04
project. Future 25G or alternate boards reuse the same `rtl/`.
