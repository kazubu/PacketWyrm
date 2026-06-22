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

0x0120  reboot                 W     write 0x52424F54 ("RBOT") -> ICAP IPROG
                                     (reload bitstream from flash; PCIe drops)

0x0800..0x0cff  spi_flash_window       in-system SPI flash master (live
                                       config-flash erase/program/read):
  0x0800  spi_ctrl   W:[0]go [1]cs_hold  R:[0]busy
  0x0804  spi_len    bytes to shift this transfer
  0x0900  spi_txbuf  512 B TX buffer
  0x0b00  spi_rxbuf  512 B RX buffer

# Slow-path TX inject window (host -> FPGA; pw_inject_tx_window)
0x0d00..0x0fff  inject_tx_window
  0x0d00  inject_ctrl  W:[0]go      R:[0]busy
  0x0d04  inject_info  W:[13:0]byte_len [19:16]egress_port
  0x0d40  inject_data  W: frame word i at +i*4 (little-endian; up to 512 B)

# Punt / slow-path RX window (FPGA -> host, BAR-polled; pw_punt_rx_window)
0x1000..0x1fff  punt_rx_window
  0x1000  punt_status  R:[0]frame_valid [1]overflow
  0x1004  punt_info    R:[13:0]byte_len [19:16]ingress_port
  0x1008  punt_lif     R: logical_if_id of the punted frame
  0x100c  punt_pop     W:1 -> release the current frame
  0x1010  punt_data    R: frame word i at +i*4 (little-endian; up to 2 KB)

# Wide table windows (64 flows / 64 classifier rows max). The
# commit-bearing windows are 16 KB apart so their commit / trigger /
# clear registers sit above the 8 KB data region; the live-read
# histogram gets 8 KB. Fills the 64 KB BAR.
0x0400..0x07ff  flowid_map_window         (TEST_RX flow-id -> checker slot;
                                           entry[flow_id] at +flow_id*4,
                                           data {[31]valid,[15:0]local_flow_id})
0x2000..0x5fff  classifier_table_window   (rows @128 B; commit @+0x3FFC)
0x6000..0x9fff  flow_table_window         (rows @256 B; commit @+0x3FFC)
0xa000..0xbfff  histogram_window          (per-flow @128 B = 16 bins; live read)
0xc000..0xffff  stats_snapshot_window     (trigger @+0x3FFC, clear @+0x3FF8,
                                           data-plane soft-reset @+0x3FF4)
```

The earlier compact map (classifier 0x1000 / flow 0x2000 / stats 0x3000
/ histogram 0x4000, 4 KB each) was replaced by the wide map above when
the design scaled past 8 flows. The histogram is BRAM-backed and read
live (no snapshot latch); its stride dropped 512 B -> 128 B (16 bins).
The former SLOW_RX/TX placeholders (0x8000 / 0x9000) were reclaimed.

`capabilities` bits:

| Bit | Name                  | Meaning                                  |
|----:|-----------------------|------------------------------------------|
|   0 | CAP_HAS_DMA           | slow-path DMA ring implemented           |
|   1 | CAP_HAS_MSIX          | MSI-X interrupts implemented             |
|   2 | CAP_HAS_HISTOGRAM     | per-flow latency histograms implemented  |
|   3 | CAP_HAS_QINQ_PARSER   | QinQ parser implemented                  |
|   4 | CAP_HAS_TIMESTAMP_SYNC| cross-card timestamp sync available      |
|   5 | CAP_HAS_MIRROR        | classifier `MIRROR_TO_HOST` implemented  |
|   6 | CAP_HAS_PUNT          | slow-path punt RX + TX-inject windows    |

> **Note:** the Phase 3 board top advertises `PW_PHASE3_CAPABILITIES`
> = `0x0000_006C` (HISTOGRAM | QINQ_PARSER | MIRROR | PUNT — the features
> implemented in the data plane; DMA / MSI-X / cross-card timestamp sync
> stay clear). Software does not currently gate on these bits.

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
PWFPGA_REG_CLASSIFIER_COMMIT = PWFPGA_WIN_CLASSIFIER + 0x3FFC
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

For a `FORWARD_PORT` action, `egress_local_port` (byte 92 of the row,
just past `flags`) selects the egress port the matched frame is
store-and-forwarded to. The data plane already routed by the
classifier result's `egress_port`; this byte is what carries the
host's choice into it (earlier bitstreams hardwired it to 0). Ignored
for non-FORWARD actions.

The inner **IPv6 dst-address** match lives in the row tail: `ipv6_dst`
(bytes 96..111) + `ipv6_dst_mask` (bytes 112..127), network byte order.
The 40-byte `pwfpga_match_key` has no room for a 128-bit address, so this
sits outside the key/mask sub-structs (the entry was 96 B of the 128 B
stride). `pw_classifier_window` OR-reduces the mask to the single
`match_ipv6_dst` enable bit; the compare is exact (`==`), not bitwise.

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
PWFPGA_WIN_FLOW_TABLE + row_index * PWFPGA_FLOW_STRIDE  (256 bytes)
```

The row stride grew from 128 B to **256 B** so each row can carry two
16-byte IPv6 addresses alongside the IPv4 fields. The generator picks the
L3 family from the row's `ip_version` (4 → 20-byte IPv4 header, ethertype
0x0800; 6 → 40-byte IPv6 header, ethertype 0x86DD with a mandatory,
non-zero UDP checksum). The row also carries per-field **modifier**
descriptors (mode + mask for `src/dst_ipv4` (or IPv6 low-32), `udp_src/dst`,
`src/dst_mac` (48-bit) and `vlan`) and, optionally, an **encapsulation**
block (bytes 157..213): `encap_type` (IPIP/GRE/EtherIP), `outer_ip_version`
+ outer L3 addresses / TTL / DSCP, `rx_expect`, and an EtherIP inner-Ethernet
MAC. All of this is decoded in `pw_flow_window.sv`; the exact byte offsets are
the packed `struct pwfpga_flow_config` in `csr.h` (authoritative).

Commit register at:

```
PWFPGA_REG_FLOW_COMMIT = PWFPGA_WIN_FLOW_TABLE + 0x3FFC
```

## Stats snapshot window

```
PWFPGA_REG_STATS_SNAPSHOT_TRIGGER  = PWFPGA_WIN_STATS_SNAPSHOT + 0x3FFC
   W     write 1 to copy live counters into the shadow region
PWFPGA_REG_STATS_CLEAR             = PWFPGA_WIN_STATS_SNAPSHOT + 0x3FF8
   W     write 1 to soft-clear all RX checker counters (re-baseline; `test arm`)
PWFPGA_REG_DP_RESET                = PWFPGA_WIN_STATS_SNAPSHOT + 0x3FF4
   W     write 1 to soft-reset the wedge-prone datapath (gen / SAF / arbiters)

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
PWFPGA_WIN_HISTOGRAM + N * PWFPGA_FLOW_HIST_STRIDE  (128 B = 16 bins)
   N = local_flow_id

Bin layout: power-of-two buckets keyed off log2(latency); the build
ships 16 bins (stride 128 B). Buckets are u64. The histogram is
BRAM-backed (`rtl/phase3/pw_lat_histogram.sv`, fed by per-port checker
events) and read LIVE through this window -- there is no snapshot latch
for the histogram (unlike the stats window). The egress timestamp
(`pw_ts_insert`) means these latencies reflect the DUT, not the tester.
```

Concrete strides and offsets are defined as preprocessor macros
in `sw/libpacketwyrm/include/packetwyrm/csr.h` and used by the
host BAR backend.

## Punt / slow-path RX window (implemented, BAR-polled)

`pw_punt_rx_window` (0x1000) delivers classifier `PUNT_TO_HOST` /
`MIRROR_TO_HOST` frames to the host without DMA. The data plane's punt
arbiter feeds it (the SAF carries each frame's `logical_if_id` + ingress
port through to the window). One frame is buffered at a time (up to
2 KB); while a frame waits, the window backpressures the punt AXIS so the
SAF holds the next one (head-of-line — fine for occasional control
traffic). The host polls:

1. read `punt_status`; if `frame_valid` (bit 0) is clear, no frame.
2. read `punt_info` for `byte_len` + `ingress_port`, and `punt_lif` for
   the `logical_if_id`.
3. read `ceil(byte_len/4)` words from `punt_data` (little-endian).
4. write 1 to `punt_pop` to release the slot.

`bar_slow_path_rx` in `backend_bar.c` implements exactly this; the daemon
`host_plane` calls it and routes each frame to the TAP for its
`logical_if_id`. The `overflow` bit (status bit 1) latches if a frame
larger than the buffer was dropped. Host -> FPGA injection
(`slow_path_tx`) is implemented too -- see the inject window below.

## Slow-path TX inject window (implemented, BAR-driven)

`pw_inject_tx_window` (0x0D00) is the host -> FPGA complement of the punt
window. The host composes a frame in `inject_data` (little-endian 32-bit
words, in order), sets `inject_info` (`byte_len` + `egress_port`), then
writes `inject_ctrl.go`; the window emits the frame as a 64-bit AXIS
master into that egress port's TX arbiter, at priority between forwarded
frames and the test generator. One frame in flight (`busy` gates `go`);
512 B max (slow-path control traffic). `bar_slow_path_tx` implements the
sequence (write words -> INFO -> GO -> poll busy). Verified on HW by
`pw_phase3_inject`: a frame injected out egress 0 loops over the DAC to
RX1, is PUNTed back, and read by `slow_path_rx` byte-identical.

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
