# Changelog

All notable changes to PacketWyrm. The project is in active
pre-release development; this file is updated per development
push and is the source of truth for "what's working today".

For where work is going next, see `NEXT-STEPS.md`.

## Unreleased

### Added
  - **Front-panel R/G health LED.** The previously-unconnected bicolor status LED
    (led_r=A13 / led_g=A12, active-low) now shows data-plane health: **red** =
    sticky error since the last `stats.clear` (a checker sequence-loss event, or
    a nonzero RX FCS/runt or port-drop count); **green blinking** = up + clean +
    traffic flowing; **green solid** = up + clean + idle; **off** = PCIe down /
    not configured (red overrides green). SFP link state is intentionally NOT
    shown here (the per-cage SFP LEDs already do that). The data plane exports two
    aggregate levels (err_sticky, activity — a retriggerable one-shot); the board
    top 2FF-synchronises them into the 100 MHz LED domain and drives a ~3 Hz
    blink. New checker `lost_event_o` pulse feeds the sticky-error latch.
  - **SFP+ module identifier + DOM read (`pw_sfp`).** New per-SFP I2C management
    bus (CSR `REG_SFP_I2C` 0x0150, open-drain SCL/SDA per cage via board-top
    IOBUFs on C13/C14 and D10/D11) lets software bit-bang the module EEPROM. New
    `libpacketwyrm/sfp.{c,h}` reads + decodes SFF-8024/8472: identifier, vendor,
    part, revision, serial, date code, nominal bit rate (0xA0 @ i2c 0x50), and —
    for DDM-capable optical modules — live DOM (temperature, Vcc, TX bias, TX/RX
    optical power, 0xA2 @ 0x51). New `pw_sfp <bdf> [port|both] [raw]` tool prints
    it (with dBm). A passive DAC reports the identifier but no DOM. Pad inputs are
    2FF-synchronised + false-pathed; the I2C lines idle high via PULLUP.

### Fixed
  - **Deep-encap UDF classifier matching.** A UDF slice comparator reads inner
    byte `base_i(eff) + offset` out of the captured window, but the window was
    truncated to the low `SLICE_WIN`(48) bytes, so for `eff + offset ≥ 48` (deep
    encap, e.g. v6-in-v6) it read 0 and could never match the inner frame (only
    shallow UDFs like the IS-IS punt worked). The classifier now gets the full
    `HDR_BYTES`(176) window, so a UDF reaches the inner frame at any single-encap
    depth. Widens only the two `pw_slice_match` byte-muxes (classifier latency-2
    path); the dp_clk-critical parser is untouched. (No config emits a deep-encap
    UDF today, so this was a latent limitation, but it restores the documented
    "offset relative to the inner frame, encap-agnostic" UDF contract.)

### Added
  - **Per-flow cross-card latency correction (Stage 2).** The single global
    `lat_correction` CSR (0x0144/0x0148) is replaced by a per-flow window
    (`0x0180 + slot*8`, atomic LO-stage/HI-commit) feeding a data-plane
    `lat_corr_table[NUM_FLOWS]`. The RX checker now corrects each flow's slot
    independently (`lat = (rx_wire_ts + corr[slot]) - tx_ts`), so a single RX
    card may mix same-card flows (corr 0) with cross-card flows from different TX
    cards (each its own offset) — the Stage-1 global-per-card validator
    constraint is removed. To hold dp_clk timing the per-flow table mux is
    registered one extra cycle (+5) before the checker, off the latency-calc cone
    (the SAF/drop/punt path stays at +4). Daemon servo + prime write per-slot
    corrections (`pw_gpio_sync_write_correction(be, slot, corr)`).
  - **Cross-card latency HW correction (`lat_correction` CSR).** The RX checker
    now takes a signed 64-bit correction (CSR `0x0144/0x0148`, broadcast to every
    port's checker) and computes `lat = (rx_wire_ts + lat_correction) − tx_ts`, so
    cross-card latency is corrected **per sample in hardware** — min/max/sum and
    the histogram all accumulate the true one-way value. This supersedes the
    earlier SW read-time single-offset correction, which left max/avg smeared by
    the ~1.6 ppm clock skew over a long accumulation (and forced avg-omit +
    histogram-unsupported for cross-card). Same-card flows use `lat_correction = 0`
    → bit-identical to before. The free-running counter is still never disciplined
    (Gray-CDC safe); only this computation is. Daemon servo + `flow.stats` cleanup
    land alongside. Robustness: the CSR commits atomically (LO stages a shadow,
    HI commits the 64-bit pair in one cycle -- no torn transient); the daemon
    primes the correction + `stats.clear`s on (re)program so the startup window
    can't pollute min/max/hist; the validator enforces the stage-1
    global-per-card limit (a cross-card RX card may not also receive a same-card
    flow, nor cross-card traffic from >1 TX card); the servo reads an
    EDGE-COHERENT offset (`pw_gpio_sync_offset_coherent` brackets the two-card
    read with seq re-reads, rejecting a sample where a sync edge landed mid-read
    -- which would otherwise write a ~1-period-wrong offset), skipping the write
    on an incoherent read; `flows`/`flow.stats` report `latency_method` with
    `latency_valid: true` for cross-card; and `pw_stats_aggregate` now surfaces
    cross-card latency too (`latency_valid: true` + a `cross_card` flag) instead
    of zeroing it. The servo period is tunable via `packetwyrmd -S SERVO_MS`
    (default 10 ms): the residual from the ~1.6 ppm clock skew between updates is
    `skew x period` (~16 ns at 10 ms, ~1.6 ns at 1 ms), so a tighter period
    sharpens cross-card max/jitter with no bitstream change (the J5 edge refreshes
    every ~210 us, the floor below which it's moot). `flow.stats` `offset_ticks`
    surfaces the live (edge-coherent) offset the servo is applying.
  - **Cross-card one-way latency in packetwyrmd/pktwyrm.** A flow whose TX and RX
    ports are on different cards now reports latency (previously rejected as
    "cross-card flow does not support latency/jitter"). The daemon brings up the
    J5 GPIO time-sync on load (one master, others slave); new `pktwyrm latency`
    prints per-flow one-way latency (same-card exact / cross-card corrected).
    HW-validated: cross-card min ~30 ticks (~192 ns), matching the single-card
    wire-to-wire figure. Library helpers `pw_gpio_sync_*`
    (libpacketwyrm/gpio_sync). Needs the J5 headers wired. **Correction now
    happens per sample in hardware** (see the `lat_correction` entry above) --
    this superseded the initial read-time offset scheme, which left avg/max
    smeared and the histogram cross-card-unsupported.
  - **RX ingress wire-stamp.** Received frames are now timestamped in the MAC RX
    clock domain at SOF (a second `pw_ts_gray_cdc` per port, dp_clk→`sfp_rx_clk`),
    carried through the RX async FIFO as widened `tuser` (`pw_mac_axis_cdc`
    `RX_USER_W` 1→65 = `{rx_wire_ts, fcs_err}`) and through `pw_parser_axis`
    aligned with the key. The RX checker now computes latency as
    `rx_wire_ts − tx_wire_ts` (both SOF-referenced) = true **wire-to-wire**, free
    of the store-and-forward FIFO + parser + classifier pipeline delay and
    frame-size independent. The same stamp is the servo-facing RX event time in
    the punt metadata (previously a post-FIFO dp_clk sample). Single-card payoff
    is modest (loopback jitter already ~0); the real value is cross-card one-way
    latency once two cards share a time base via the J5 GPIO sync.
  - **Stateless TCP segment generation.** A flow selects `tcp:` instead of
    `udp:` (mutually exclusive) to emit fixed-form TCP segments — a 20-byte TCP
    header (data-offset 5, configurable `flags` byte defaulting to 0x02 SYN,
    window 0xFFFF, seq = test sequence, ack/urgent 0) with a correct L4 checksum
    for both IPv4 and IPv6, the 32-byte test header carried in the TCP payload so
    loss/latency/sequence measurement is identical to UDP. This is a generator,
    NOT a connection engine (no handshake / ACK tracking / retransmit / window).
    The per-proto minimum legal frame (IPv4/TCP ≥ 86 B, IPv6/TCP ≥ 106 B) clamps
    a smaller `frame_len` up. RX test-header classification covers TCP up to the
    parser capture depth (the deepest v6-encap TCP test header is not RX-classified
    at the current 160-byte depth; TX generation is unaffected).
  - **IPv6 source/destination classifier matching.** Forward rules accept
    `ipv6_dst` / `ipv6_src` (address or `addr/prefix`) compiled to masked field
    comparators (all four IPv6-src words are now selectable; `/64` costs 2 of the
    12 per-card comparators + 1 `is_ipv6` guard, `/128` costs 4 + 1; the compiler
    dedups and returns `PW_E_NO_RESOURCES` with a diagnostic when over-subscribed).
    `classify: header` flows accept `match: { ipv6_dst_prefix / ipv6_src_prefix }`
    to narrow the hash key (the key mask is per-card global).
  - **Full 128-bit IPv6 address modifiers.** `src_ipv6` / `dst_ipv6` modifiers
    accept a full IPv6-literal mask (rotate the whole 128-bit address); a bare
    ≤32-bit hex still rotates the low 32 bits (back-compatible). Each 32-bit lane
    is field+lane-salted so a full-mask rotation emits four distinct words and
    src ≠ dst (de-duplicated deterministic streams, ~2³² period). Increment mode
    and all existing v4/port/MAC/VLAN modifiers are byte-identical to before.
  - (Stateless line-rate TCP segment generation is implemented on the
    `phase3-tcp-gen` branch but deferred from this build: A+B+C together exceed
    the xcku3p routing budget (~93% LUT), so TCP ships after a dedicated
    LUT-reduction pass.)

### Fixed
  - **`DP_RESET` now also resets the MAC-TX CDC, to recover a presumed TX-FIFO
    wedge in-system.** The data-plane soft reset only quiesced dp_clk-domain
    state (gen / SAF / arbiters); the per-port MAC-TX CDC FIFO + `pw_ts_insert`
    live in the MAC tx_clk domain and were outside it. An observed egress hang
    (every flow `tx=0`, inject `INJECT_STATUS_BUSY` stuck, link still up) cleared
    only on an ICAP reboot / power cycle — consistent with a stuck TX-FIFO state.
    The `DP_RESET` pulse is now stretched in dp_clk and CDC'd into each MAC
    tx_clk to flush the TX FIFO (both sides) and reset `pw_ts_insert`. This
    re-initialises the TX-CDC state while the TX clock is running; it does not
    cover the MAC/PCS/GT, the RX CDC, or a stopped TX clock (still a reboot).
  - **Sub-minimum frame lengths no longer stall a flow.** The generator clamps a
    too-short frame up to the minimum legal size (incl. VLAN/encap/IP family);
    the SW now computes that same minimum and applies it to the token-bucket cap
    **and** the rate_pps byte basis, so a flow configured below the minimum (e.g.
    64 B) transmits at the right rate instead of starving (cap < cost).
  - **Reloads no longer leave stale classifier / flow / hash / map entries.**
    `pw_program_card_tables` now writes every table to its full capacity on each
    load: configured entries enabled, all remaining slots invalidated (flow rows
    zeroed, rules `enable=0`, hash buckets + flow-id-map entries `valid=0`).
    Previously a reload that *shrank* the config left the deleted flows / punt /
    forward / TEST_RX entries live, since the RTL commit only copies
    shadow→live without touching un-written slots. HW-validated on the loopback
    (4-flow multiflow, lost_est=0, correct per-slot classification).
  - **Slow-path inject window bounds-checks its inputs** (`pw_inject_tx_window`):
    `byte_len` is clamped to the 512 B buffer and out-of-range DATA word writes
    are dropped, so a malformed host inject can't alias onto a valid beat or emit
    a frame longer than the buffer. (RTL; ships in the next bitstream.)
  - **TX-arbiter source-select width** (`pw_data_plane_axis` `SELW`) widened to
    `$clog2(PW_PORTS + 2)` to cover the host-inject source index (`PW_PORTS+1`);
    the old `+1` was correct only by luck at `PW_PORTS=2`. (RTL; future-proofs
    `PW_PORTS≥3`.)
  - **config.load now rolls back on a staging failure** instead of swapping the
    daemon's view to a config the FPGA may not actually hold. If programming a
    card hard-fails (BAR error / card drop), the daemon re-programs the previous
    config, keeps it running, and rejects the load with an error — matching the
    documented behavior (`docs/design/daemon.md`). A half-applied config (daemon
    view != FPGA) was the worst failure mode for a tester.

### Changed
  - **dp_clk timing + LUT optimization (WNS -0.001 → +0.132 ns; LUT 89.2% →
    87.9%).** Two targeted changes recovered the razor-thin timing the
    variable-frame-length work left:
    * `pw_hash_classifier` pipelined 2→3 cycles — a masked-key register splits
      the dp_clk-critical `parser-key → assemble → mask → XOR-fold → multiply →
      BRAM-address` path (the actual WNS path). The data plane delays the field
      classifier + flow-id map results and the decision/`rx_kv_d` chain by one
      cycle so all three classification paths stay aligned at the precedence mux.
    * `pw_spi_flash` TX/RX buffers moved from two 512-byte register arrays
      (~10K LUT of byte-indexed muxes) to 32-bit-word block RAM; MOSI is a direct
      bit-select of the current word (the 1-cycle BRAM latency is absorbed by the
      SCK divider) and RX accumulates words. The CSR read is now a 1-cycle
      pending read (`spi_pend`, like the histogram/punt windows).
    HW-validated on the xcku3p loopback: map + hash-hit (24-flow header-classify)
    loopbacks loss=0, SPI JEDEC-ID read + 512 B live write/verify OK, link stable
    (blk_lock_loss=0). All Verilator tbs green.

### Added
  - **TCP SYN generator (`pw_tcp_syn`) over the slow-path inject.** Reuses the
    existing `slow_path_tx` arbitrary-frame path: the host composes a complete
    Ethernet/IPv4/TCP-SYN frame with the IPv4 + TCP checksums computed in
    software and the FPGA emits it verbatim — no RTL/bitstream change. Per-packet
    randomized src ip / src port / sequence (SYN-flood realism). HW-validated:
    frames egress and arrive on the loopback (fcs=0, correct size); the SW IPv4
    and TCP checksums fold to 0xFFFF (a DUT will accept them). This is the slow
    path (one frame per CSR sequence, tens of k pps — fine for protocol/
    functional SYN testing and low-rate floods); a *line-rate* TCP generator
    would need the streaming generator (`pw_flow_gen_multi`) to emit a TCP header
    + checksum, a separate RTL change.

### Fixed
  - **Punt rules narrowed; fake backend no longer a silent default.** BGP punt
    now matches **TCP port 179 only** (one rule per direction — listener dst:179,
    initiator src:179) instead of all TCP, so generated TCP test traffic (e.g. a
    SYN flood on other ports) is not swallowed by the slow path. IS-IS punt now
    matches the 802.3/LLC DSAP/SSAP (0xFEFE) via a UDF instead of a catch-all
    that punted **every** frame on the ingress (fails safe: under-matches rather
    than over-matches if the parser's L3 base differs for length-encoded frames).
    Pure compiler change (existing bitstream's L4-port comparators + UDFs);
    HW-confirmed it programs cleanly with the data plane at loss=0. The daemon
    no longer falls back to the no-op **fake backend by default** — a BAR-open
    failure is now an error unless `--allow-fake`/`-F` is passed (dev/CI), so a
    real deployment can't look healthy while silently dropping all CSR writes.
  - **Code-review hardening (config/validation/daemon).** `rate_pps` is now
    realized (compiler computes pps × frame bytes → token rate; a pps-only flow
    transmitted 0 frames before — HW-validated tx>0, loss=0). The config parser
    now validates traffic: exactly one of `rate_bps`/`rate_pps`, frame-length
    range [64,1518], `frame_len_min ≤ frame_len_max`, `frame_len_step ≥ 1`, and
    `frame_len` vs the `frame_len_min/max/step` triple are mutually exclusive
    (schema gained the matching `oneOf`; max tightened 9216→1518 to the FIFO/RTL
    limit). `program_backends` returns the worst hard status (card drop / BAR
    error), and `config.load` reports it (`ok=false` + `program_error`) instead
    of always succeeding. RPC `config.load` response key fixed
    `n_classifier_rules`→`n_classifier_rows` (matches the CLI + docs; the CLI
    printed 0 rows). `pw_rfc2544` now aborts on any CSR op failure (naming the
    failing access) and validates `trial_ms`.

### Added
  - **Variable frame length in the generator + RFC 2544 driver** — the test
    generator (`pw_flow_gen_multi`) now honors `frame_len_min/max/step`: each
    slot emits a total L2 frame length that is fixed (`min==max`, RFC 2544) or
    sweeps `min→max` by `step` (IMIX). Previously these fields were plumbed
    through the config/window but ignored — every flow emitted a fixed 74 B
    frame regardless of `frame_len`. The L4 payload pad is generated on the fly
    (the 176 B header buffer is unchanged; the FSM streams zero pad out to the
    frame length), and the IPv4/IPv6/UDP length fields + length-dependent
    checksum terms track the per-frame size. New `pw_rfc2544` tool automates the
    RFC 2544 methodology (throughput binary-search to zero sequence loss,
    latency at throughput, loss@line-rate) across the standard frame sizes on
    the loopback/DUT. Also bumped the MAC↔dp_clk frame FIFO (`pw_mac_axis_cdc`
    DEPTH 1024→2048 B): the taxi FRAME_FIFO drops oversize frames, so the 1 KB
    buffer silently capped frame size at ~1 KB — invisible while the generator
    only ever emitted 74 B. Validated: `tb_flow_gen_multi` sweeps {128,192,256}
    with matching IPv4 total_len + valid header checksum; full Verilator suite
    green; on HW the loopback shows real per-size results — latency scaling
    493/698/1107 ns for 128/256/512 B at ~line rate, loss=0 (1280/1518 B need
    the 2048 B FIFO). (64 B is below the 74 B test-frame floor — eth+IPv4+UDP+
    32 B test header — so it reports n/a.)
  - **Punt RX wire-timestamp (servo-facing PTP hook)** — punted frames now carry
    a 64-bit RX timestamp: the free-running counter latched at the frame's SOF in
    the data plane, threaded through the SAF in the punt metadata and exposed at
    `PWFPGA_REG_PUNT_RX_TS_LOW`/`_HIGH` (0x1010/0x1014; `PWFPGA_PUNT_DATA` moved
    to 0x1020). `slow_path_rx()` gained an `out_rx_ts` argument (read before the
    POP releases the slot). This is the RX-event capture a software PTP servo
    needs (e.g. Sync arrival time); the TX (inject) egress timestamp + the full
    two-clock servo loop follow (the latter gated on a second card). Validated:
    `tb_punt_window` RX_TS readback + `pw_phase3_punt` reports a monotonic
    `rx_ts` per punted frame.
  - **Inject TX wire-timestamp (servo-facing PTP TX hook)** — the inject window
    (`pw_inject_tx_window`) latches the free-running counter at the injected
    frame's first egress beat and exposes it at `PWFPGA_REG_INJECT_TX_TS_LOW`/
    `_HIGH` (0x0D08/0x0D0C). With the punt RX timestamp this gives a servo both
    event times (e.g. Delay_Req departure). Validated single-card: `pw_phase3_
    inject` injects a frame, reads its `tx_ts`, loops it back, and confirms the
    punt `rx_ts > tx_ts` (the loopback latency). Completes #60's TX/RX wire-
    timestamp exposure; the full two-clock servo loop remains gated on a 2nd card.
  - **Hash exact classifier — high-count payload-agnostic flows, wide masked
    key** (`pw_hash_classifier`; CSR window `PWFPGA_WIN_FC_HASH` @ 0x3000, mask
    window `PWFPGA_WIN_HASH_MASK` @ 0x2F00, seed reg `PWFPGA_REG_HASH_SEED`).
    Classifies a frame by an EXACT, MASKED match on a WIDE header key — 11
    field-aligned 32-bit words covering the full IPv4/IPv6 **5-tuple** (src+dst
    IP, src+dst port, proto) **+ VLAN + ethertype** — scaling payload-agnostic
    classification to the checker's `NUM_FLOWS` (vs the field comparators' ~`NCMP`
    cap) and without the test-header `flow_id`, so the payload stays free.
    Direct-indexed BRAM hash table (1 read + 1 full-key verify, NOT an N-way
    parallel match, so it routes): the key XOR-folds to 32 bits, a Dietzfelbinger
    multiply-shift (seed) chooses the bucket, and the stored full key is compared
    for an exact hit (the hash only picks the bucket — no misclassification). A
    **global key mask** (ANDed into both the hash input and the verify) selects
    which bits participate: masking out a field/bits lets a generator **modifier
    randomize** them while the flow still classifies. The compiler routes
    `classify: header` flows here, builds the global mask (key everything, then
    relax the bits any flow randomizes via modifiers or narrows via match masks),
    and searches a hash **seed** that places the masked keys collision-free; the
    field+UDF classifier then carries only punt/forward. Data-plane precedence:
    flow-id **map > hash classifier > field classifier**. Bit-identical HW/SW
    hash + key build. Completes Phase 5 of `docs/design/generic-classifier.md`.
    Examples: `phase3-header-classify.yaml` (24-flow exact scale test),
    `phase3-header-random.yaml` (randomized src port, masked out of the key).
  - **Classifier redesign — unified field+UDF comparator engine; legacy
    classifier retired** (`pw_field_classifier` + `pw_slice_match`; CSR windows
    `PWFPGA_WIN_FC_CMP`/`_UDF`/`_RULE` @ 0x2000). Replaces the parallel
    `pw_classifier` (an N×~600-bit masked-key compare that hit the xcku3p route
    wall at ~16 entries) AND the interim slice classifier with one engine:
    `NCMP` (12) **field comparators** each `{src,mask,value}` over a 32-bit lane
    selected from the parser's canonical fields (mux-free — the parser already
    extracts + position-normalizes them, so a 128-bit IPv6 addr is 4 comparators
    over its lanes); `NUDF` (2) **UDF comparators** `{offset,mask,value}` over the
    raw inner-frame window (for DSCP/TTL/flow-label/TCP-flags/arbitrary bytes);
    and `NRULE` (32) **rules** that AND a `care` subset of the comparator bits
    into `{action,egress,lfid,lif}`. The per-rule compare is only NCMP+NUDF bits,
    so it routes far past the legacy ~16 wall — and **retiring the legacy 600-bit
    classifier frees the RX-region routing budget** so the engine + the 32-flow
    data plane fit together on the xcku3p (the interim slice classifier could not
    route at 32 flows alongside the legacy one). Handles every action the legacy
    did (TEST_RX / PUNT / MIRROR / FORWARD / DROP); the compiler lowers
    header-defined test flows (`classify: header`) + punt + forward rules to
    comparators + rules, while structured high-count TEST_RX still rides the
    flow-id map. **Payload-agnostic**: a flow classified by header carries no
    dependency on the test `flow_id`, so its payload is free. The parser exposes
    the header byte-window (`window_o`) + inner-L3 base (`base_o`) aligned with
    `key_valid_o` (encap-aware UDF offsets). The RX checker now counts
    **non-test** frames too (rx_frames only; loss = tx-vs-rx count), so
    arbitrary-payload or external DUT traffic is countable, while structured test
    frames keep full seq/latency/jitter. (The standalone `pw_phase3_{punt,
    forward,modgen,inject,ipv6gen}` tools still target the legacy classifier and
    need migration to the field-classifier programming.)
  - **TEST_RX flow-id map — scalable flow classification** (`pw_flowid_map`,
    `PWFPGA_WIN_FLOWID_MAP` @ 0x0400). A test frame's parsed `test_flow_id`
    directly indexes a BRAM table → its checker slot (gated by the parser's
    magic/`is_test`), so TEST_RX flows no longer need a per-flow classifier
    rule. This removes the route-congestion wall that capped the parallel
    classifier at ~16 entries on the xcku3p — test-flow count is now bounded by
    the checker/generator (`NUM_FLOWS`), not classifier routability. The
    parallel classifier (`pw_classifier`, 16) now carries only the few non-test
    rules (PUNT/FORWARD/DROP) and routes comfortably. The compiler emits a map
    entry per TEST_RX flow (`flow_id → local slot`) instead of a classifier
    rule; the data plane overrides the classifier result for map-matched test
    frames. Keying on the stable `flow_id` also makes header-field modifiers
    (udp_dst/ip rotation) irrelevant to RX classification. First piece of the
    generic slice-based classifier (`docs/design/generic-classifier.md`);
    `pw_slice_match` (the programmable offset/mask/value extractor for the
    flexible front-end) is also landed + unit-tested.
  - **Classifier IPv6 dst-address match** — a TEST_RX rule for an IPv6 flow now
    matches the inner IPv6 **destination** address exactly, in addition to
    udp_dst + l3_proto + magic + flow_id. The 40-byte `pwfpga_match_key` has no
    room for a 128-bit address, so the dst key + mask live in the classifier
    row tail (bytes 96..127 — the entry was 96 B of a 128 B stride, so no row
    growth); `pw_classifier_window` decodes them (network byte order, matching
    `pw_parser_axis`). The match is exact (`==`), so the compiler skips it when
    a dst modifier rotates the address (shared `dst_ipv4` field, low 32 bits of
    v6) — udp_dst+magic+flow_id still identify the flow there. The `pw_classifier`
    match logic + parser extraction already existed; this wires the host path.
  - **Per-flow IPDV jitter** — `pw_test_rx_checker` now tracks each flow's
    previous-sample latency and accumulates `|latency[n] - latency[n-1]|` into
    per-flow jitter min / max / sum (RFC-3393 instantaneous packet delay
    variation; the first sample only seeds `prev_latency`). Surfaces in the flow
    stats block at jitter_min@104 / jitter_max@108 / jitter_sum@112 and is
    printed by `pw_phase3_loopback` (with a derived average over n-1 deltas).
    min/max (and the internal `prev_latency`) are 32-bit — a single inter-arrival
    delta never approaches 2^32 ns, and the snapshot fields are u32 anyway — while
    `sum` stays 64-bit (it accumulates over the whole run); this reclaims the
    dp_clk LUT headroom that a fully-64-bit jitter path had pushed to ~90%.
  - **Per-port link health + FCS errors** — `pw_data_plane_axis` 2-FF
    synchronizes the async MAC/PCS `link_up` / `block_lock` status into `dp_clk`
    and edge-counts link-up / link-down transitions and block-lock losses
    (`link_up_count@64` / `link_down_count@68` / `block_lock_loss@72`, sticky
    across `stats_clear`); RX `tuser`-on-`tlast` errored frames are counted into
    `rx_fcs_error@16`. A `set_false_path` constrains the status synchronizer.
  - **Per-flow TX counters (true loss = tx − rx)** — the generator keeps a
    clearable per-slot TX frame counter that merges into the flow stats block's
    `tx_frames`; `pw_phase3_loopback` prints `tx / rx / loss(tx−rx)`. (The
    snapshot reads tx and rx non-atomically, so a single frame in flight shows
    as loss(tx−rx)=±1; `lost_packets_estimated` is the authoritative loss.)
  - **Per-port Tx/Rx frame + byte counters** — `pw_data_plane_axis` now counts
    every frame/byte at each port's ingress (rx_frames/rx_bytes) and egress
    (tx_frames/tx_bytes), 48-bit (zero-extended to the 64-bit snapshot fields),
    filling the previously-zeroed `pw_port_stats` slots. The SAF forward-buffer
    overflow (previously a silent drop) folds into `port_drops`, and a stats
    clear now re-baselines the port counters + `port_drops`. `pw_phase3_loopback`
    prints them. NUM_FLOWS dropped 32→24 for the LUT headroom (80.7%, dp_clk
    +0.038 met). HW-validated: per-port counters track the loopback (p0 tx ==
    p1 rx), encap matrix still loss=0.
  - **Encapsulated packet generation + RX decap (IPIP / GRE / EtherIP)** — a flow
    can set `encap: { type, outer: {ipv4|ipv6} }` to wrap its inner IP/UDP/test
    frame in a tunnel: IPIP (outer-IP proto 4/41), GRE (proto 47 + 4-byte GRE),
    or EtherIP (proto 97 + 2-byte EtherIP + inner Ethernet, whose MAC is set by
    an optional `encap.inner_l2` block or defaults to the flow MAC). The outer family is
    independent of the inner — every v4/v6 inner × v4/v6 outer combination is
    supported. The generator builds the full stack and the outer IPv4 header
    checksum; egress timestamping rewrites the inner test header's tx_timestamp
    and fixes up the inner UDP checksum at its (encap-dependent) deep offset; the
    RX parser auto-decapsulates recognized tunnels and classifies on the inner
    test flow. `rx_expect: inner|tunneled` records whether the DUT decapsulated
    the return traffic. Full stack: config/wire/compiler, RTL (generator,
    `pw_ts_insert`, `pw_parser_axis`, flow table/row), sims (`sim_fge` byte-level
    + gen→decap round-trip, `sim_tsi` deep-offset cases, `sim_ftb`), and docs.
    **Validated on HW** (KU3P, SFP+ DAC loopback): all four combos — IPIP v4/v4,
    IPIP v6/v6, GRE v4-in-v6, EtherIP v4/v4 — run loss=0 at line rate, latency
    70–82 ns, 0 drops (`configs/examples/phase3-encap{,-matrix}.yaml` via
    `pw_phase3_loopback`).
  - **BRAM-backed flow table** (`pw_flow_table_bram`) — to fit the encap-widened
    data plane on the fabric: the 32-wide registered flow-row array + its fan-out
    + the per-generator 32:1 row mux (the routing wall, ~92% LUT) were replaced
    with a block-RAM table (decoded once via a commit walk into a per-generator
    BRAM copy) + a compact per-slot scheduling FF array; the dead legacy
    `gen_*_o` selection was removed. LUT 92%→87%, FF 78%→66%, +34 RAMB36. The
    parser was split 2→3 stages (L2+decap-descent / inner L3-L4 / test extract)
    and the quasi-static shadow→live commit paths multicycled, to recover dp_clk
    margin. Host CSR/wire format unchanged.
  - **Background (load) flows** — a flow can set `background: true` to generate
    TX-only traffic with no RX classifier rule and no measurement. Background
    flows don't consume a classifier entry, so a config can run more generator
    flows than the classifier capacity (e.g. 32 gen slots / 16 measured). SW
    only (the compiler emits the TX flow row but skips the TEST_RX rule).
  - **Bitwise (TCAM-style) classifier matching on dst port + dst IPv4** — the
    classifier compares `(key & mask) == (rule_key & mask)` for `l4_dst`/
    `udp_dst` and `ipv4_dst`, so a rule can match only part of a field. Enables
    using a generator modifier on a *classified* field (the rule matches the
    fixed bits; the compiler auto-relaxes the mask to exclude the rotated bits)
    and classifying arbitrary-payload traffic by header bits via a YAML
    `match: { udp_dst, ipv4_dst }` block. All-ones mask = exact (back-compatible
    with the prior boolean match); 0 = wildcard. The wire format is unchanged
    (the per-entry mask already carried the bytes; the RTL stopped OR-reducing
    them to a boolean). `sim` gains a partial-port match/non-match scenario;
    unit test covers the compiler mask emission + auto-relax + background.
  - **MAC / VLAN field modifiers** — extends the generator's field-modifier
    scheme to `src_mac` / `dst_mac` (48-bit mask) and `vlan` (low 12 bits),
    same `mode` (static/increment/random) + `mask` syntax as the address/port
    modifiers. These only rewrite the Ethernet header (not in any checksum),
    so they sit off the dp_clk checksum-critical path. Wire row gained the
    MAC/VLAN modifier fields at bytes 140..156 (256 B stride unchanged);
    `pw_field_mod.mask` widened to 64-bit to carry the 48-bit MAC mask.
    `sim_fgm` checks src-MAC and VLAN-ID rotation; unit test covers the
    config → wire mapping (MSB-first MAC mask, 12-bit VLAN mask).
  - **IPv4/IPv6 generator feature parity** — IPv6 flows gained the features
    previously IPv4-only: (1) **address field modifiers** — `src_ipv6` /
    `dst_ipv6` (YAML, same syntax as the v4 keys) rotate the low 32 bits of
    the address (host / interface-ID) per frame for DUT hashing / ECMP
    testing; the modified address is folded into the IPv6 UDP checksum in
    hardware. The wire reuses the existing address-modifier slots (a flow is
    one family), applied to the active family. (2) **DSCP / traffic class**
    and **TTL / hop limit** are now emitted from config for *both* families
    (`ipv4.dscp` -> IPv4 TOS, `ipv6.dscp` -> IPv6 traffic class; `ttl` /
    `hop_limit` -> the respective header field) — previously both were
    silently hardcoded (TOS=0, TTL=64), so the IPv4 `dscp` config was a
    latent no-op; the IPv4 header checksum now includes TOS + TTL. Defaults
    (dscp 0, ttl/hop_limit 64) keep existing configs byte-identical.
    `sim_fgm` checks both families' DSCP, TTL/hop-limit, and the IPv6
    address modifier (rotates low bits, keeps high bits, checksum valid).

- **Phase 3 data plane on silicon (AS02MC04 / KU3P)** — the 64-bit
  streaming data plane runs on hardware at line rate, loss=0:
  - Rewrote the unroutable wide `pw_frame_t` bus into a 64-bit AXIS
    streaming plane (`pw_parser_axis`, `pw_flow_gen_multi`,
    `pw_frame_saf`, `pw_data_plane_axis`); closes timing at 156.25 MHz.
  - Scaled to **32 flows / 16 classifier rows / 16 latency bins**;
    bidirectional + 16 concurrent flows validated at loss=0.
  - **Store-and-forward FORWARD validated on silicon** — a classifier
    `FORWARD_PORT` rule routes ingress frames through `pw_frame_saf` to
    the egress port; HW test (`pw_phase3_forward`) crossed the DAC twice
    at line rate with loss=0.
  - **FORWARD egress port now host-selectable** — added
    `egress_local_port` (byte 92) to the classifier wire struct and
    decoded it in `pw_classifier_window`; the data plane already routed
    by the classifier result's `egress_port` (previously hardwired to
    0). `pw_phase3_forward [fwd_egress]` validates routing to either
    port; `sim_vec` covers the new wire byte.
  - **FORWARD rules from config** — a top-level `forwards:` YAML section
    (ingress/egress port + optional ethertype/ip_proto/udp_dst/vlan
    match) compiles to classifier `FORWARD_PORT` rows; ingress/egress
    must be on the same card. Example `configs/examples/phase3-forward.yaml`;
    schema in `docs/design/yaml-schema.md`.
  - **Timing margin recovered** — pipelined `pw_parser_axis` key extract
    into two stages; WNS +0.003 → +0.020 ns at 156.25 MHz, HW-revalidated
    at loss=0.
  - **IPv6 test-flow generation** — the generator now emits IPv6/UDP
    frames (ethertype 0x86DD, 40-byte header) with a correct, non-zero
    UDP checksum (IPv6 mandates it). The generator computes a *partial*
    checksum (IPv6 pseudo-header + UDP + payload, **minus** the
    tx_timestamp) and `pw_ts_insert` folds the egress departure stamp into
    it at the MAC, yielding the final valid checksum on the wire — so IPv6
    flows get the same DUT-accurate egress timestamping as IPv4 (see
    below). Selected per flow via a YAML `ipv6: {src,dst,hop_limit}` block
    (mutually exclusive with `ipv4:`); the flow-table row stride grew
    128→256 B to carry the 16-byte addresses. The test header is unchanged
    so RX loss/latency is identical. Example
    `configs/examples/phase3-ipv6.yaml`; `sim_fgm` checks the IPv6 partial
    checksum, `sim_tsi` checks the egress finalization + a forwarded
    IPv6/UDP frame left untouched; HW tool `pw_phase3_ipv6gen`. (Field
    modifiers remain IPv4-only in v1; IPv6-address modifiers are a
    follow-up.)
  - **IPv6 egress hardware timestamping + UDP-checksum fixup** —
    `pw_ts_insert` now detects the L3 family and overwrites tx_timestamp at
    the correct IPv6 offset (byte 82, +4 VLAN), and finalizes the IPv6 UDP
    checksum by adding the four departure-stamp words to the generator's
    partial sum (RFC 768 `0→0xFFFF`). One-pass, no buffering: the csum
    field (@60) precedes tx_ts, so only the new (SOF-latched) stamp is
    needed. Gated by a "generator test frame" marker the egress arbiter
    raises (`sel_gen`), carried as AXIS `tuser` through the MAC-TX CDC, so
    forwarded / injected IPv6/UDP traffic is never rewritten; the marker is
    consumed in the stamper (MAC sees `m_tuser=0`).
  - **Timing: registered flow-table decode + generator checksum
    precompute** — recovering the margin the 256-byte rows + IPv6 checksum
    cost, without cutting flows/scale. (1) `pw_flow_window` registers the
    decoded `flow_rows_o`; with 256-byte rows the decode fan-out into the
    generators was a dominant `dp_clk` path (commit lands one cycle later,
    harmless). (2) `pw_flow_gen_multi` precomputes the modifier-applied
    header fields + IPv4/IPv6 checksums one stage ahead, registered
    alongside the round-robin `pick` (same 1-cycle staleness, so they align
    with the built row), so the frame-build cycle only lays out bytes
    instead of running mod32/scramble + the checksum adders. Made possible
    by excluding the live tx_timestamp from the IPv6 checksum (it is folded
    in at egress), which makes the whole checksum pick-stable. (3) The IPv6
    UDP checksum is summed as a single multi-term expression rather than
    sequential `+=`, so synthesis maps it to a balanced adder tree instead
    of a deep carry chain — this cone was the dp_clk-critical path.
  - **Generator field modifiers + correct IPv4 checksum** — per-field
    modifiers (`static` / `increment` / `random` with a bitmask) on
    `src_ipv4` / `dst_ipv4` / `udp_src` / `udp_dst` rotate the masked bits
    per emitted frame (driven by the slot's sequence number, no extra
    per-slot state), so one generator slot looks like many flows to the
    DUT. The test header (magic/flow_id/seq/ts) is never modified, so RX
    loss/latency measurement is unaffected. `build()` now emits a correct
    IPv4 header checksum (was 0), recomputed from the modified addresses.
    Configured via a `modifiers:` block per flow (`forwards`-style); see
    `configs/examples/phase3-modifiers.yaml` and `docs/design/yaml-schema.md`.
    Sim (`sim_fgm`) verifies the dst-IP rotation (masked) + a valid on-wire
    IPv4 checksum.
  - **SAF buffer BRAM-backed** — `pw_frame_saf`'s 512-beat frame buffer
    now infers as block RAM (reset-less write port + registered read-ahead
    drain) instead of ~37k FFs/instance + a wide mux. Frees ~24% of device
    FFs and ~14% LUTs across the two instances, which de-congested the
    route-dominated paths: **WNS +0.005 → +0.143 ns** with no feature or
    scale change. HW-revalidated (loopback loss=0, FORWARD, PUNT, inject
    round-trip).
  - **PUNT / slow-path RX to the host** — `pw_punt_rx_window` sinks the
    data plane's punt AXIS (`PUNT_TO_HOST` / `MIRROR_TO_HOST`) into a
    CSR-polled single-frame buffer (`PWFPGA_WIN_PUNT_RX`, BAR, no DMA).
    The SAF now carries each frame's `logical_if_id` + ingress port as
    metadata; `bar_slow_path_rx` drains frame + lif, and the daemon
    `host_plane` routes them to the per-`logical_if_id` TAP. New
    `sim_punt` unit tb; the `sim_top` punt scenario reads the frame back
    over the CSR BAR (lif verified).
  - **PUNT / slow-path TX from the host** — `pw_inject_tx_window` is the
    host → FPGA complement: the host composes a frame in a CSR buffer
    (`PWFPGA_WIN_INJECT_TX`, 512 B max), sets length + egress, writes GO;
    the window emits it into that egress port's TX arbiter (priority
    between forwarded frames and the generator). `bar_slow_path_tx`
    drives it. New `sim_inj` unit tb + a `tb_data_plane_axis` inject
    scenario (arbiter routes inject to the chosen egress). HW round-trip
    (`pw_phase3_inject`): inject out egress 0 → DAC → RX1 → PUNT → read
    back byte-identical, proving both slow-path directions on silicon.
  - **BRAM-backed latency histogram** (`pw_lat_histogram`) — freed the
    FF wall that capped flow scaling; read live via the CSR window.
  - **Egress hardware timestamping** (`pw_ts_insert` + `pw_ts_gray_cdc`)
    — tx_timestamp applied at the MAC (PTP one-step style), so measured
    latency reflects the DUT, not the tester's own TX queuing.
  - **CSR data-plane soft-reset** (`REG_DP_RESET`) — recover a wedged
    data plane without a JTAG reconfig.
  - **Wide CSR address map** — classifier/flow/stats windows 16 KB,
    histogram 8 KB (128 B stride); commit/trigger/clear above the data
    region. (ABI change; see `docs/design/csr-map.md`.)
- **In-system flash + reconfiguration**
  - `pw_spi_flash` CSR SPI master via STARTUPE3 — erase/program/read the
    config flash live over PCIe (no JTAG); `pktwyrm flash` / `pw_flash`.
  - `pw_icap_reboot` (ICAP IPROG via `REG_REBOOT`) — reload the bitstream
    from flash in-band; `pw_reboot`. The full-feature image is flashed as
    the cold-boot image.
- **Lab integration: pktwyrm-tinet**
  - `tools/pktwyrm-tinet/` generates a [tinet](https://github.com/tinynetwork/tinet)
    topology + per-router FRR configs from a small lab spec that
    references an existing PacketWyrm config. Each router runs in a
    container; its assigned PacketWyrm TAP is moved into the
    container's network namespace via tinet `postinit_cmds`, so
    PacketWyrm stays the data-plane truth and tinet handles the
    container lifecycle.
  - v1 supports BGP (asn / router_id / neighbors / advertised
    networks). OSPF / IS-IS can be added under the same `routing:`
    shape when needed.
  - Lifecycle CLI: `pktwyrm-tinet up LAB.YAML` starts `packetwyrmd`,
    waits for TAPs to appear, runs `tinet up` + `tinet conf`, and
    persists state (pid, tinet.yaml, TAP list) under
    `<out_dir>/.pktwyrm-lab.json`. `conf`, `down`, and `status`
    operate against that state file. `down` is idempotent and falls
    back to a best-effort `tinet down` when the state file is gone
    but a tinet.yaml is still present.
  - `make -C tools/pktwyrm-tinet test`: 35 / 35 tests in pure Python
    (PyYAML + `unittest.mock` only). No docker / tinet / FPGA
    required. Covers golden YAML/FRR rendering, lab-spec schema
    validation, state-file round-trip, shell command construction,
    and the up/down/conf orchestrator (with mocked subprocess).
  - Worked example at `configs/examples/lab-frr-2node/` with two FRR
    routers peering eBGP across a DUT.
  - Lab spec lives in its own file (referencing the PacketWyrm config
    by path); the core daemon and its JSON Schema are untouched.
- **Parser & classifier**
  - QinQ (802.1ad outer + 802.1Q inner) tag decoding
  - IPv6 (40-byte fixed header, source/dest extraction, next-header
    routing to TCP / UDP / ICMPv6)
  - Unified `l4_src` / `l4_dst` for TCP and UDP
  - Protocol class flags: `is_arp`, `is_ipv4`, `is_ipv6`, `is_tcp`,
    `is_udp`, `is_icmp`, `is_icmp6`, `is_ospf`
  - Matching mask bits for each new field
- **Test RX checker**
  - Per-flow min / max / sum / sample-count latency stats
  - Power-of-two latency histogram
- **Flow generator**
  - Token-bucket rate limit with Q16.16 bytes/cycle + burst-byte cap
- **CSR / BAR backend**
  - Wire-format structs (`pwfpga_classifier_entry`,
    `pwfpga_flow_config`, `pwfpga_test_hdr`, DMA descriptor /
    completion) are now `__attribute__((packed))` so the host
    and the RTL share a byte-for-byte view.
  - CSR window strides + commit register offsets centralised in
    `csr.h` (`PWFPGA_CLASSIFIER_STRIDE`,
    `PWFPGA_REG_CLASSIFIER_COMMIT`, etc.).
  - `pw_bar_backend_*` ops are functional end-to-end:
    classifier_write / flow_write / classifier_commit /
    flow_commit / stats_snapshot / port_stats_read /
    flow_stats_read / flow_hist_read all use word-aligned BAR
    writes/reads against the documented window layout.

- **Host stack**
  - `libpacketwyrm/tap.h` &mdash; create / configure TAP devices via
    `/dev/net/tun` + ioctl (no libnl dependency)
  - `libpacketwyrm/host_plane.h` &mdash; FPGA punt &harr; TAP fd
    bridge using slow-path RX/TX FIFOs on the backend
  - `libpacketwyrm/ipc.h` &mdash; length-prefixed JSON over Unix domain
    socket
  - Fake-backend slow-path FIFOs + `pw_fake_backend_inject_punt` /
    `_drain_tx` test helpers
  - `pw_pci_discover()` &mdash; sysfs-based PCI enumeration
  - `pw_bar_backend_open()` &mdash; mmap of
    `/sys/bus/pci/devices/<bdf>/resource0`
- **`packetwyrmd`**
  - Long-running event loop with TAP creation, host_plane stepping,
    SIGINT / SIGTERM clean shutdown
  - **Per-card worker threads**: one pthread per opened card runs
    its own `poll()` over its TAP fds + `pw_host_plane_step()`.
    The main thread keeps the control socket and Prometheus
    listener, so slow-path latency on one card cannot be starved
    by a busy control socket or by another card. Workers exit on
    a `stdatomic` stop flag set by the signal handler.
  - Initial program push to backends at startup
  - JSON-RPC server on a Unix socket:
    `version`, `cards`, `ports`, `flows`, `stats`,
    `flow.start`, `flow.stop`, `flow.stats`, `flow.hist`,
    `test.arm`, `test.start`, `test.stop`, `config.load`
  - **Live config reload** (`config.load`): the daemon accepts
    a fresh YAML body over RPC, parses / validates / compiles
    it, stops old flows, pushes the new program to every open
    backend, and swaps the cfg+prog atomically. Topology
    changes (cards / logical_ifs) are explicitly rejected
    because live TAP/backend swap isn't safe yet.
  - Prometheus `/metrics` exporter on `-p PORT`
- **`pktwyrm`**
  - Offline: `cards`, `ports`, `map`, `load`, `flow show`, `version`
  - Online: `rpc <method>`, `stats [--watch]`, `flow start|stop`,
    `flow stats`, `test arm|start|stop`, `hist latency --flow N`,
    `load <config.yaml> --socket PATH` (live deploy)
- **Packaging**
  - `make install` target with `DESTDIR` / `PREFIX` / split dirs
  - systemd unit (`packetwyrmd.service`), sysusers entry,
    tmpfiles entry, udev rule
- **Examples**
  - `configs/examples/container-frr/` &mdash; FRR-on-TAP via
    `ip netns` recipe, including a smoke-tested `start-r1.sh`
- **AS02MC04 (FPGA side)**
  - Phase 1 Vivado project skeleton with reverse-engineered pin
    assignments sourced from Julia Desmazes (Essenceia) and Alex
    Forencich (Taxi)
  - Verilator lint of the shared + AS02MC04 RTL
  - OpenOCD + J-Link JTAG bring-up recipe
- **Simulation**
  - `make -C sim sim`: Verilator-driven `tb_data_plane.sv`, 38 / 38
    assertions across scenarios: drop, punt, loopback, loss, dup,
    vlan, forward, ooo, rate, qinq, bgp, ospf, ipv6
  - `make -C sim sim_csr`: 24 / 24 assertions exercising the CSR
    window pipeline (AXI-Lite-style writes → shadow → commit →
    typed classifier table → data plane).
  - `make -C sim sim_flow`: 16 / 16 assertions for the flow-table
    window (per-port flow-gen inputs decoded from
    `pwfpga_flow_config` rows, lowest-indexed enabled row wins
    per egress port, atomic commit, disable via re-commit).
  - `make -C sim sim_stats`: 16 / 16 assertions for the stats
    snapshot window (per-port + per-flow counters latched on
    trigger, wire-format byte offsets match `pw_port_stats` /
    `pw_flow_stats`, re-trigger replaces the shadow).
  - `make -C sim sim_lat`: 16 / 16 assertions for the BRAM-backed
    per-flow latency histogram (`pw_lat_histogram`): accumulate via
    per-port checker events, live addressed read through
    `PWFPGA_WIN_HISTOGRAM` (NUM_BUCKETS u64s per flow at
    `lfid * PWFPGA_FLOW_HIST_STRIDE`), and clear.
  - `make -C sim sim_full`: 12 / 12 assertions exercising the
    full `pw_csr_full` AXI4-Lite slave end-to-end: identity
    reads, classifier write+commit through `axi_write`, stats
    snapshot trigger latches counters readable via the
    snapshot window, histogram trigger latches readable buckets.
  - `make -C sim sim_top`: 4 / 4 assertions exercising the
    `pwfpga_top_phase3` end-to-end loop: AXI-Lite host writes
    program both windows, the data plane emits frames via the
    AXIS serializer, the TB loops port-0 TX into port-1 RX
    through the deserializer, classifier hits TEST_RX, and the
    snapshot RPC reports rx_frames > 0. ARP on RX[0] raises
    the punt AXIS path.
  - `make -C sim sim_vec`: 25 / 25 assertions for the C ↔ SV
    wire-format byte-vector regression. A C-side generator
    (`sw/build/gen_bar_vectors`) drives the real
    `pw_bar_backend` ops against a tmpfs BAR, dumps the post-
    write image as a `$readmemh` hex file, and the RTL TB
    replays those dwords through `pw_csr_full` and verifies the
    decoded `pw_classifier_table_t` and per-port flow_gen
    inputs match what the host wrote. Drift in either side
    (csr.h struct layout, classifier_window byte offsets,
    flow_window byte offsets) fails this test before silicon
    ever boots.
- **CSR window RTL (Phase 3 ↔ BAR backend hookup)**
  - `rtl/shared/pw_csr_window.sv` &mdash; generic windowed-row CSR
    table with shadow + write-1-to-commit semantics. Parameters:
    `DEPTH`, `ROW_BYTES`, `WIN_BASE`, `COMMIT_OFFSET`. Live rows
    are exposed as packed byte arrays with byte 0 in the low bits,
    matching the AXI-Lite little-endian wire format.
  - `rtl/phase3/pw_classifier_window.sv` &mdash; adapts the wire-
    format `pwfpga_classifier_entry` rows into the typed
    `pw_classifier_table_t` that `pw_data_plane` consumes.
  - `rtl/phase3/pw_flow_window.sv` &mdash; adapts the wire-format
    `pwfpga_flow_config` rows into per-egress-port flow-generator
    inputs (token bucket Q16.16 tokens/cycle, burst bytes, MAC /
    IP / UDP / VLAN). The lowest-indexed enabled row binds to each
    `egress_local_port`.
  - Wire additions to `pwfpga_flow_config`:
    `tokens_per_tick_fp` (Q16.16 bytes/cycle, host-precomputed
    from `rate_bps` and `PWFPGA_DATA_PLANE_CLOCK_HZ`) and
    `burst_bytes`. The host flow compiler now populates both.
  - `rtl/phase3/pw_stats_snapshot.sv` &mdash; on
    `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER` write, latches the live
    per-flow counters from `pw_test_rx_checker` and the per-port
    drop counters from the data plane into a shadow byte region
    whose layout matches `struct pw_port_stats` /
    `struct pw_flow_stats`. Reads served via `rd_addr/rd_data`.
  - Wire fix: `PWFPGA_FLOW_STATS_BASE` moved from `0x80` to
    `0x100` to keep the per-port stats area (2 × 128 B) from
    overlapping per-flow stats inside the snapshot window.
  - `rtl/phase3/pw_histogram_snapshot.sv` &mdash; same trigger
    semantics, separate window. Stores `NUM_BUCKETS` u64s per
    flow starting at `lfid * PWFPGA_FLOW_HIST_STRIDE`. Reads
    served via `rd_addr/rd_data`.
  - `rtl/phase3/pw_csr_full.sv` &mdash; AXI4-Lite slave (16-bit
    address) that wraps the identity registers and the four
    windows under one decode. Single write-strobe drives all
    four windows; a write to `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER`
    latches the stats and histogram shadows in lockstep.
  - `rtl/phase3/pwfpga_top_phase3.sv` &mdash; board-agnostic
    integration top wiring `pw_csr_full` + `pw_data_plane`
    + per-port AXIS serializer / deserializer pair + a punt
    AXIS master. Per-board tops (e.g. AS02MC04) bring their
    PCIe → AXI-Lite bridge and 10G MAC IP around this core.
  - Wire change: `PWFPGA_CLS_FLAG_ENABLE` (bit 0 of
    `pwfpga_classifier_entry.flags`); the RTL ignores any row
    whose ENABLE bit is clear, and the host flow compiler sets
    it for every TEST_RX and PUNT_TO_HOST row.
- **Kernel driver (Phase 11 starting point)**
  - `kernel/packetwyrm.c` &mdash; out-of-tree PCI skeleton:
    `pci_driver` match on `10ee:a502`, BAR0 ioremap, identity-
    register read, dev_info dump.
  - `kernel/Kbuild` + `kernel/Makefile` for building against
    `linux-headers-$(uname -r)`.
  - `docs/design/kernel-driver.md` scoping doc: when the kernel
    driver becomes desirable vs. sticking with the userspace TAP
    plane, target architecture (NAPI / DMA / ethtool / devlink),
    coexistence rules, risks.

- **Tests**
  - `sw/libpacketwyrm/schema/packetwyrm.schema.json` &mdash;
    JSON Schema (Draft 2020-12) mirror of
    `docs/design/yaml-schema.md`. Informative only (the C
    validator is authoritative); useful for editor plugins
    (vscode-yaml, etc.) and a forcing function to keep the
    schema and the docs in sync.
  - `scripts/check-schema.sh` &mdash; optional dev tool that
    validates the example configs against the schema when
    `python3 + jsonschema + PyYAML` are installed (skips
    cleanly otherwise).
  - `make -C sw test`: 164 / 164 unit-test assertions across
    YAML / validator / flow compiler / backend (fake + BAR
    window writes / stats reads) / PCI discovery / host_plane /
    TAP / IPC
  - `make -C sw e2e`: shell-based daemon ↔ CLI smoke - launches
    packetwyrmd against an example config and walks the full
    JSON-RPC surface from pktwyrm, including `config.load`
    (same-topology accepted, different-topology rejected).
    18 / 18 checks.
  - `make -C sim/cocotb all`: Scapy + cocotb unit suite for the
    Phase 3 sub-modules. 17 / 17 Python assertions across
    `pw_parser`, `pw_classifier`, and `pw_flow_gen` behavioural
    mirrors. Runs under Icarus Verilog (the system Verilator
    5.020 predates cocotb 2.x's 5.036 minimum); the small
    behavioural RTL under `sim/cocotb/rtl/` mirrors the spec
    of the production modules on Icarus-friendly flat ports.
    The Verilator SV suite remains the integration gate against
    the production RTL.

### Documentation

- Initial design docs under `docs/design/` and phase plan under
  `docs/phases/`
- README updated to reflect the current implementation status
- Per-board bring-up notes in `fpga/as02mc04/docs/`
- This CHANGELOG
- RPC reference: `docs/design/rpc-protocol.md`
- Getting-started: `docs/guides/getting-started.md`
