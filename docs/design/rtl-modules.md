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
+-- STARTUPE3  + pw_ts_gray_cdc + pw_ts_insert   egress HW timestamping
+-- ICAPE3     <- pw_icap_reboot                 in-band IPROG reload
+-- pwfpga_top_phase3            board-agnostic core
    +-- pw_csr_full              AXI-Lite slave: identity + windows +
    |   +-- pw_classifier_window /  pw_stats_snapshot  (flow table moved to
    |   |                            the data plane; csr_full just forwards the
    |   |                            decoded flow-window write strobe)
    |   +-- pw_spi_flash         CSR SPI master (live config-flash access)
    |   +-- DP_RESET / REBOOT / STATS_CLEAR / SNAPSHOT triggers
    +-- pw_punt_rx_window        punt AXIS -> CSR-polled frame buffer (host RX)
    +-- pw_inject_tx_window      CSR frame buffer -> AXIS into egress (host TX)
    +-- pw_data_plane_axis       64-bit AXIS streaming data plane
        +-- pw_flow_table_bram   BRAM flow table (commit-walk decode; per-port
        |                        read port + compact scheduling FF array)
        +-- per ingress port: pw_parser_axis -> pw_classifier (RESULT_STAGES=2,
        |                      non-test rules only) + pw_flowid_map (TEST_RX
        |                      flow_id -> checker slot) -> pw_frame_saf (S&F)
        +-- per ingress port: pw_test_rx_checker (loss/dup/ooo/min/max/sum +
        |                      RFC-3393 IPDV jitter min/max/sum)
        +-- link health: per-port 2-FF sync + edge count of MAC link_up /
        |                block_lock; FCS errors from RX tuser-on-tlast
        +-- pw_lat_histogram     shared BRAM latency histogram
        +-- per egress port:  pw_flow_gen_multi (N-slot token-bucket gen)
        +-- egress / punt arbiters
```

Module notes: `pw_parser_axis` is pipelined (3-stage: L2+decap-descent / inner L3-L4 / test extract) and
auto-decapsulates recognized tunnels (outer IP proto 4/41/47/97 →
IPIP/GRE/EtherIP), re-basing the L3/L4 parse onto the inner frame so the
classifier keys on the inner test flow (header capture grew to 160 B);
`pw_classifier` uses RESULT_STAGES + a parallel priority winner;
`pw_lat_histogram` replaced the FF histogram; `pw_frame_saf`
is BRAM-backed (reset-less write + registered read-ahead drain) — freed
~24% FF / ~14% LUT vs the former register array. `pw_flow_gen_multi`
applies per-field modifiers (static/increment/random + bitmask on
src/dst IPv4 (or IPv6 low 32 bits) + UDP ports + src/dst MAC (48-bit) +
VLAN ID, driven by the slot sequence so the DUT sees
many flows while the fixed test header keeps measurement intact), emits
a correct IPv4 header checksum, and can emit IPv6/UDP frames (0x86DD,
40-byte header) for IPv6 flow rows (the flow-table row stride is 256 B to
carry the 16-byte addresses). For IPv6 it emits a *partial* UDP checksum
(the mandatory pseudo-header + UDP + payload sum, **minus** the
tx_timestamp); `pw_ts_insert` folds the departure stamp in (see below).
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
byte). `HDR_MAX_BYTES` grew to 176 to hold the deepest layout (v6-outer
EtherIP v6-inner + VLAN = 154 B). The inner UDP checksum is unchanged (over
the inner addresses), so egress timestamping still works at the deep offset.
`pw_flow_table_bram` holds the flow table in **block RAM** (in the data
plane, next to the generators). The old approach — a 32-wide registered
`pw_flow_row_t` array (`flow_rows_o`) fanning out to both generators, each
muxing the picked row 32:1 — was the routing wall once encap widened the row
(~92% LUT, unroutable). Instead: the CSR shadow/commit is unchanged, but on
commit a single decoder **walks** the committed rows (one per cycle) into a
per-generator BRAM copy plus a compact per-slot scheduling FF array
(`flow_sched`: valid/egress/tokens/cap/cost). Each generator schedules from
`flow_sched` (all slots, every cycle) and reads only its **picked** row from
BRAM (`rd_addr`→`rd_row`, 1-cycle, same latency the old register mux had). The
decode happens once (not ×32 in parallel), the wide register array + fan-out
are gone, and the 32:1 mux became a BRAM read — LUT 92%→87%, FF 78%→66%, +34
RAMB36. (BRAM inference needs a flat bit-vector mem read into an internal reg;
a struct-array mem or reading into the output port maps to FFs.) The legacy
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
stable lane. For IPv6 (inner) it also **finalizes the UDP checksum**: it adds
the four departure-stamp 16-bit words to the generator's partial checksum and
writes the result to the UDP csum field (@60 non-encap, +4 VLAN, or the inner
offset for a tunnel), applying the RFC 768 `0→0xFFFF` rule. This one-pass fixup works because the csum field
leaves before the tx_ts field, so only the (SOF-latched) *new* stamp is
needed, never the old one. Which frames to rewrite is gated by a
"generator test frame" marker the egress arbiter raises (`sel_gen`),
carried as AXIS `tuser` through the MAC-TX CDC — so forwarded / injected
frames (including genuine IPv6/UDP DUT traffic) are never touched. That
`tuser` is consumed here; the MAC sees `m_tuser=0` (no tx-error).

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

- Priority-ordered linear table (Phase 1).
- **TEST_RX flows are NOT in the classifier** — they are classified by
  `pw_flowid_map` (below), so the classifier carries only the few non-test
  rules (PUNT/FORWARD/DROP) and stays small (16 entries) and routable. A wider
  parallel match is route-congestion-bound on the xcku3p (~16 is the wall);
  moving the many per-flow TEST_RX rules out is what lifts the flow ceiling.
- Each entry: match key + mask, action, priority,
  `local_flow_id`, `logical_if_id`, `egress_local_port`.
- The dst port (`l4_dst`/`udp_dst`) and dst IPv4 address match **bitwise**
  (TCAM-style): `(key & mask) == (rule_key & mask)`, so a partial mask
  matches only part of a field — letting a generator modifier rotate the
  unmatched bits, or classifying arbitrary-payload traffic by header bits.
  An all-ones mask is exact match (back-compatible); 0 is wildcard. Other
  fields remain boolean match/ignore.
- **IPv6 dst address** matches **exactly** (`==`, not bitwise): the 40-byte
  wire `match_key` has no room for a 128-bit address, so the dst key + mask
  live in the row tail (bytes 96..127, decoded by `pw_classifier_window` in
  network byte order to match the parser). The compiler enables it for IPv6
  TEST_RX flows unless a dst modifier rotates the address.
- Actions: `DROP`, `TEST_RX`, `PUNT_TO_HOST`, `MIRROR_TO_HOST`,
  `FORWARD_PORT`.
- `FORWARD_PORT` uses `egress_local_port` (byte 92 of the wire row,
  decoded in `pw_classifier_window`) to pick the egress port the SAF
  drains to; the data plane routes by the result's `egress_port`. See
  `docs/design/csr-map.md` (classifier window).
- Double-buffered: stage row, then write `commit` to swap.
- Returns the matched action + IDs to the rest of the RX pipeline.

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
  irrelevant to RX classification. First back-end of the generic slice
  classifier — see `docs/design/generic-classifier.md`. The flexible front-end
  (`pw_slice_match`, programmable offset/mask/value extractor) is also landed.

### test_rx_checker

- Triggered on `TEST_RX` action.
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
- Cross-card flows still hit `test_rx_checker`; daemon flags
  `latency_valid = false` on those flows and the host does not surface
  the (invalid) latency numbers.

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
