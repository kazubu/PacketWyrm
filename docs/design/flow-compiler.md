# Flow compiler

The flow compiler turns the global, user-facing flow definitions from
YAML into per-card FPGA programming. It lives in `libpacketwyrm` and
is consumed by both `packetwyrmd` (at runtime) and the test harness
(for offline validation against a fake card).

## Inputs and outputs

Input:

```
pw_config
  +-- cards[]               (declared cards + their PCI BDF)
  +-- logical_interfaces[]  (logical_if_id -> port + VLAN + MAC + punt)
  +-- flows[]               (user flow definitions)
```

Output:

```
pw_program
  +-- per_card[card_id]
        +-- classifier_rows[]    (rule + action + tags)
        +-- flow_rows[]          (TX or RX configuration)
        +-- commit_plan          (which slots, in what order)
        +-- rollback_plan        (previous shadow contents)
```

## Compilation steps

### 1. Resolve ports

For every flow, resolve `tx_global_port` and `rx_global_port` into
`(card_id, local_port_id)`:

```
tx -> tx_card, tx_local_port
rx -> rx_card, rx_local_port
```

Cross-card means `tx_card != rx_card`.

### 2. Allocate local IDs

For each `(card_id, role)` involved, the compiler asks the per-card
free list (kept by the daemon) for a fresh `local_flow_id`:

- Same-card flow: one `local_flow_id` (the TX row also acts as the
  RX checker anchor, addressed by the classifier).
- Cross-card flow: one `local_flow_id` on the TX card (generator), one
  on the RX card (checker / classifier).
- **Background (load) flow** (`background: true`): TX-only. It gets a TX
  `local_flow_id` but **no RX checker slot** — it consumes no classifier /
  flow-id-map entry and produces no RX/loss/latency/jitter stats (the
  validator rejects a background flow that requests any measurement). Its
  `flow_meta` carries `rx_slot_valid = false`; the daemon must not read the RX
  side (it would alias a real flow's slot).

**Capacity ceiling.** `pw_program_card_tables` enforces the card's *real* flow
capacity, not just the 64-row CSR-window ceiling. If `n_flow_rows` exceeds the
bitstream's `num_local_flows` (32 on the shipping build, from `card_info`) it
rejects the program with a concrete diagnostic — `"<N> flow rows requested but
device supports <M> (num_local_flows); reduce measured flows or mark some
background"` — rather than silently programming a dead row past the implemented
generator/checker slots. Comparators / rules / hash / map are separately bounded
by `PWFPGA_NUM_CMP` (12) / `PWFPGA_NUM_UDF` (2) / `PWFPGA_NUM_RULE` (32) /
`PWFPGA_HASH_DEPTH` (128) / `PWFPGA_FLOWID_MAP_DEPTH` (256).

### 3. Build TX flow row

For the TX card, fill in `pwfpga_flow_config`:

- `enable = 0` initially; the orchestrator sets `enable = 1` at
  `flow start` time.
- `egress_local_port = tx_local_port`.
- `global_flow_id` is carried verbatim into the test header so the
  RX side can correlate even across cards.
- Frame fields (`dst_mac`, `src_mac`, VLAN, IPv4/IPv6, L4 ports, lengths)
  come from YAML.
- **L4 protocol**: a flow sets exactly one of a `udp:` or `tcp:` block
  (mutually exclusive). The compiler writes `l4_proto` (17 = UDP, 6 = TCP)
  and, for TCP, `tcp_flags` (default 0x02 SYN) into the row. TCP is a
  stateless segment generator (fixed 20-byte header, no handshake/ACK).
- **Min-legal frame is per-protocol and per-template** (`pw_flow_min_legal_frame`):
  the 20-byte TCP header makes the smallest legal frame larger than UDP —
  IPv4/TCP ≥ 86 B, IPv6/TCP ≥ 106 B (vs 74 / 94 for UDP). A requested
  `frame_len` below this is clamped up by the RTL; the compiler meters the
  token cost / `rate_pps` byte basis against this minimum so `cap ≥ cost`.
  The *raw* frame templates drop the 32-byte test-header floor: `raw` (L4RAW)
  ≥ 42 B (IPv4/UDP headers only), `ip` (L3RAW) ≥ 34 B (Eth+IPv4), `eth`
  (L2RAW) ≥ 14 B (Ethernet only) — so a 64-byte request is honored exactly
  rather than clamped to 74 B. Raw templates require `classify: header` and
  forbid measurements/encap (validator-enforced); the compiler sets the flow
  row's `frame_template`/`l2_ethertype` and zeroes the absent-layer hash-key
  words so RX header classification matches the zero-payload frame.
- Rate (`rate_bps` / `rate_pps`) + burst (`burst_size`,
  `burst_gap_ticks`). The token-bucket cap (`burst_bytes`) is `burst_size x
  frame` bytes, floored at one frame's cost (so the bucket can always reach it).
  A `burst_size: 1` (cap=1 frame) small-frame flow still reaches line rate: the
  generator keeps the active slot's pick pipeline primed through its own emit, so
  there is no per-frame drain bubble (see `pw_flow_gen_multi` — 64 B single flow
  → 14.2 Mpps at cap=1, HW-validated). No 2-frame cap floor is needed.
- `insert_sequence` and `insert_timestamp` default true.
- If the flow sets `encap`, the row also carries the tunnel descriptor
  (type + outer L3 + EtherIP inner MAC); the generator wraps the inner
  frame and the egress stamper finds the inner test header at its deep
  offset.

### 4. Build RX classifier entry + RX flow row

For the RX card (which equals the TX card on same-card flows), the compiler
picks one of two RX-identification paths, selected per flow by `classify:`:

- **`classify: map` (default) — TEST_RX flow-id map.** The generated test
  header already carries the `global_flow_id`. The compiler installs a
  `pw_flowid_map` entry (`flow_id → local_flow_id`); the parser's magic match
  (`is_test`) gates it and the flow_id indexes directly, so the udp_dst /
  ipv4 / ipv6 match fields are redundant and are **not** used. This is the
  high-count path (up to `PWFPGA_FLOWID_MAP_DEPTH` = 256 structured test
  flows), and it consumes no field-comparator / rule budget.

- **`classify: header` — hash exact table.** For payload-agnostic matching
  (e.g. traffic that must classify on the header alone), the compiler builds
  a `pw_hash_classifier` entry: a masked 11-word header key (IPv4/IPv6
  5-tuple + VLAN + ethertype) with a global key mask and a collision-free
  seed found in a per-card post-pass. Two header-classify flows that collide
  in a non-randomized field are rejected with a diagnostic (make a field
  differ, or use `classify: map`).

Action: `TEST_RX`. Tags: `local_flow_id` (RX), `logical_if_id` (for
diagnostics / tooling; not used for forwarding).

Both paths auto-decapsulate: the RX parser strips a recognized tunnel
(IPIP/GRE/EtherIP) and classifies on the **inner** frame, so the same flow
matches whether the DUT returns the bare inner frame (`rx_expect: inner`) or
the tunneled frame (`rx_expect: tunneled`).

**Modifiers relax the match mask.** A flow may diversify per-packet header
fields with modifiers (`inc` / `rand` / `mask` per field; IPv6 uses 128-bit
per-lane salts), applied by sequence number in the generator. When a field is
modified — or narrowed by an explicit match mask — the compiler **clears the
corresponding bits from the hash key mask** (`pw_fc_relax_mask`), so the
randomized/don't-care bits do not break classification (the RTL masks the same
bits before hashing and verifying). The flow-id-map path is unaffected: it keys
only on the fixed `flow_id`.

RX flow row mirrors the TX configuration (so the FPGA knows the
expected packet shape) but with the generator disabled
(`tx_enable = 0`, `rx_check_enable = 1`).

### 5. Latency validity / method decision

```
latency_valid = (tx_card == rx_card)   # true = same-card (exact, counter-direct)
```

Latency is now measured for **both** same-card and cross-card flows, so the
compiler no longer rejects cross-card `latency`/`jitter`. The `latency_valid`
flag is repurposed as the **method indicator**, not an availability gate:
`true` = same-card (exact, single FPGA counter); `false` = cross-card, corrected
per flow in hardware via the J5 GPIO time-sync + the per-flow `lat_correction`
table (the daemon servo keeps each cross-card slot at its inter-card offset).
The stats aggregator / `flow.stats` surface latency for both and use this flag
to emit `latency_method` (`"same-card"` / `"gpio-corrected"`). There is no
cross-card topology restriction: a single RX card may mix same-card and
cross-card flows and take cross-card traffic from multiple TX cards (each flow
gets its own correction slot).

### 6. Punt rule injection

For each logical interface, the compiler also emits the punt rules
described in `tap-logical-if.md`. These are deduplicated against
test-RX rules: if a punt key collides with a test-RX key, the test
key wins (it has the test_magic match, so it is strictly more
specific).

### 7. Catch-all rules

Per card / per port, low-priority catch-alls:

- Unknown frames on a port that has any logical interface attached
  &rarr; `DROP`.
- Unknown frames on a port with no logical interface (pure test
  port) &rarr; `DROP`.
- Optional `MIRROR_TO_HOST` for debugging, off by default.

### 8. Commit plan

Per affected card, the compiler emits:

1. Stage classifier rows (highest priority first or by table index).
2. Stage flow rows.
3. Write classifier `commit`.
4. Write flow `commit`.
5. On any error during stage, do **not** commit; restore staged region
   from the saved shadow contents.

Cards are programmed independently. A multi-card commit is therefore
not atomic across cards; the daemon documents that and avoids being
mid-config during `flow start`.

## Pseudocode

```c
int pw_flow_compile(const pw_config *cfg, pw_program *out) {
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const pw_flow *f = &cfg->flows[i];

        pw_port_resolved tx = pw_resolve_port(cfg, f->tx_global_port);
        pw_port_resolved rx = pw_resolve_port(cfg, f->rx_global_port);

        bool same_card = (tx.card_id == rx.card_id);
        // Cross-card latency/jitter is NOT rejected: it is HW-corrected per flow
        // (J5 GPIO sync + the per-flow lat_correction table). latency_valid below
        // is the method flag (same-card exact vs cross-card gpio-corrected), not
        // an availability gate.

        uint32_t tx_lfid = pw_alloc_local_flow_id(out, tx.card_id);
        uint32_t rx_lfid = same_card
            ? tx_lfid
            : pw_alloc_local_flow_id(out, rx.card_id);

        pw_emit_tx_flow_row(out, tx, f, tx_lfid);
        // Background (TX-only) flows emit no RX entry and set rx_slot_valid=0.
        // Real flows install a flow-id-map entry (classify: map, default) or a
        // hash entry (classify: header); modifiers relax the hash key mask.
        if (!f->background) {
            pw_emit_rx_classify(out, rx, f, rx_lfid);   // map or hash per classify:
            if (!same_card) pw_emit_rx_flow_row(out, rx, f, rx_lfid);
        }

        out->flow_meta[i] = (pw_flow_meta){
            .global_flow_id = f->id,
            .tx_card_id    = tx.card_id,
            .rx_card_id    = rx.card_id,
            .tx_local_flow = tx_lfid,
            .rx_local_flow = rx_lfid,
            .latency_valid = same_card && !f->background,
            .rx_slot_valid = !f->background,
        };
    }

    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        pw_emit_punt_rules(out, &cfg->logical_if[i]);
    }

    pw_emit_catchall_rules(out, cfg);
    pw_build_commit_plan(out);
    return PW_OK;
}
```

## Reload semantics

Configuration reloads compute a diff:

- New flows &rarr; allocate `local_flow_id`s, stage, commit.
- Removed flows &rarr; stop, free `local_flow_id`s, stage empty rows.
- Modified flows &rarr; stage new shape into the same row, commit.

The daemon prefers stable `local_flow_id` reuse across reloads for a
given `global_flow_id` to minimise classifier churn.
