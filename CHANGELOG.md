# Changelog

All notable changes to PacketWyrm. The project is in active
pre-release development; this file is updated per development
push and is the source of truth for "what's working today".

For where work is going next, see `NEXT-STEPS.md`.

## Unreleased

### Added
  - **Hash exact classifier — high-count payload-agnostic flows**
    (`pw_hash_classifier`; CSR window `PWFPGA_WIN_FC_HASH` @ 0x3000 + seed reg
    `PWFPGA_REG_HASH_SEED`). Classifies a frame by an EXACT match on a multi-field
    HEADER tuple `{l3_dst, l4_dst, l4_src, l3_proto}` (168-bit key), scaling
    payload-agnostic classification to the checker's `NUM_FLOWS` (vs the field
    comparators' ~`NCMP` cap) — and without the test-header `flow_id` the flow-id
    map needs, so the payload stays free. Direct-indexed BRAM hash table (1 read
    + 1 full-key verify, NOT an N-way parallel match, so it routes): the 168-bit
    key XOR-folds to 32 bits, a Dietzfelbinger multiply-shift (with a seed)
    chooses the bucket, and the stored full key is compared for an exact hit
    (the hash only picks the bucket — no misclassification). The compiler routes
    `classify: header` flows to this table and searches a hash **seed** that
    places the configured keys collision-free; the field+UDF classifier then
    carries only punt/forward. Data-plane precedence: flow-id **map > hash
    classifier > field classifier**. Bit-identical HW/SW hash. Completes Phase 5
    of `docs/design/generic-classifier.md`. (`configs/examples/
    phase3-header-classify.yaml` is now a 24-flow header-keyed scale test.)
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
