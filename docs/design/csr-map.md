# CSR / register map

All control / status registers live in **BAR0**. Phase 1 ships BAR-only
access; Phase 2 adds a slow-path DMA ring (TX and RX). The map below is
the initial proposal; concrete field bit definitions are owned by the
`fpga/as02mc04/` sources and the matching `libpacketwyrm` headers.

## Conventions

- All registers are 32-bit. 64-bit counters occupy a `_low` / `_high`
  pair where `_low` must be read first, then `_high`; the FPGA latches
  `_high` when `_low` is read so the pair is snapshot-atomic.
- All multi-byte fields are little-endian.
- Error / status registers are **write-1-to-clear**.
- Reserved fields read as zero and must be written as zero.
- Tables (classifier / flow / stats / histogram) are accessed through
  windowed regions: an address register selects the row, then data
  registers expose the row contents.
- Every table that affects packet processing **must** be updated via a
  double-buffered or commit-bit scheme. Mid-write classifier reads
  never observe a half-updated entry.

## Top-level map

```
0x0000  device_id              R     0x000041C5 / vendor-defined
0x0004  version                R     {major[31:24], minor[23:16], patch[15:0]}
0x0008  build_id               R     opaque build identifier
0x000c  git_hash               R     low 32 bits of git SHA
0x0010  capabilities           R     bitmask, see below
0x0014  num_local_ports        R     usually 2
0x0018  num_local_flows        R     flow table depth
0x001c  num_logical_interfaces R     classifier punt-tag depth
0x0020  num_classifier_entries R
0x0024  num_histogram_bins     R     per-flow latency histogram bins
0x0028  capability_ext         R     reserved for future bits

0x0100  global_control         RW    [0] enable, [1] arm, [2] reset_counters
0x0104  global_status          R     [0] ready, [1] armed, [2] running,
                                     [3] error, [4] degraded
0x0108  timestamp_low          R     FPGA timestamp counter, snapshot pair
0x010c  timestamp_high         R
0x0110  error_status           W1C   sticky error bits
0x0114  irq_status             W1C   sticky interrupt sources (future)
0x0118  irq_mask               RW    interrupt mask (future)

0x0200  port0_control          RW    [0] enable, [1] reset, [4] loopback
0x0204  port0_status           R     [0] link_up, [1] block_lock,
                                     [2] sfp_present, [3] rx_fault
0x0208..0x02fc port0 stats     R     see "port stats block"
0x0300  port1_control          RW
0x0304  port1_status           R
0x0308..0x03fc port1 stats     R

0x1000..0x1fff  classifier_table_window
0x2000..0x2fff  flow_table_window
0x3000..0x3fff  stats_snapshot_window
0x4000..0x4fff  histogram_window

0x8000..0x8fff  slow_path_rx_ring_control
0x9000..0x9fff  slow_path_tx_ring_control
```

`capabilities` bits (initial proposal):

| Bit | Name                  | Meaning                                  |
|----:|-----------------------|------------------------------------------|
|   0 | CAP_HAS_DMA           | slow-path DMA ring implemented           |
|   1 | CAP_HAS_MSIX          | MSI-X interrupts implemented             |
|   2 | CAP_HAS_HISTOGRAM     | per-flow latency histograms implemented  |
|   3 | CAP_HAS_QINQ_PARSER   | QinQ parser implemented                  |
|   4 | CAP_HAS_TIMESTAMP_SYNC| cross-card timestamp sync available      |
|   5 | CAP_HAS_MIRROR        | classifier `MIRROR_TO_HOST` implemented  |

## Port stats block (per port)

Each block is `0xF8` bytes; counters are 64-bit pairs.

```
+0x00 rx_frames_low / +0x04 rx_frames_high
+0x08 rx_bytes_low  / +0x0c rx_bytes_high
+0x10 rx_fcs_error_low / +0x14 _high
+0x18 rx_bad_frame_low / +0x1c _high
+0x20 rx_oversize_low  / +0x24 _high
+0x28 rx_undersize_low / +0x2c _high
+0x30 tx_frames_low / +0x34 _high
+0x38 tx_bytes_low  / +0x3c _high
+0x40 link_up_count        (u32)
+0x44 link_down_count      (u32)
+0x48 block_lock_loss      (u32)
+0x4c reserved
```

Reading the `_low` of a counter latches its `_high` into a shadow
register so the next read of `_high` returns the matched value.

## Classifier table window

```
classifier_addr      RW     row index
classifier_match_*   RW     match key (ethertype, vid, l3 proto,
                            udp ports, ipv4 src/dst, mac src/dst,
                            test_magic, ingress_local_port)
classifier_mask_*    RW     match mask (same layout as key)
classifier_action    RW     action enum + priority + flags
classifier_local_flow_id RW
classifier_logical_if_id RW
classifier_commit    W      1 = atomically swap shadow -> active
```

A double-buffered shadow table holds the staged entry; `commit` swaps
the staged entry into the live row. Mid-update classifier lookups
always see either the previous or the new entry, never a torn one.

## Flow table window

```
flow_addr            RW     row index
flow_enable          RW
flow_egress_local_port RW
flow_global_flow_id  RW     opaque tag passed through to test header
flow_local_flow_id   RW     usually equals row index but exposed for tooling
flow_logical_if_id   RW
flow_dst_mac_*       RW     6 bytes split across two registers
flow_src_mac_*       RW
flow_vlan            RW     [12:0] vid, [15:13] pcp, [16] vlan_enable
flow_ip              RW     src_ip, dst_ip, dscp, ttl, ip_version
flow_udp             RW     src_port, dst_port
flow_len             RW     min, max, step
flow_rate_bps_low / _high   RW
flow_rate_pps       RW
flow_burst          RW     burst_size + burst_gap_ticks
flow_payload        RW     payload_mode + payload_seed
flow_options        RW     [0] insert_sequence, [1] insert_timestamp,
                          [8] tx_enable, [9] rx_check_enable
flow_commit          W     1 = atomically activate this row
```

## Stats snapshot window

```
stats_snapshot_trigger W   write 1 to snapshot all per-flow counters
stats_addr             RW  row index
stats_tx_frames_l/h    R
stats_tx_bytes_l/h     R
stats_rx_frames_l/h    R
stats_rx_bytes_l/h     R
stats_expected_seq_l/h R
stats_seq_gap          R
stats_lost_est         R
stats_dup              R
stats_out_of_order     R
stats_late             R
stats_min_latency      R
stats_max_latency      R
stats_sum_latency_l/h  R
stats_sample_count_l/h R
stats_jitter_min       R
stats_jitter_max       R
stats_jitter_sum_l/h   R
```

`stats_snapshot_trigger` causes the FPGA to copy all live per-flow
counters into a shadow region in a single cycle. Host reads the shadow,
not the live counters. This makes `pktwyrm stats --watch` consistent
across many flows.

## Histogram window

```
hist_addr            RW   row index = local_flow_id
hist_bin_addr        RW   bin index
hist_bin_count_l/h   R    bin count (64-bit)
hist_bin_low_edge    R    bin low edge in ticks (read-only descriptor)
hist_bin_high_edge   R
```

Bin layout is fixed in RTL (e.g. 64 log-spaced bins between 100 ns and
1 ms). The host reads `hist_bin_low_edge` / `hist_bin_high_edge` once
per build and caches them by `build_id`.

## Slow-path DMA rings (Phase 2)

```
slow_rx_base_low/high  RW   descriptor ring physical base
slow_rx_size           RW   number of descriptors (power of two)
slow_rx_head           R    HW write index
slow_rx_tail           RW   SW read index
slow_rx_irq_coalesce   RW   coalesce window
slow_rx_enable         RW

slow_tx_base_low/high  RW
slow_tx_size           RW
slow_tx_head           RW   SW write index
slow_tx_tail           R    HW read index
slow_tx_enable         RW
```

Descriptor layout (`struct pwfpga_dma_desc`) and completion layout
(`struct pwfpga_dma_cpl`) are defined in
`sw/libpacketwyrm/include/packetwyrm/csr.h`.

Phase 1 may implement RX punt by polling a BAR-mapped circular buffer
without scatter-gather DMA. Phase 2 introduces real DMA descriptors.

## Snapshot atomicity rules

Three independent atomicity mechanisms exist:

1. **64-bit counter pairs** &mdash; `_low` read latches `_high`.
2. **Per-flow stats snapshot** &mdash; `stats_snapshot_trigger` copies all
   per-flow counters into a shadow region atomically.
3. **Table updates** &mdash; double buffer + `commit` register for
   classifier and flow tables; mid-update lookups never see torn rows.

All three are mandatory; counters that violate them give wrong numbers
under load and the bug is invisible from software.
