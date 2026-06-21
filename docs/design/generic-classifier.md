# Generic slice-based classifier (design spec)

Status: **proposed — design freeze before implementation.** Replaces the
fixed-field parallel-TCAM classifier (`pw_classifier` / `pw_classifier_banked`)
with a programmable, protocol-agnostic match engine that scales the flow count
on the *fixed* xcku3p (there is no larger-FPGA plan).

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
1. **Slice extractor unit** + unit tb (offset/width/mask/value → bit). Self-contained.
2. **Parser → byte-window provider** (expose the decap'd window + inner base;
   keep test-header fields). The blast-radius step.
3. **Direct-index exact path** for TEST_RX (flow_id → index) — unlocks the flow
   ceiling immediately for test traffic; smallest path to "many flows".
4. **Small wildcard TCAM** for PUNT/FORWARD over slice bits.
5. (Optional) **hash exact table** for arbitrary DUT-traffic flows.
6. Compiler: presets → slice configs + back-end entries; retire fixed-field path.

Each phase is sim-gated; (3) alone likely lifts the measured-flow ceiling well
past 16 without the routing wall.

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
