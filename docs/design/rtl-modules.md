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
    |   +-- pw_classifier_window /  pw_flow_window /  pw_stats_snapshot
    |   +-- pw_spi_flash         CSR SPI master (live config-flash access)
    |   +-- DP_RESET / REBOOT / STATS_CLEAR / SNAPSHOT triggers
    +-- pw_punt_rx_window        punt AXIS -> CSR-polled frame buffer (host RX)
    +-- pw_inject_tx_window      CSR frame buffer -> AXIS into egress (host TX)
    +-- pw_data_plane_axis       64-bit AXIS streaming data plane
        +-- per ingress port: pw_parser_axis -> pw_classifier (RESULT_STAGES=2)
        |                      -> pw_frame_saf (store-and-forward)
        +-- per ingress port: pw_test_rx_checker (loss/dup/ooo/min/max/sum)
        +-- pw_lat_histogram     shared BRAM latency histogram
        +-- per egress port:  pw_flow_gen_multi (N-slot token-bucket gen)
        +-- egress / punt arbiters
```

Module notes: `pw_parser_axis` is pipelined (2-stage key extract);
`pw_classifier` uses RESULT_STAGES + a parallel priority winner;
`pw_lat_histogram` replaced the FF histogram; `pw_ts_insert` overwrites
the tx_timestamp at egress so latency measures the DUT. The wide-bus
`pw_data_plane` / `pw_parser` / `pw_flow_gen` remain only for the legacy
sim (`tb_data_plane`).

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
- Each entry: match key + mask, action, priority,
  `local_flow_id`, `logical_if_id`, `egress_local_port`.
- Actions: `DROP`, `TEST_RX`, `PUNT_TO_HOST`, `MIRROR_TO_HOST`,
  `FORWARD_PORT`.
- `FORWARD_PORT` uses `egress_local_port` (byte 92 of the wire row,
  decoded in `pw_classifier_window`) to pick the egress port the SAF
  drains to; the data plane routes by the result's `egress_port`. See
  `docs/design/csr-map.md` (classifier window).
- Double-buffered: stage row, then write `commit` to swap.
- Returns the matched action + IDs to the rest of the RX pipeline.

### test_rx_checker

- Triggered on `TEST_RX` action.
- Verifies the `pwfpga_test_hdr` magic.
- Tracks per-flow expected sequence, increments
  `lost / duplicate / out_of_order / late` counters.
- Computes `rx_timestamp - tx_timestamp` (both from this card's
  `timestamp_unit`) and updates min / max / sum / sample_count plus
  the histogram bin.
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
