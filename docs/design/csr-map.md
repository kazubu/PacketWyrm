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

A double-buffered row table. Each row is a packed
`struct pwfpga_classifier_entry` (see
`sw/libpacketwyrm/include/packetwyrm/csr.h`) at:

```
PWFPGA_WIN_CLASSIFIER + row_index * PWFPGA_CLASSIFIER_STRIDE  (128 bytes)
```

A write-1-to-commit register lives at the last dword of the
window:

```
PWFPGA_REG_CLASSIFIER_COMMIT = PWFPGA_WIN_CLASSIFIER + 0xFFC
```

The shadow table holds the staged entry; writing 1 to
`CLASSIFIER_COMMIT` atomically swaps the staged entry into the
live row. Mid-update classifier lookups always see either the
previous or the new entry, never a torn one.

Each row carries a 16-bit `flags` field. Currently defined:

| Bit | Name                    | Meaning                          |
|----:|-------------------------|----------------------------------|
|   0 | `PWFPGA_CLS_FLAG_ENABLE`| row is live; the RTL ignores any row with this bit clear |

The host must set `PWFPGA_CLS_FLAG_ENABLE` for every active row.
Clearing the bit on a re-commit takes the row out of the lookup
without disturbing any other entry.

The RTL side of the window is implemented by
`rtl/shared/pw_csr_window.sv` (generic shadow + commit) and
`rtl/phase3/pw_classifier_window.sv` (wire-format ↔
`pw_classifier_table_t` adapter). See
`sim/csr_window_tb/tb_csr_window.sv` for the end-to-end test that
drives AXI-Lite writes into the window and verifies the data
plane classifies according to the committed table.

## Flow table window

Each row is a packed `struct pwfpga_flow_config` at:

```
PWFPGA_WIN_FLOW_TABLE + row_index * PWFPGA_FLOW_STRIDE  (128 bytes)
```

Commit register at:

```
PWFPGA_REG_FLOW_COMMIT = PWFPGA_WIN_FLOW_TABLE + 0xFFC
```

## Stats snapshot window

```
PWFPGA_REG_STATS_SNAPSHOT_TRIGGER  = PWFPGA_WIN_STATS_SNAPSHOT + 0xFFC
   W     write 1 to copy live counters into the shadow region

per-port block (read-only after snapshot):
   PWFPGA_WIN_STATS_SNAPSHOT + N * PWFPGA_PORT_STATS_STRIDE  (128 B)
   N = 0..PW_PORTS_PER_CARD-1
   layout = `struct pw_port_stats`

per-flow block (read-only after snapshot):
   PWFPGA_WIN_STATS_SNAPSHOT + PWFPGA_FLOW_STATS_BASE
                              + N * PWFPGA_FLOW_STATS_STRIDE
   N = local_flow_id (0..num_local_flows-1)
   layout = `struct pw_flow_stats`
```

`STATS_SNAPSHOT_TRIGGER` causes the FPGA to copy all live per-flow
counters into the shadow region in a single cycle. Host reads the
shadow region, not the live counters. This makes
`pktwyrm stats --watch` consistent across many flows.

## Histogram window

```
PWFPGA_WIN_HISTOGRAM + N * PWFPGA_FLOW_HIST_STRIDE  (512 B = 64 bins)
   N = local_flow_id

Bin layout: 64 power-of-two buckets keyed off log2(latency)
(matches `pw_test_rx_checker` in `rtl/phase3/`). Buckets are u64
each; the stride leaves room for 64 of them.
```

Concrete strides and offsets are defined as preprocessor macros
in `sw/libpacketwyrm/include/packetwyrm/csr.h` and used by the
host BAR backend.

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
