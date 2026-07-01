# Generic classifier (design spec)

Status: **implemented + HW-bound — v2 unified field+UDF engine; legacy
classifier retired.** A programmable, protocol-agnostic match engine
(`pw_field_classifier`) that **replaces** the fixed-field parallel `pw_classifier`
(the xcku3p route wall) and the interim `pw_slice_classifier`, with the
high-count flow-id map (`pw_flowid_map`) kept for structured test traffic. On
the *fixed* xcku3p (no larger-FPGA plan). The hash exact table (Phase 5,
`pw_hash_classifier`) lifts payload-agnostic classification from the field
comparators' ~NCMP cap to the checker's NUM_FLOWS.

**v2 architecture (the "rethink").** The dominant cost of arbitrary-offset
matching is the variable byte-mux — and the parser *already* pays it to extract
named fields. So v2 sources comparators from the parser's canonical, position-
normalized fields (`pw_match_key_t`) — **mux-free** — and only falls back to a
bounded raw-window byte-mux for true UDF (fields the parser doesn't name). And
retiring the legacy 600-bit×N classifier frees the RX-region routing budget so
the engine + the 32-flow data plane fit together (the interim slice classifier,
*added alongside* the legacy one, could not route at 32 flows).

Implemented: `pw_field_classifier` = `NCMP`(12) field comparators (each
`{src,mask,value}` over a canonical-field lane; IPv6 addr = 4 comparators) +
`NUDF`(2) UDF comparators (`pw_slice_match` over the raw inner-frame window,
`SLICE_WIN`=48) → `NRULE`(32) care-mask rules → priority `{action,egress,lfid,
lif}`. Parser `window_o`/`base_o` outputs; data-plane precedence **map > field
classifier**; CSR windows `PWFPGA_WIN_FC_CMP`/`_UDF`/`_RULE` @ 0x2000; compiler
lowers `classify: header` test flows + punt + forward to comparators+rules. The
checker counts non-test frames (rx only) so arbitrary-payload / external DUT
traffic is countable; structured test frames still get full seq/latency stats.

**UDF window depth (deep-encap fix).** `pw_slice_match` extracts its 4-byte lane
at *absolute* window byte `base_i + offset_i`, with `base_i` = the inner-L3 base
(`eff`). The UDF now gets the **full `HDR_BYTES` captured window** (not just the
low `SLICE_WIN` bytes), so a UDF reaches the inner frame wherever
`eff + offset < HDR_BYTES` (176) — i.e. at any single-encap depth (deepest inner
L3 base ≈ 74). Earlier the window was truncated to the low 48 absolute bytes, so
`eff + offset ≥ 48` (deep encap, e.g. v6-in-v6) read 0 and could never match the
inner frame; only shallow UDFs like the IS-IS punt (`offset 0`, no encap) worked.
The fix widens only the two `pw_slice_match` byte-muxes (48→`HDR_BYTES`) in the
classifier's latency-2 path — it does NOT touch the parser's dp_clk-critical
Stage-A2 (an earlier parser-side inner-anchored-slice attempt was abandoned for
no LUT win + a timing regression; see `parser-lut-reduction.md`, "SUPERSEDED").
Out-of-window bytes still read 0 (fails safe: no false match). Asserted in
`tb_field_classifier` (deep-encap UDF at base 74).
Capacity note: header-defined flows + punt + forward share the 12 comparators /
32 rules per card (comparators dedup); high-count structured TEST_RX uses the
256-entry flow-id map.

## Why

The current classifier matches a ~600-bit named-field key (`pw_match_key_t`,
incl. 128-bit IPv6 src+dst) in **parallel across every entry**. That is both:
- **Inflexible**: matchable fields are hardcoded in the parser + key + window;
  a new field/protocol (VXLAN, MPLS, a custom header byte) needs an RTL change.
- **Unscalable / unroutable**: N entries × ~600-bit compares is a dense,
  high-fanout cloud. It does not route past ~16 entries on the xcku3p — 32
  needed banking + spread-placement + a registered winner + dead-compare trims
  just to (marginally, ~3 h builds) close. The wide per-entry compare is the wall.

The fix is the architecture programmable switches (RMT / P4) and commercial
testers (Ixia/Spirent "user-defined fields") use: **extract a few narrow,
arbitrary slices of the packet, and match scalably.**

## Architecture (two stages)

### Stage 1 — shared slice extractors (the flexible front-end)
A bounded set of `NSLICE` (~16) identical units. Each is programmed with
`{offset, width, mask, value}` and produces one **slice-match bit**:

```
slice_match[i] = ((frame_bytes[offset_i +: width_i] & mask_i) == (value_i & mask_i))
```

- `offset` is into the **decapsulated inner frame** (the parser provides the
  byte window + the inner-frame base; see "Parser role"). Bounded to the
  captured header window (`HDR_BYTES`), so the byte mux is bounded.
- `width` ≤ 4 bytes; `mask`/`value` 32-bit. Bitwise mask = TCAM-style partial
  match (ranges, "match these bits only").
- Shared across all flows — the expensive byte-extract + masked compare is done
  **once per slice unit**, NOT replicated per flow. Cost ≈ `NSLICE` × (bounded
  byte-mux + 32-bit masked compare). ~16 units, fixed — bounded and routable.

### Stage 2 — match back-end (scalable flow identification)
The `NSLICE` slice-match bits + a few extracted key fields feed **two** parallel
back-ends; the host picks per rule:

**(a) Exact-match table (the many-flow path).**
For flows identified by an exact value (the common case): the relevant
extracted bytes form a composite key that is matched via a **BRAM table** —
either a hash table or, for our own test traffic, a **direct index**:
- *Test traffic*: the generated test header already carries a `flow_id`. Extract
  it (one slice) and use it **directly as the flow index** — no matching at all.
  This is how TEST_RX scales to as many flows as the checker BRAM holds, for
  free. (Today's classifier already keys TEST_RX on test_flow_id; this just
  makes it the index rather than one of N parallel compares.)
- *Arbitrary exact flows* (DUT traffic by header tuple): hash the composite
  extracted key → BRAM bucket → {flow_id, action}. Scales to 100s–1000s of
  flows in BRAM with no per-flow comparators. (Collision handling: small bucket
  depth + a "verify" compare of the stored key; documented bound.)

**(b) Small wildcard TCAM (the few-rule path).**
Wildcard / masked / range rules (PUNT ARP/ND/LLDP, FORWARD by port, encap
class) stay in a **small** parallel TCAM — e.g. 8 entries — over the slice-match
vector + class flags. 8-wide routes comfortably (16 already does). This keeps
the flexibility of masked matching where it is actually needed (few rules),
without paying for it × every flow.

Per-rule combine (for the TCAM path) is the user's "combine in SW" idea: each
TCAM rule = `{care[NSLICE], expect[NSLICE]}` over the slice-match bits, hit =
`(slice_match & care) == (expect & care)`. The combination pattern is computed
by the SW compiler.

### Why this scales where the current design doesn't
| | current (parallel TCAM) | generic slice |
|---|---|---|
| per-flow compare | M × ~600 bit | exact: **0** (index/hash) · wildcard: 8 × NSLICE bit |
| byte extract/compare | replicated in every entry | **NSLICE shared** units (~16) |
| add a field/protocol | RTL change | **SW only** (program an offset) |
| flow-count ceiling | ~16 (route wall) | checker/BRAM-bound (64/128/256+) |

The expensive, congesting work (wide masked byte compares) is bounded to
`NSLICE` shared units; flow count rides cheap BRAM. Routability stops being the
flow-count wall.

## Parser role change
Today `pw_parser_axis` extracts **named fields** into `pw_match_key_t`. New role:
provide the **decapsulated inner-frame byte window** + the inner base offset
(it already computes `eff_off` for decap descent) + the test-header fields the
direct-index path needs. The slice extractors index into that window. Named-field
extraction is no longer the parser's job — offsets are SW-programmed.

## CSR / wire model
- **Slice config window**: `NSLICE` × `{offset:16, width:8, mask:32, value:32}`.
- **Exact table**: BRAM (hash buckets or direct flow_id index) — reuse the
  committed-shadow + walk pattern from `pw_flow_table_bram`.
- **Wildcard TCAM**: small (~8) `{care, expect, action, egress, flow_id, prio}`.
- Versioned + capability-bit gated; the old fixed-field window can remain for
  one transition release.

## Migration / compatibility
- SW keeps a library of **named-field presets** (`udp_dst → offset 36 width 2`,
  `ipv6_dst → offset … width 16 = 4 slices`, …) so YAML stays high-level; the
  compiler lowers them to slice configs + back-end entries.
- TEST_RX flows → direct-index path (flow_id from the test header). PUNT/FORWARD
  → wildcard TCAM. Encap inner matching → slices at the parser's inner offset.
- Behavior parity gate: the existing sims + the 32-flow loopback must pass with
  the new engine before the old classifier is retired.

## Phased implementation
Status: **all phases (1–6) implemented + HW-bound.** The interim
`pw_slice_classifier` (Phase 4 first cut) was superseded by `pw_field_classifier`
and removed.

1. **[DONE]** Slice extractor unit (`pw_slice_match`) — reused as the field
   classifier's UDF comparator front-end.
2. **[DONE]** Parser → byte-window provider: `pw_parser_axis` exposes `window_o`
   (captured inner-frame header bytes) + `base_o` (inner L3 base), aligned with
   `key_valid_o`.
3. **[DONE]** Direct-index exact path for structured TEST_RX (flow_id → index,
   `pw_flowid_map`) — the high-count fast path keyed on the test header.
4. **[DONE]** Field+UDF comparator engine (`pw_field_classifier`) — comparators
   source the parser's canonical fields (mux-free) + bounded UDF window slices;
   NRULE care-mask rules → priority result. Replaced the legacy `pw_classifier`
   (the 600-bit route wall); carries punt/forward + few-rule wildcard matching.
5. **[DONE]** Hash exact table (`pw_hash_classifier`) — multiply-shift hash of a
   WIDE 11-word header key (full IPv4/IPv6 5-tuple + VLAN + ethertype) → BRAM
   bucket → full masked-key verify. A global key mask (ANDed in before hash +
   verify) selects which bits participate, so a generator modifier can randomize
   the masked-out bits and the flow still classifies. Payload-agnostic, scaling
   to NUM_FLOWS. SW builds the mask (relaxing modifier/match bits) + a collision-
   free seed. Data-plane precedence map > hash > field.
6. **[DONE]** Compiler: `classify: header` → hash entries (collision-free seed
   search); punt/forward → field comparators + rules; structured TEST_RX → map.

Each phase is sim-gated. Capacity note: with each slice an exact match, header-
defined flows are bounded by `NSLICE` distinct header values (4) / `NRULE` rules
(8) per card, over a 48-byte match window (L3/L4 of a non-encapsulated frame) —
sized so the byte-mux fits alongside the 32-flow data plane on the xcku3p; the
flow-id map (256) remains for high-count structured test.

## Risks / open questions
- **Arbitrary-offset byte mux** cost — bound offsets to the header window +
  limit `NSLICE` (~16), as commercial designs do.
- **Encap/inner offsets** — slices are relative to the parser's inner base;
  verify across the IPIP/GRE/EtherIP × v4/v6 matrix.
- **Hash collisions** (path 5) — bucket depth + stored-key verify; or skip hash
  and rely on direct-index (path 3) + wildcard TCAM, which covers the tester's
  own traffic without hashing.
- This is a **large redesign** (classifier + parser role + compiler + sims +
  build/HW). Phases 1–3 are the high-value core; 4–6 complete it.
