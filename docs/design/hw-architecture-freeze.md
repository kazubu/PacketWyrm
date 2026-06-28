# Hardware Architecture Freeze (Phase 3 generation)

Status: **proposed — for review before implementation.** This document locks the
load-bearing hardware decisions for the current PacketWyrm generation so the
software layer (RFC2544 orchestration, reporting, REST/Python API, PTP servo)
can be built on a stable contract. Software is cheap to iterate; RTL is ~50 min
per build + flash, and the CSR/wire formats ossify once external software
depends on them — so we settle the silicon first.

## Frozen platform parameters

| Parameter        | Frozen value                          | Rationale |
|------------------|---------------------------------------|-----------|
| FPGA             | `xcku3p-ffvb676-1-e`                  | this generation; ~162K LUT, currently 91% used |
| Ports / speed    | 2 × SFP+ 10GBASE-R (Taxi PHY)         | no 25G/100G this gen (would need a bigger device + datapath rework) |
| Data plane       | 64-bit AXIS @ 156.25 MHz (dp_clk)     | sized for 10G; unchanged |
| Off-chip memory  | none (no DDR/MIG in this design)      | line-rate capture-to-DRAM is OUT of scope this gen |

**Explicitly out of scope this generation** (reserve hooks, don't build):
25G/100G, DRAM capture, stateful TCP (handshake/ACK/window — note *stateless* TCP
segment generation IS in scope and shipped) / routing-protocol emulation. Capture stays
on the existing PUNT/MIRROR slow path (host TAP).

## What must go into silicon NOW (retrofit-expensive hooks)

### DECISION (2026-06-21): raw HW timestamps + SW correction

`pw_ts_gray_cdc` (egress timestamp dp_clk→MAC-TX) is a Gray-code CDC: correct
only when the counter steps by 0/1 per cycle. A *disciplined* counter speeding
up (period_inc > nominal) would step +2 → two Gray bits flip → a mid-transition
sample can resolve to garbage → corrupted wire timestamps. So we do **not**
discipline the HW counter. Instead:

- The dp_clk counter stays free-running `+1`/cycle (Gray-CDC unchanged).
- HW captures **raw wire timestamps** (TX egress already does; add RX ingress).
- The SW PTP servo measures each card's offset/skew vs the grandmaster from PTP
  packet exchanges and **corrects the raw timestamps in software**. Adequate for
  a latency tester (one-way latency = corrected rx_wire_ts − corrected tx_wire_ts).

So the original "disciplinable counter" (item 1 below) is **dropped**, and
"atomic snapshot" is moot (the flow snapshot is a BRAM walk, coherent per-flow;
final loss uses stop→drain→snapshot). The remaining HW hook is the RX ingress
wire-stamp (item, was step 3) + exposing TX/RX wire timestamps for PTP packets.

### 1. (DROPPED) PTP-ready disciplinable timestamp

Cross-card / cross-chassis one-way latency **is in scope**, so the timestamp
unit must become a *disciplinable clock* and the RX path must *wire-stamp at
ingress*. The PTP servo + protocol stack are software and come later — but these
hooks cannot be retrofitted cheaply (they thread a new field through the whole
RX datapath).

**1a. Disciplinable counter (`rtl/shared/pw_timestamp.sv`).**
Today it is a free-running `ts_o <= ts_o + 1` cycle counter (1 tick = 6.4 ns),
which is why `min_lat` reads ~71 (≈454 ns). Replace with a rate/offset-adjustable
nanosecond accumulator:

```
  ts (Q48.16 ns) <= ts + period_inc;     // period_inc nominal = 6.4 ns (0x0000_0006_6666)
  on offset_adjust write: ts <= ts + offset_adjust;   // signed one-shot phase step
```

- `period_inc` (CSR, RW): the SW servo writes the frequency correction to
  syntonize to the grandmaster. Defaults to nominal 6.4 ns.
- `offset_adjust` (CSR, W one-shot): signed phase step for coarse offset
  correction.
- The counter now reads in real nanoseconds (servo and reports want ns, not
  cycles); the test header `tx_timestamp` and all latency math inherit ns units.
- Same-card latency is unaffected (both ends already share this counter);
  cross-card becomes valid once both cards discipline to the same grandmaster.

**Concrete RX wire-stamp implementation plan** (scoped 2026-06-21):
1. Board top: per-port `pw_ts_gray_cdc` dp_clk→`sfp_rx_clk` → `ts_rx[p]` (the +1
   counter is Gray-safe). Latch `rx_wire_ts[p]` at RX SOF in `sfp_rx_clk`.
2. `pw_mac_axis_cdc` (rtl/phase2): widen the RX async-FIFO `USER_W` 1→65 and pack
   `{rx_wire_ts_at_sof, mac_rx_tuser}`; the 64-bit ts (held over the frame)
   crosses with the frame, emerging as `dp_rx` user on dp_clk.
3. `pw_data_plane_axis`: split the dp_rx user into rx_tuser + rx_wire_ts per port;
   present rx_wire_ts to the parser as per-frame metadata.
4. `pw_parser_axis`: carry rx_wire_ts from SOF through the 3 stages so it emerges
   aligned with `key_valid` (the test header is at end-of-frame). THE alignment
   risk — verify in sim that the ts that exits matches the frame's SOF capture.
5. `pw_test_rx_checker_bram`: take rx_wire_ts on the event and use it for latency
   (`latency = rx_wire_ts − tx_ts`) instead of the dp_clk `timestamp_i` sampled
   at the checker — removes the RX-FIFO-occupancy jitter (tighter min/max even
   same-card) and is the cross-card one-way reference.
HW check: same-card loopback min/max latency spread should *shrink* vs today's
71–77; loss still 0.

**1b. RX ingress wire-stamp (the expensive plumb — do it now).**
Today RX latency = `dp_clk timestamp at the checker − test_tx_timestamp`, i.e.
the RX side is stamped *after* the MAC→dp_clk CDC + parser pipeline (jittery,
and only meaningful same-card). Mirror the egress TX stamp:

- add a `pw_ts_gray_cdc` per port (dp_clk → `sfp_rx_clk`), like the existing TX one;
- capture `rx_wire_ts` at RX **SOF** in the `sfp_rx_clk` domain (the wire instant);
- carry `rx_wire_ts` through `pw_mac_axis_cdc` → `pw_parser_axis` → `pw_test_rx_checker`
  as an AXIS sideband field;
- checker: `latency = rx_wire_ts − test_tx_timestamp` (both on the disciplined clock).

This new sideband field is what's brutal to retrofit later (re-plumbs the entire
RX path); adding it now is cheap.

**1c. Servo / PTP-packet timestamp interface.**
- CSR: `TS_PERIOD_INC` (RW), `TS_OFFSET_ADJ` (W one-shot), `TS_NOW_LO/HI`
  (R, latched snapshot of the live counter for the servo).
- PTP event packets (Sync/Delay_Req) reach the host via the existing PUNT path —
  so **PUNT metadata must carry `rx_wire_ts`** (available once 1b lands).
- TX PTP packets go via the inject path — it must **return the egress
  `tx_wire_ts`** (inject-with-timestamp-capture hook).

### 2. Atomic snapshot + true-loss semantics

`loss(tx−rx)` oscillates 0/±1 because frames are genuinely in flight at the
sample instant (not only a snapshot-coherency artifact). Two parts:
- **HW**: one `snapshot_pulse` freezes *all* counter shadows (gen TX, checker RX,
  port) on the same cycle — a coherent instant. All counters already live on
  dp_clk, so this is a small change to `pw_stats_snapshot` triggering.
- **Semantics (contract for SW)**: *final* loss is measured **stop → drain →
  snapshot** (after in-flight frames land), at which point tx == rx exactly.
  Document this; the in-flight delta is not loss.

### 3. CSR / wire-format versioning freeze

Once external SW + saved configs depend on the map, it can't move:
- bump/define a **capabilities contract** (`CAPABILITIES`, currently `0x6C`) with
  bits for PTP-timestamp, atomic-snapshot, etc.;
- add explicit **reserved** fields to `pw_port_stats` / `pw_flow_stats` /
  `pwfpga_match_key` / `pwfpga_flow_config` for forward growth;
- freeze and version the layout in `csr.h` + `docs/design/csr-map.md`.

### 4. Per-flow state → BRAM (pays for 1–3 on a 91%-full part)

The part is nearly full, so the PTP hooks need room. Move `pw_test_rx_checker`
per-flow state (expected_seq, lost/dup/ooo/last_seq, latency min/max/sum/samples,
jitter) from FF arrays to a BRAM + RMW pipeline — the pattern already proven by
`pw_lat_histogram` and `pw_flow_table_bram`. This **frees LUT** (the wide
per-flow muxes) *and* raises the flow-count ceiling from 24 toward hundreds on
the same device. Sequencing: do this first to bank headroom, then add the PTP
hooks.

## Implementation order (each = one build/flash/HW cycle)

1. **Checker → BRAM** (frees LUT + lifts flow ceiling; no behavior change → easy HW check).
2. **Disciplinable `pw_timestamp`** (period_inc/offset CSR; ns units) + atomic snapshot.
3. **RX ingress wire-stamp** plumbed to the checker + PUNT/inject timestamp metadata.
4. **CSR/wire versioning freeze** (reserved fields, capabilities bits) — fold into 2–3's commits.

After this, the silicon is the stable contract; the PTP servo, RFC2544
orchestration, reporting, and API are pure software on top.

## Reserved-but-not-built hooks (next generation)

- 25G/100G: would replace the MAC/PCS, widen the datapath (≥512-bit), and need a
  larger device (US+ / Versal) — full data-plane rework.
- DRAM capture: needs board DDR (confirm AS02MC04 datasheet) + MIG + capture
  FIFO + trigger. A capture-tap point in the data plane could be reserved.
- Stateful / control-plane emulation (TCP, BGP/OSPF, in-FPGA ARP/ND responders).
