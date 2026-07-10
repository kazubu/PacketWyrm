# Statistics aggregation

The FPGA owns per-port and per-flow counters; the daemon owns the
**global** view that the user sees. This document specifies the
counters, their semantics, and how multi-card aggregation works.

## Per-port counters (from FPGA)

| Counter                | Type | Notes                                  |
|------------------------|------|----------------------------------------|
| `rx_frames`            | u64  | post-FCS, valid + invalid              |
| `rx_bytes`             | u64  | wire bytes including FCS               |
| `rx_fcs_error`         | u64  | RX `tuser`-on-`tlast` errored frames   |
| `rx_bad_frame`         | u64  | REAL drops only: SAF forward-buffer overflow (exposed as `drops`) |
| `rx_oversize`          | u64  | > MTU (not yet produced)               |
| `rx_undersize`         | u64  | < 64 B (not yet produced)              |
| `tx_frames`            | u64  |                                        |
| `tx_bytes`             | u64  |                                        |
| `link_up_count`        | u32  | rising-edge count of MAC link_up       |
| `link_down_count`      | u32  | falling-edge count of MAC link_up      |
| `block_lock_loss`      | u32  | falling-edge count of PCS block_lock   |
| `rx_unmatched`         | u32  | frames counted in `rx_frames` that matched no classifier rule (informational, NOT a drop) |
| `last_unmatched_ctx`   | u32  | most recent unmatched frame's context: `{l3_proto[31:24], ethertype[23:8], is_arp[7], action[6:4], hit[3], is_ipv6[2], is_ipv4[1], is_test[0]}` |
| `last_unmatched_flowid`| u32  | that frame's `test_flow_id` (0 if not a test frame) |

`rx_bad_frame` (exposed as `drops`) counts **real drops only** — a
store-and-forward forward-buffer overflow. A classifier **no-match** is NOT a
drop: the frame was still received and counted in `rx_frames`, it simply matched
no flow/forward/punt rule (e.g. the host TAP's own IPv6 ND/MLD looped back to the
port). That case is counted separately in `rx_unmatched`. A **stray** no-match
deliberately does **not** light the front-panel error LED — but a no-match on a
real **test** frame (`is_test`) **does** latch the error LED: such a frame never
reaches the RX checker, so no loss event fires and the miss would otherwise hide
behind a green LED. `last_unmatched_ctx`/`last_unmatched_flowid` capture the
identity of the most recent unmatched frame so it is diagnosable (a real
test-frame miss carries `is_test` + a known `flow_id`; stray/garbage traffic
does not).

`rx_frames/bytes`, `tx_frames/bytes`, `rx_fcs_error`, `rx_bad_frame` and
`rx_unmatched` are counted at the port edge in `pw_data_plane_axis` (48-bit, zero-extended
to the snapshot fields; cleared by `stats_clear`). Link health
(`link_up/down_count`, `block_lock_loss`) is derived by 2-FF synchronizing
the async MAC/PCS status levels into `dp_clk` and edge-counting; these are
sticky (not affected by `stats_clear`). `rx_oversize/undersize` are not yet
produced and read back as zero.

## Per-flow counters (from FPGA)

| Counter                  | Type | Same-card | Cross-card |
|--------------------------|------|-----------|------------|
| `tx_frames`              | u64  | yes       | yes        |
| `tx_bytes`               | u64  | yes       | yes        |
| `rx_frames`              | u64  | yes       | yes        |
| `rx_bytes`               | u64  | yes       | yes        |
| `last_sequence`          | u64  | yes       | yes        |
| `sequence_gap_count`     | u64  | yes       | yes        |
| `lost_packets_estimated` | u64  | yes       | yes        |
| `duplicate_count`        | u64  | yes       | yes        |
| `out_of_order_count`     | u64  | yes       | yes        |
| `late_packet_count`      | u64  | yes       | yes        |
| `min_latency`            | u32  | **yes**   | **yes** (HW-corrected) |
| `max_latency`            | u32  | **yes**   | **yes** (HW-corrected) |
| `sum_latency`            | u64  | **yes**   | **yes** (HW-corrected) |
| `sample_count`           | u64  | **yes**   | **yes**    |
| `jitter_min/max/sum`     | u32/64| **yes**  | **yes**    |
| latency histogram bins   | u64[]| **yes**   | **yes** (HW-corrected) |

`last_sequence` is the **last received** sequence number (the HW snapshot
exports the last seq seen, not an expected one). The C struct field is
`last_sequence` (`backend.h`) and the `flow.stats` JSON key is `last_seq`.

`min_latency` and `jitter_min` are tracked in HW from a `0xFFFFFFFF` sentinel
that the first sample overwrites. When `sample_count == 0` (no traffic / flow
not started) that sentinel is meaningless, so the daemon reports **0** for both
(never the raw ~27.5 s that `0xFFFFFFFF` ticks × 6.4 ns would imply); the CLI
prints `-` and keys "has a measurement" off `sample_count`.

Cross-card latency is **now valid too**: the RX checker corrects each sample in
hardware (the `lat_correction` CSR carries the inter-card offset from the J5
GPIO sync, kept current by the daemon servo), so min/max/sum and the histogram
hold the true one-way latency for cross-card exactly as for same-card. The
aggregator therefore reports `latency_valid = true` for both and sets a
`cross_card` flag to distinguish the source; the compiler's `latency_valid`
annotation is repurposed as the same-card indicator, no longer a gate.

## Snapshot protocol

```
host writes stats_snapshot_trigger = 1
   |
   v
FPGA copies per-flow counters into the shadow region (single cycle)
   |
   v
host reads stats_addr / stats_* registers row by row
```

Critical: 64-bit counter `_low/_high` pairs use the read-latch rule.
The shadow region is **not** updated again until the host writes the
trigger again, so the host can take its time reading a single
snapshot.

## Global aggregation rules

The aggregator joins per-card snapshots into a global view keyed by
`global_flow_id`. For each flow:

- Look up `tx_card_id`, `rx_card_id` from the compiler's flow_meta.
- `tx_frames`, `tx_bytes` &larr; TX card's counters for that
  `local_flow_id`.
- `rx_*`, `lost_est`, `duplicate`, `out_of_order`, `late`,
  `last_sequence`, `sequence_gap_count` &larr; RX card's counters.
- `latency` / `jitter`: valid for BOTH same-card and cross-card. The RX card's
  counters already hold the HW-corrected one-way latency (cross-card via
  `lat_correction` + the J5 GPIO sync servo), so they are copied unconditionally;
  `latency_valid = true` either way, with `cross_card` marking the corrected path.
- `loss = max(0, tx_frames - rx_frames)` for reporting; the flow's
  own `lost_packets_estimated` is the authoritative loss number.

Per-port aggregates roll up across cards naturally; each
`global_port_id` is owned by exactly one card so no cross-card
summing is needed at the port level.

## Output forms

### CLI tables

```
$ pktwyrm stats --flow 1
Flow  TX       RX       Loss   Dup  Reord  Late  MinLat  AvgLat  MaxLat
1     12345    12340    5      0    0      0     1.20us  1.34us  2.10us

$ pktwyrm stats --flow 2     # cross-card: HW-corrected, so latency is reported
Flow  TX       RX       Loss   Dup  Reord  Late  MinLat  AvgLat  MaxLat
2     12345    12340    5      0    0      0     0.19us  0.21us  0.24us
```

### JSON

The `flow.stats` RPC emits flat per-flow fields (latency/jitter in ns):

```json
{
  "flows": [
    {
      "id": 1,
      "tx_frames": 12345,
      "rx_frames": 12340,
      "lost": 5,
      "duplicate": 0,
      "out_of_order": 0,
      "seq_gap": 0,
      "last_seq": 12340,
      "read_ok": true,
      "latency_valid": true,
      "min_latency": 1200, "avg_latency": 1340, "max_latency": 2100,
      "sample_count": 12340,
      "jitter_min": 0, "jitter_avg": 120, "jitter_max": 800,
      "latency_method": "same-card"
    },
    {
      "id": 2,
      "tx_frames": 12345,
      "rx_frames": 12340,
      "lost": 5,
      "duplicate": 0,
      "out_of_order": 0,
      "seq_gap": 0,
      "last_seq": 12340,
      "read_ok": true,
      "latency_valid": true,
      "min_latency": 190, "avg_latency": 210, "max_latency": 240,
      "sample_count": 12340,
      "jitter_min": 0, "jitter_avg": 13, "jitter_max": 80,
      "latency_method": "gpio-corrected",
      "offset_ticks": 42
    }
  ]
}
```

(The library aggregator `pw_stats_aggregate` also carries a `cross_card` flag
and raw `*_ns` fields on `struct pw_global_flow_stats`; the daemon's `flow.stats`
surface uses `latency_method` = `"same-card"` / `"gpio-corrected"` instead of a
separate `cross_card` boolean, and applies the no-samples → 0 rule described
above.)

### Prometheus (optional)

`packetwyrmd` may export `/metrics` with:

- `packetwyrm_port_rx_frames_total{card="0",port="p0"} ...`
- `packetwyrm_flow_tx_frames_total{flow="1"} ...`
- `packetwyrm_flow_lost_total{flow="1"} ...`
- `packetwyrm_flow_latency_ns{flow="1",quantile="0.5"} ...` (same- and
  cross-card; cross-card is HW-corrected)

Latency is valid for both same-card and cross-card flows, so no
"unsupported" gauge is needed; a `cross_card` / `latency_method` label can
distinguish the exact vs GPIO-corrected source.

## Overflow and reset

- 64-bit counters do not realistically overflow on 10G in a daemon
  lifetime, but the aggregator handles 64-bit subtraction with
  wrap-around just in case (uses unsigned arithmetic).
- `pktwyrm test stop` does not clear counters by default. Counter
  reset is an explicit action (`global_control.reset_counters` =
  bit 2) and is logged.
- Histogram bins follow the same reset semantics.

## Watchdog

The aggregator timestamps each snapshot. If a card's snapshot ages
beyond N intervals (default 5 &times; poll interval), it logs a
warning and surfaces the card as `degraded` in `pktwyrm cards`. The
counters from that card freeze at the last known good values rather
than going to zero.
