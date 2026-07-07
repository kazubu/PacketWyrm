// PacketWyrm multi-flow generator -- 64-bit AXIS, N flow slots, one egress
// port. Generalises pw_flow_gen_axis: instead of one hardwired flow, it
// takes an array of decoded flow-window rows (pw_flow_row_t) and generates
// every row whose egress == EGRESS_PORT, each with its own sequence counter
// and Q16.16 token bucket, round-robined onto the single AXIS output. This
// lets one egress port carry several concurrent test flows (the
// single-template pw_flow_gen_axis emitted only one flow_id per port), and
// the emitted flow_id comes from the row config.
//
// Frame layout per flow matches pw_flow_gen_axis exactly: Ethernet [+VLAN]
// / IPv4 / UDP / 32-byte PacketWyrm test header (magic / version / flow_id
// / seq / timestamp). IPv4 header checksums (inner + encap outer) are
// computed here; v6 UDP and TCP carry a partial L4 checksum finalized by
// pw_ts_insert at egress; v4 UDP checksum stays 0 (legal, no fixup path).
//
// Scheduling: a slot is eligible when its row is valid, targets this egress
// port, and its bucket holds at least one frame's cost. A round-robin
// pointer picks the next eligible slot at each frame boundary, so concurrent
// flows share the port fairly; each flow's average rate is set by its bucket.

`default_nettype none

import pw_axis_pkg::*;

module pw_flow_gen_multi #(
    parameter int EGRESS_PORT       = 0,
    parameter int NUM_SLOTS         = 8,
    parameter int FRAME_LEN_PAYLOAD = 32,    // L4 payload bytes (>=32 = test hdr)
    parameter int HDR_MAX_BYTES     = 176   // worst case (v6-outer EtherIP v6-inner +VLAN):
                                            // eth14 + vlan4 + v6_outer40 + etherip2 + inner_eth14
                                            // + v6_inner40 + udp8 + payload32 = 154
) (
    input  wire           clk,
    input  wire           rst_n,

    input  wire [63:0]    timestamp_i,

    // Compact per-slot scheduling descriptors (all slots, every cycle): used
    // for eligibility / round-robin / token buckets. The wide frame-content
    // row is read from BRAM only for the picked slot (rd_addr_o -> rd_row_i,
    // 1-cycle latency). Slots whose egress != EGRESS_PORT are ignored here.
    input  pw_flow_sched_t flow_sched_i [NUM_SLOTS],
    output logic [$clog2(NUM_SLOTS)-1:0] rd_addr_o,
    input  pw_flow_row_t   rd_row_i,

    // Per-slot TX frame counter for true loss (tx - rx). Separate from the
    // on-wire sequence number (which must never be cleared); this one is
    // re-baselined by stats_clear_i alongside the RX checkers.
    input  wire            stats_clear_i,
    output logic [47:0]    tx_count_o [NUM_SLOTS],
    // Per-slot TX byte counter (emitted L2 frame bytes), same clear semantics as
    // tx_count_o. Feeds per-flow tx_bytes so a client can compute tx bps.
    output logic [63:0]    tx_bytes_o [NUM_SLOTS],

    // 64-bit AXIS egress
    output logic [63:0]   m_tdata,
    output logic [7:0]    m_tkeep,
    output logic          m_tvalid,
    input  wire           m_tready,
    output logic          m_tlast,
    // 1 = this frame is a stampable PacketWyrm test frame (TEST template, with
    // the 32-byte test header the egress pw_ts_insert overwrites); 0 = a raw
    // template (L4RAW/L3RAW/L2RAW) with no test header, which pw_ts_insert must
    // leave untouched (no tx_ts overwrite, no L4-csum fixup). Held stable for
    // the whole frame; sampled at SOF downstream.
    output logic          m_tstampable
);
    localparam logic [31:0] PW_TEST_HDR_MAGIC = 32'hA502_7E57;
    localparam int          SELW = $clog2(NUM_SLOTS);

    // Encapsulation header length (bytes added between the outer IP and the
    // inner IP): IPIP=0 (bare inner IP), GRE=4, EtherIP=2 + a 14-byte inner
    // Ethernet header = 16. encap_type: 0 none / 1 ipip / 2 gre / 3 etherip.
    function automatic int encap_hdr_len(input logic [1:0] et);
        case (et)
            2'd2:    return 4;    // GRE: flags/ver(2) + protocol-type(2)
            2'd3:    return 16;   // EtherIP(2) + inner Ethernet header(14)
            default: return 0;    // IPIP / none
        endcase
    endfunction
    // Outer IP protocol number for an encap type carrying an inner v4/v6 IP.
    function automatic logic [7:0] encap_proto(input logic [1:0] et, input logic inner_v6);
        case (et)
            2'd1:    return inner_v6 ? 8'd41 : 8'd4;   // IPIP: 4 (v4-in) / 41 (v6-in)
            2'd2:    return 8'd47;                      // GRE
            2'd3:    return 8'd97;                      // EtherIP
            default: return 8'd17;                      // (unused) UDP
        endcase
    endfunction
    // (The token cost = frame_bytes<<16 is now precomputed in the flow table
    // and delivered via flow_sched_i[].cost, so the generator no longer
    // computes frame_bytes -- only the build-time encap header lengths above.)

    // This slot belongs to this generator's egress port.
    function automatic logic mine(input pw_flow_sched_t s);
        return s.valid && (s.egress == 4'(EGRESS_PORT));
    endfunction

    // Per-slot state.
    logic [63:0] sequence_q [NUM_SLOTS];
    logic [31:0] tokens_q   [NUM_SLOTS];   // Q16.16
    logic [47:0] tx_count   [NUM_SLOTS];   // emitted frames (clearable, for tx-rx loss)
    logic [63:0] tx_bytes_count [NUM_SLOTS]; // emitted L2 bytes (clearable, for tx bps)
    logic [15:0] cur_len    [NUM_SLOTS];   // current swept total frame length (0 -> use min)

    always_comb for (int s = 0; s < NUM_SLOTS; s++) tx_count_o[s] = tx_count[s];
    always_comb for (int s = 0; s < NUM_SLOTS; s++) tx_bytes_o[s] = tx_bytes_count[s];

    // In-flight frame (built from the selected slot at frame start).
    logic [HDR_MAX_BYTES-1:0][7:0] fb;
    logic [11:0]                   frame_len;   // total emitted bytes this frame
    logic [11:0]                   built_len;   // bytes actually laid into fb (header
                                                // + 32B test region); rest is zero pad
    logic [SELW-1:0]               sel;
    logic                          active;
    logic                          frame_stampable; // TEST-template frame in flight
    logic [11:0]                   byte_off;

    // Per-slot eligibility. Registered before the round-robin pick so the
    // long tokens_q -> compare -> priority-select -> tokens_q deduction path
    // is broken (the pick sees last cycle's eligibility). Safe: between
    // frames a slot's bucket only grows, so a 1-cycle-stale "eligible" is
    // still eligible, and a just-emptied slot is `active` (not re-picked)
    // until its frame finishes, by which point eligible_q has caught up.
    // Per-slot quasi-static fields (registered). f_rows_i is written once at
    // config time and then held, so pulling `mine` / token `cost` / bucket
    // `cap` into registers takes frame_bytes()/shifts OUT of both the
    // eligibility compare and the pick->deduct path -- the dominant timing
    // path once NUM_SLOTS grows (32 slots blew 156.25 MHz otherwise).
    logic        mine_q [NUM_SLOTS];
    logic [31:0] cost_q [NUM_SLOTS];
    logic [31:0] cap_q  [NUM_SLOTS];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SLOTS; s++) begin
                mine_q[s] <= 1'b0; cost_q[s] <= '0; cap_q[s] <= '0;
            end
        end else begin
            for (int s = 0; s < NUM_SLOTS; s++) begin
                mine_q[s] <= mine(flow_sched_i[s]);
                cost_q[s] <= flow_sched_i[s].cost;
                cap_q[s]  <= flow_sched_i[s].cap;
            end
        end
    end

    // Eligibility. A slot is eligible when its bucket holds a frame's cost, OR
    // when it is the currently-emitting slot (`active && s==sel`): keeping the
    // active slot "eligible" through its own emit keeps the round-robin pick and
    // the pick->precompute pipeline PRIMED on it, so pick_valid_qq stays high
    // for the whole frame and the next frame can start ~1 cycle after this one
    // ends -- eliminating the per-frame ~5-cycle pipeline-drain bubble that
    // otherwise caps a cap=1 (burst_size:1) small-frame flow below line rate.
    // The speculative term does NOT bypass rate limiting: the real token check
    // moves to the launch decision below (a rate-limited flow waits there). It
    // also does not hurt fairness -- the active slot is the round-robin LAST
    // choice (rr_ptr = sel+1), so any other eligible slot is picked first.
    logic [NUM_SLOTS-1:0] eligible;
    always_comb begin
        for (int s = 0; s < NUM_SLOTS; s++)
            eligible[s] = mine_q[s] && ((tokens_q[s] >= cost_q[s]) ||
                                        (active && (SELW'(s) == sel)));
    end
    logic [NUM_SLOTS-1:0] eligible_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) eligible_q <= '0;
        else        eligible_q <= eligible;
    end

    // Registered per-slot "bucket holds a frame's cost" flag. The launch gate
    // uses tok_ready_q[pick_qq] (a registered lookup) instead of recomputing the
    // token accrue+clamp+compare combinationally -- that arithmetic on the
    // `active`/`byte_off` set path was the dp_clk-critical path. Safe: between
    // frames a slot's bucket only grows, so a 1-cycle-stale "ready" is still
    // ready (and the deduct below re-derives the exact accrued value).
    logic [NUM_SLOTS-1:0] tok_ready_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tok_ready_q <= '0;
        else for (int s = 0; s < NUM_SLOTS; s++)
            tok_ready_q[s] <= (tokens_q[s] >= cost_q[s]);
    end

    // Round-robin pick: earliest eligible slot at/after rr_ptr (wrapping).
    logic [SELW-1:0] rr_ptr;
    logic [SELW-1:0] pick;
    logic            pick_valid;
    always_comb begin
        pick       = '0;
        pick_valid = 1'b0;
        for (int i = NUM_SLOTS - 1; i >= 0; i--) begin
            automatic int idx = (int'(rr_ptr) + i) % NUM_SLOTS;
            if (eligible_q[idx]) begin
                pick       = SELW'(idx);
                pick_valid = 1'b1;
            end
        end
    end

    // Register the round-robin pick so the priority select (over NUM_SLOTS)
    // and the pick-indexed wide row mux + token arithmetic land in separate
    // pipeline stages. Safe for the same reason eligible_q is registered:
    // rr_ptr is stable while a frame is active and a picked slot stays
    // eligible (its bucket only grows) until its frame starts, so a
    // 1-cycle-stale pick selects the same slot it would have anyway.
    logic [SELW-1:0] pick_q;
    logic            pick_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pick_q       <= '0;
            pick_valid_q <= 1'b0;
        end else begin
            pick_q       <= pick;
            pick_valid_q <= pick_valid;
        end
    end

    wire start = !active && pick_valid_qq;

    wire [11:0] rem  = frame_len - byte_off;
    wire        last = active && (rem <= 12'd8);

    // Emit fb for the built header region, zeros for the pad beyond it (a long
    // frame's payload pad is generated on the fly -- fb only holds the header,
    // so the index is masked to the buffer size and guarded by built_len to
    // never read past it). tkeep runs out to the total frame_len.
    always_comb begin
        m_tdata = '0;
        m_tkeep = '0;
        for (int k = 0; k < 8; k++) begin
            automatic logic [11:0] gb = byte_off + k[11:0];
            if (gb < frame_len) begin
                m_tkeep[k]        = 1'b1;
                m_tdata[k*8 +: 8] = (gb < built_len) ? fb[gb[$clog2(HDR_MAX_BYTES)-1:0]]
                                                     : 8'h00;
            end
        end
    end
    assign m_tvalid = active;
    assign m_tlast  = last;
    assign m_tstampable = frame_stampable;

    // --- field modifiers + IP checksum -------------------------------------
    // xorshift32 scramble for the "random" modifier mode (combinational).
    function automatic logic [31:0] scramble(input logic [31:0] x);
        logic [31:0] v;
        v = x ^ (x << 13);
        v = v ^ (v >> 17);
        v = v ^ (v << 5);
        return v;
    endfunction
    // Apply a field modifier: static -> base; increment -> seq in the masked
    // bits; random -> scrambled seq in the masked bits. Unmasked bits keep
    // the base value, so e.g. mask=0x000003FF rotates the low 10 bits (1024
    // apparent flows) while the rest of the address stays put.
    function automatic logic [31:0] mod32(input logic [1:0] mode, input logic [31:0] base,
                                          input logic [31:0] mask, input logic [63:0] seq);
        logic [31:0] rot;
        rot = (mode == 2'd2) ? scramble(seq[31:0]) : seq[31:0];
        return (mode == 2'd0) ? base : ((base & ~mask) | (rot & mask));
    endfunction
    function automatic logic [15:0] mod16(input logic [1:0] mode, input logic [15:0] base,
                                          input logic [15:0] mask, input logic [63:0] seq);
        logic [15:0] rot;
        rot = (mode == 2'd2) ? scramble(seq[31:0])>>3 : seq[15:0];
        return (mode == 2'd0) ? base : ((base & ~mask) | (rot & mask));
    endfunction
    // 48-bit field modifier for the MAC addresses (random uses two scrambled
    // seq halves to fill 48 bits).
    function automatic logic [47:0] mod48(input logic [1:0] mode, input logic [47:0] base,
                                          input logic [47:0] mask, input logic [63:0] seq);
        logic [47:0] rot;
        logic [63:0] rnd;
        rnd = {scramble(seq[63:32]), scramble(seq[31:0])};
        rot = (mode == 2'd2) ? rnd[47:0] : seq[47:0];
        return (mode == 2'd0) ? base : ((base & ~mask) | (rot & mask));
    endfunction
    // Full 128-bit IPv6 address modifier. Each 32-bit lane is rotated
    // independently with a fixed per-lane salt (random) / offset (increment) so
    // a full-mask rotation does NOT emit four identical words; field_salt
    // (distinct for src vs dst) decorrelates the two addresses. Lane 0 ([31:0])
    // uses salt/offset 0, so a low-32-only mask reproduces the original v6
    // host-ID rotation exactly (back-compat). These are field+lane-SALTED
    // deterministic streams (xorshift is linear, so they are de-duplicated, not
    // statistically independent). The salts are FIXED RTL spec (golden-tested).
    function automatic logic [127:0] mod128(input logic [1:0] mode, input logic [127:0] base,
                                            input logic [127:0] mask, input logic [63:0] seq,
                                            input logic [31:0] field_salt);
        logic [127:0] r;
        logic [31:0]  lsalt [4];
        logic [31:0]  loff  [4];
        lsalt[0] = 32'h0000_0000; loff[0] = 32'h0000_0000;   // low lane: unchanged
        lsalt[1] = 32'h9E37_79B1; loff[1] = 32'h1000_0000;
        lsalt[2] = 32'h85EB_CA77; loff[2] = 32'h2000_0000;
        lsalt[3] = 32'hC2B2_AE3D; loff[3] = 32'h3000_0000;
        for (int l = 0; l < 4; l++) begin
            logic [31:0] rot;
            rot = (mode == 2'd2) ? scramble(seq[31:0] ^ field_salt ^ lsalt[l])
                                 : (seq[31:0] + loff[l]);
            r[l*32 +: 32] = (mode == 2'd0) ? base[l*32 +: 32]
                          : ((base[l*32 +: 32] & ~mask[l*32 +: 32]) | (rot & mask[l*32 +: 32]));
        end
        return r;
    endfunction
    // Field salts: src=0 preserves the original v6-low random stream exactly;
    // dst is distinct so src and dst don't emit identical rotated values.
    localparam logic [31:0] SALT_SIP = 32'h0000_0000;
    localparam logic [31:0] SALT_DIP = 32'h5A5A_5A5A;
    // IPv4 header checksum over the (mostly constant) header with the
    // effective src/dst addresses, the DSCP (TOS byte) and the TTL.
    // Constants: ver/ihl=0x45, flags/frag=0x4000, proto=0x11 (UDP); id and
    // csum contribute 0. tos = {dscp[5:0],2'b00} (6-bit DSCP, ECN=0).
    function automatic logic [15:0] ip_csum16(input logic [15:0] tot,
                                              input logic [31:0] sip, input logic [31:0] dip,
                                              input logic [7:0]  dscp, input logic [7:0] ttl,
                                              input logic [7:0]  proto);
        logic [31:0] s;
        s = {16'b0, 8'h45, dscp[5:0], 2'b00}     // ver/ihl | TOS
          + {16'b0, tot} + 32'h4000              // total length | flags/frag
          + {16'b0, ttl, proto}                  // TTL | proto (UDP 17 / TCP 6)
          + {16'b0, sip[31:16]} + {16'b0, sip[15:0]}
          + {16'b0, dip[31:16]} + {16'b0, dip[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        return ~s[15:0];
    endfunction
    // Outer IPv4 header checksum for an encap tunnel: same as ip_csum16 but the
    // protocol byte is the tunnel proto (4/41/47/97), not UDP. The outer header
    // carries fixed (non-modified) outer addresses, so this is pick-stable.
    function automatic logic [15:0] ip_csum16_o(input logic [15:0] tot,
                                                input logic [31:0] sip, input logic [31:0] dip,
                                                input logic [7:0]  dscp, input logic [7:0] ttl,
                                                input logic [7:0]  proto);
        logic [31:0] s;
        s = {16'b0, 8'h45, dscp[5:0], 2'b00}
          + {16'b0, tot} + 32'h4000
          + {16'b0, ttl, proto}
          + {16'b0, sip[31:16]} + {16'b0, sip[15:0]}
          + {16'b0, dip[31:16]} + {16'b0, dip[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        return ~s[15:0];
    endfunction

    // Generalized L4 (UDP/TCP, IPv4/IPv6) *partial* checksum -- the 8-byte
    // tx_timestamp is deliberately EXCLUDED (pw_ts_insert folds the departure
    // stamp in at egress, producing the final valid checksum in one pass: the
    // csum field leaves the MAC before the tx_ts field, so the stamper only
    // *adds* the SOF-latched ts, never subtracts an old one). Emits the raw
    // one's-complement (~s, no 0xFFFF rule) so ~csum == partial exactly.
    //
    // Applies to {v6 UDP, v4 TCP, v6 TCP}; v4 UDP keeps csum 0 (build() decides).
    // Split into two registered half-sums (the proven dp_clk timing structure):
    //   psum_a = pseudo-header address sum (v6: 16 words; v4: 4 words).
    //   psum_b = pseudo (proto + L4 length) + L4 header (proto-specific, csum=0)
    //            + the 24-byte non-timestamp test region (magic / ver / flow_id /
    //            seq -- NOT tx_ts).
    // Accumulators are 24-bit: psum_b's TCP term count (~17 words) exceeds the
    // old 20-bit width, so size for the max (<= 0x15FFEA) with margin.
    function automatic logic [23:0] l4_psum_a(input logic is_v6,
                                              input logic [31:0] sip, input logic [31:0] dip,
                                              input logic [127:0] v6src, input logic [127:0] v6dst);
        logic [23:0] s; s = '0;
        if (is_v6) begin
            for (int w = 0; w < 8; w++) s += {8'b0, v6src[w*16 +: 16]};
            for (int w = 0; w < 8; w++) s += {8'b0, v6dst[w*16 +: 16]};
        end else begin
            s = {8'b0, sip[31:16]} + {8'b0, sip[15:0]}
              + {8'b0, dip[31:16]} + {8'b0, dip[15:0]};
        end
        return s;
    endfunction
    function automatic logic [23:0] l4_psum_b(input logic is_tcp,
                                              input logic [15:0] sport, input logic [15:0] dport,
                                              input logic [15:0] l4_len, input logic [31:0] flow_id,
                                              input logic [63:0] seq, input logic [7:0] tcp_flags,
                                              input logic add_test);
        logic [23:0] s;
        s = {8'b0, l4_len} + (is_tcp ? 24'd6 : 24'd17)     // pseudo-hdr: L4 len + proto
          + {8'b0, sport} + {8'b0, dport};                 // L4 src/dst port
        if (is_tcp)
            // TCP header (csum=0): seq = test-seq low-32, data-offset 5 | flags,
            // window 0xFFFF. ack=0 / urgent=0 contribute nothing.
            s += {8'b0, seq[31:16]} + {8'b0, seq[15:0]}
               + {8'b0, (16'h5000 | {8'h00, tcp_flags})}
               + 24'h00_FFFF;
        else
            s += {8'b0, l4_len};                           // UDP length (csum=0)
        // 24-byte non-timestamp test region (excl tx_ts). Omitted for L4RAW
        // (add_test=0): a raw payload carries no test header, and the emitted
        // payload is all zeros -- so nothing beyond the L4 header contributes.
        if (add_test)
            s += {8'b0, PW_TEST_HDR_MAGIC[31:16]} + {8'b0, PW_TEST_HDR_MAGIC[15:0]}
               + 24'h00_0001                               // version 0x0001, reserved 0
               + {8'b0, flow_id[31:16]} + {8'b0, flow_id[15:0]}
               + {8'b0, seq[63:48]} + {8'b0, seq[47:32]} + {8'b0, seq[31:16]} + {8'b0, seq[15:0]};
        return s;
    endfunction
    // Combine the two registered half-sums -> raw one's-complement partial.
    function automatic logic [15:0] l4_fold(input logic [23:0] psa, input logic [23:0] psb);
        logic [24:0] s;
        s = {1'b0, psa} + {1'b0, psb};
        s = {9'b0, s[15:0]} + {16'b0, s[24:16]};
        s = {9'b0, s[15:0]} + {16'b0, s[24:16]};
        return ~s[15:0];
    endfunction

    // --- precompute pipeline (two stages after the registered pick_q) -------
    // The effective (modifier-applied) header fields + checksums depend only on
    // the picked row and its sequence number -- both pick-stable -- so they are
    // precomputed off pick_q (NOT the combinational `pick`: that would chain
    // the 32-way priority encoder into the checksum adders). The path is split
    // into two register stages because, fused, it was the dp_clk-critical path:
    //
    //   Stage A (row fetch): the picked slot's wide row comes from the flow-
    //   table BRAM. rd_addr_o = pick_q drives the read; rd_row_i is the BRAM's
    //   registered output (1-cycle latency, like the old f_rows_i[pick_q]
    //   register mux), so row_l = rd_row_i is already isolated by the BRAM's
    //   output register and aligns with the pick_l / seq_l registers below.
    //
    //   Stage B (checksum): mod32/scramble + the IPv4/IPv6 checksum adders read
    //   the BRAM output row_l.
    //
    // build() then consumes the stage-B registers and only lays out bytes. (B
    // excludes the live tx_timestamp from udp6_csum -- that is what makes the
    // whole checksum pick-stable and thus precomputable here.)
    assign rd_addr_o = pick_q;             // flow-table BRAM read address
    logic [SELW-1:0]  pick_l;
    logic             pvalid_l;
    pw_flow_row_t     row_l;               // = rd_row_i (BRAM output); set in the
                                           // precompute always_comb below.
    logic [63:0]      seq_l;
    logic [15:0]      eff_len_l;           // swept total frame length for this frame
    logic [11:0]      paylen_l;            // L4 payload bytes for this frame (>=32)

    // Effective frame length + L4 payload for the slot being fetched (pick_q):
    // the slot's current sweep position, snapped to len_min on the first frame
    // (cur_len 0) or if it ever falls outside [min,max]. min/max/ovh come from
    // the scheduling descriptor (FF), so this adds no BRAM-latency dependency.
    // Computed here (stage A, otherwise near-empty) rather than in the checksum
    // precompute (stage B) so the dp_clk-critical csum adders see a *registered*
    // length input, not this subtract.
    logic [15:0] sl_min_pk, sl_max_pk, cur_pk, eff_len_a;
    logic [11:0] ovh_pk, paylen_a, floor_pk;
    always_comb begin
        sl_min_pk = flow_sched_i[pick_q].len_min;
        sl_max_pk = flow_sched_i[pick_q].len_max;
        ovh_pk    = flow_sched_i[pick_q].ovh;
        cur_pk    = cur_len[pick_q];
        eff_len_a = (cur_pk < sl_min_pk || cur_pk > sl_max_pk) ? sl_min_pk : cur_pk;
        // Payload = total - header overhead. TEST reserves a 32-byte test-header
        // region as the payload floor; raw templates (L4RAW/L3RAW/L2RAW) carry no
        // test header, so their floor is 0 (enabling a true 64-byte frame). ovh
        // is already template-aware (pw_frame_bytes in the sched descriptor).
        floor_pk  = (flow_sched_i[pick_q].frame_template == 2'd0) ? 12'd32 : 12'd0;
        paylen_a  = (eff_len_a > {4'b0, ovh_pk} + {4'b0, floor_pk})
                    ? 12'(eff_len_a - {4'b0, ovh_pk}) : floor_pk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pick_l <= '0; pvalid_l <= 1'b0; seq_l <= '0; eff_len_l <= '0; paylen_l <= 12'd32;
        end else begin
            pick_l    <= pick_q;
            pvalid_l  <= pick_valid_q;
            seq_l     <= sequence_q[pick_q];
            eff_len_l <= eff_len_a;
            paylen_l  <= paylen_a;
        end
    end

    logic [31:0]  pc_sip, pc_dip;
    logic [127:0] pc_v6src, pc_v6dst;
    logic [47:0]  pc_smac, pc_dmac;
    logic [11:0]  pc_vlan;
    logic [15:0]  pc_sp, pc_dp, pc_csum, pc_ocsum;
    logic [23:0]  pc_psa, pc_psb;       // L4 csum half-sums (folded in build)
    logic [15:0]  l4hl_pk;              // L4 header length (UDP 8 / TCP 20)
    logic [7:0]   l4proto_pk;           // normalized L4 proto (17 UDP / 6 TCP)
    always_comb begin
        logic [15:0] vlan16;
        logic [15:0] outer_tot;
        logic [15:0] ip_tot_pk;
        row_l    = rd_row_i;       // picked row from the flow-table BRAM (Stage A)
        // L4 payload (paylen_l) is computed + registered in stage A. The pad
        // beyond the 32-byte test header is zero, so it adds nothing to the UDP
        // checksum -- only these length fields change.
        pc_sip   = mod32(row_l.sip_mod, row_l.src_ipv4, row_l.sip_mask, seq_l);
        pc_dip   = mod32(row_l.dip_mod, row_l.dst_ipv4, row_l.dip_mask, seq_l);
        // MAC / VLAN modifiers (Ethernet header only; not in any checksum).
        pc_smac  = mod48(row_l.smac_mod, row_l.src_mac, row_l.smac_mask, seq_l);
        pc_dmac  = mod48(row_l.dmac_mod, row_l.dst_mac, row_l.dmac_mask, seq_l);
        // (Vivado synth rejects slicing a function-call result directly, so
        // assign to a temp first.)
        vlan16   = mod16(row_l.vlan_mod, {4'b0, row_l.vlan_id}, row_l.vlan_mask, seq_l);
        pc_vlan  = vlan16[11:0];
        // IPv6 address modifiers: full 128-bit rotation. The mask is
        // {*_mask_hi[127:32], *_mask[31:0]}; a low-32-only mask reproduces the
        // original host-ID rotation. The udp6 partial checksum sums the full
        // modified address, so no extra checksum work is needed here.
        pc_v6src = mod128(row_l.sip_mod, row_l.ipv6_src,
                          {row_l.sip_mask_hi, row_l.sip_mask}, seq_l, SALT_SIP);
        pc_v6dst = mod128(row_l.dip_mod, row_l.ipv6_dst,
                          {row_l.dip_mask_hi, row_l.dip_mask}, seq_l, SALT_DIP);
        pc_sp    = mod16(row_l.sp_mod,  row_l.udp_sp,   row_l.sp_mask,  seq_l);
        pc_dp    = mod16(row_l.dp_mod,  row_l.udp_dp,   row_l.dp_mask,  seq_l);
        // L4 header length (UDP 8 / TCP 20) threads into the IPv4 total-length,
        // the IPv4-header proto byte, and the L4 checksum's pseudo-header length.
        // Normalize proto here too (6 -> TCP, else UDP) so the csum matches the
        // emitted proto byte even if the row wasn't decode-normalized.
        l4proto_pk = (row_l.l4_proto == 8'd6) ? 8'd6 : 8'd17;
        l4hl_pk    = (l4proto_pk == 8'd6) ? 16'd20 : 16'd8;
        // Inner IPv4 total length: L3RAW (template 2) carries only the raw
        // payload after the 20-byte IP header (no L4); TEST/L4RAW include the
        // L4 header. (L2RAW has no IP header, so this csum is unused.)
        ip_tot_pk = (row_l.frame_template == 2'd2)
                    ? 16'(20 + int'(paylen_l))
                    : 16'(20 + int'(l4hl_pk) + int'(paylen_l));
        pc_csum  = ip_csum16(ip_tot_pk, pc_sip, pc_dip,
                             row_l.dscp, row_l.ttl, l4proto_pk);
        pc_psa   = l4_psum_a(row_l.is_v6, pc_sip, pc_dip, pc_v6src, pc_v6dst);
        // The L4 partial checksum includes the test-header region only for TEST;
        // raw templates carry a zero payload (adds nothing). L4 csum is only
        // emitted for TEST/L4RAW anyway (build() decides).
        pc_psb   = l4_psum_b(l4proto_pk == 8'd6, pc_sp, pc_dp,
                             16'(int'(l4hl_pk) + int'(paylen_l)), row_l.flow_id,
                             seq_l, row_l.tcp_flags, row_l.frame_template == 2'd0);
        // Outer IPv4 header checksum (encap with a v4 outer). tot_len = outer
        // header(20) + encap header + inner IP packet. Static outer addresses.
        outer_tot = 16'(20 + encap_hdr_len(row_l.encap_type)
                        + (row_l.is_v6 ? 40 : 20) + int'(l4hl_pk) + int'(paylen_l));
        pc_ocsum = ip_csum16_o(outer_tot, row_l.outer_src_ipv4, row_l.outer_dst_ipv4,
                               row_l.outer_dscp, row_l.outer_ttl,
                               encap_proto(row_l.encap_type, row_l.is_v6));
    end

    // Stage B latch (consumed by build): picked row + seq + precomputed fields.
    logic [SELW-1:0]  pick_qq;
    logic             pick_valid_qq;
    pw_flow_row_t     row_qq;
    logic [63:0]      seq_qq;
    logic [31:0]      eff_sip_q, eff_dip_q;
    logic [127:0]     eff_v6src_q, eff_v6dst_q;
    logic [47:0]      eff_smac_q, eff_dmac_q;
    logic [11:0]      eff_vlan_q;
    logic [15:0]      eff_sp_q, eff_dp_q, csum_q, ocsum_q;
    logic [23:0]      psa_q, psb_q;       // L4 csum half-sums; folded in build()
    logic [11:0]      paylen_q;           // L4 payload bytes (>=32) for this frame
    logic [15:0]      eff_len_qq;         // total frame length used (drives sweep advance)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pick_qq <= '0; pick_valid_qq <= 1'b0; row_qq <= '0; seq_qq <= '0;
            eff_sip_q <= '0; eff_dip_q <= '0; eff_sp_q <= '0; eff_dp_q <= '0;
            eff_v6src_q <= '0; eff_v6dst_q <= '0;
            eff_smac_q <= '0; eff_dmac_q <= '0; eff_vlan_q <= '0;
            csum_q    <= '0; ocsum_q <= '0; psa_q <= '0; psb_q <= '0;
            paylen_q  <= 12'd32; eff_len_qq <= '0;
        end else begin
            pick_qq       <= pick_l;
            pick_valid_qq <= pvalid_l;
            row_qq        <= row_l;
            seq_qq        <= seq_l;
            eff_smac_q <= pc_smac; eff_dmac_q <= pc_dmac; eff_vlan_q <= pc_vlan;
            eff_sip_q <= pc_sip;  eff_dip_q <= pc_dip;
            eff_v6src_q <= pc_v6src; eff_v6dst_q <= pc_v6dst;
            eff_sp_q  <= pc_sp;   eff_dp_q  <= pc_dp;
            csum_q    <= pc_csum; ocsum_q <= pc_ocsum; psa_q <= pc_psa; psb_q <= pc_psb;
            paylen_q  <= paylen_l; eff_len_qq <= eff_len_l;
        end
    end

    // Build a slot's frame into fb at frame start. The effective header fields
    // and checksums are supplied precomputed (eff_* / csum / ucsum, registered
    // and aligned with the picked row); build() only lays out bytes.
    task automatic build(input pw_flow_row_t r, input logic [63:0] seq, input logic [63:0] ts,
                         input logic [31:0] eff_sip, input logic [31:0] eff_dip,
                         input logic [127:0] eff_v6src, input logic [127:0] eff_v6dst,
                         input logic [47:0] eff_smac, input logic [47:0] eff_dmac,
                         input logic [11:0] eff_vlan,
                         input logic [15:0] eff_sp,  input logic [15:0] eff_dp,
                         input logic [15:0] csum,    input logic [15:0] ocsum,
                         input logic [23:0] psa,     input logic [23:0] psb,
                         input logic [11:0] pay_len);
        int off, tl, total_len, o_pl, o_tot, l4hl, ip_pl;
        logic [7:0]  tos, o_tos, o_proto, l4proto;
        logic        is_tcp;
        logic [1:0]  tmpl;
        logic [15:0] ucsum, inner_et, et2, et_out;
        tmpl    = r.frame_template;
        is_tcp  = (r.l4_proto == 8'd6);
        l4hl    = is_tcp ? 20 : 8;         // L4 header length
        l4proto = is_tcp ? 8'd6 : 8'd17;
        tos   = {r.dscp[5:0], 2'b00};      // IPv4 TOS / IPv6 TC byte (DSCP<<2, ECN 0)
        // Combine the two registered L4-csum half-sums (cheap; the deep adder is
        // upstream, split across the precompute stages).
        ucsum = l4_fold(psa, psb);
        inner_et = r.is_v6 ? 16'h86DD : 16'h0800;
        // L2RAW ethertype: configured override, else the IP-family default.
        et2      = (r.l2_ethertype != 16'd0) ? r.l2_ethertype : inner_et;
        for (int i = 0; i < HDR_MAX_BYTES; i++) fb[i] <= 8'h00;
        // Outer Ethernet (carries the flow's configured MAC/VLAN regardless of
        // encapsulation; for EtherIP the inner Ethernet reuses the same MACs).
        fb[0]<=eff_dmac[47:40]; fb[1]<=eff_dmac[39:32]; fb[2]<=eff_dmac[31:24];
        fb[3]<=eff_dmac[23:16]; fb[4]<=eff_dmac[15:8];  fb[5]<=eff_dmac[7:0];
        fb[6]<=eff_smac[47:40]; fb[7]<=eff_smac[39:32]; fb[8]<=eff_smac[31:24];
        fb[9]<=eff_smac[23:16]; fb[10]<=eff_smac[15:8]; fb[11]<=eff_smac[7:0];
        off = 12;
        if (r.vlan_en) begin
            fb[off]<=8'h81; fb[off+1]<=8'h00;
            fb[off+2]<={4'h0,eff_vlan[11:8]}; fb[off+3]<=eff_vlan[7:0];
            off += 4;
        end

        // Length setup shared by all IP-bearing templates. tl = inner L4 length
        // (UDP len / TCP seg); ip_pl = the IP-carried payload length, which for
        // L3RAW (no L4 header) is just the raw payload. Raw templates carry a
        // ZERO payload (fb holds only the header region; the emit FSM streams
        // zeros beyond built_len), so an RX header-classifier reads zeros for any
        // L3/L4 it parses -- coherent with the compiler hash key. No encap for
        // raw templates (validator-enforced), so the encap prefix below is only
        // reached by TEST/L4RAW.
        tl    = l4hl + int'(pay_len);
        ip_pl = (tmpl == 2'd2) ? int'(pay_len) : tl;   // L3RAW: no L4

        // --- Encapsulation prefix: outer IP + tunnel header ----------------
        if (r.encap_type != 2'd0) begin
            o_proto = encap_proto(r.encap_type, r.is_v6);
            o_tos   = {r.outer_dscp[5:0], 2'b00};
            // Outer IP payload = tunnel header + inner IP packet.
            o_pl    = encap_hdr_len(r.encap_type) + (r.is_v6 ? 40 : 20) + l4hl + int'(pay_len);
            if (r.outer_v6) begin
                fb[off]<=8'h86; fb[off+1]<=8'hDD; off += 2;    // ethertype IPv6 (outer)
                fb[off+0]<={4'h6, o_tos[7:4]}; fb[off+1]<={o_tos[3:0], 4'h0};
                fb[off+2]<=8'h00; fb[off+3]<=8'h00;            // flow label = 0
                fb[off+4]<=o_pl[15:8]; fb[off+5]<=o_pl[7:0];   // payload length
                fb[off+6]<=o_proto; fb[off+7]<=r.outer_ttl;    // next-header = tunnel proto
                for (int b = 0; b < 16; b++) fb[off+8+b]  <= r.outer_ipv6_src[127 - b*8 -: 8];
                for (int b = 0; b < 16; b++) fb[off+24+b] <= r.outer_ipv6_dst[127 - b*8 -: 8];
                off += 40;
            end else begin
                fb[off]<=8'h08; fb[off+1]<=8'h00; off += 2;    // ethertype IPv4 (outer)
                o_tot = 20 + o_pl;
                fb[off+0]<=8'h45; fb[off+1]<=o_tos;
                fb[off+2]<=o_tot[15:8]; fb[off+3]<=o_tot[7:0];
                fb[off+4]<=8'h00; fb[off+5]<=8'h00; fb[off+6]<=8'h40; fb[off+7]<=8'h00;
                fb[off+8]<=r.outer_ttl; fb[off+9]<=o_proto;
                fb[off+10]<=ocsum[15:8]; fb[off+11]<=ocsum[7:0];
                fb[off+12]<=r.outer_src_ipv4[31:24]; fb[off+13]<=r.outer_src_ipv4[23:16];
                fb[off+14]<=r.outer_src_ipv4[15:8];  fb[off+15]<=r.outer_src_ipv4[7:0];
                fb[off+16]<=r.outer_dst_ipv4[31:24]; fb[off+17]<=r.outer_dst_ipv4[23:16];
                fb[off+18]<=r.outer_dst_ipv4[15:8];  fb[off+19]<=r.outer_dst_ipv4[7:0];
                off += 20;
            end
            // Tunnel header.
            if (r.encap_type == 2'd2) begin                    // GRE: 4 bytes
                fb[off]<=8'h00; fb[off+1]<=8'h00;              // flags + version 0
                fb[off+2]<=inner_et[15:8]; fb[off+3]<=inner_et[7:0];  // protocol-type
                off += 4;
            end else if (r.encap_type == 2'd3) begin           // EtherIP + inner Ethernet
                fb[off]<=8'h30; fb[off+1]<=8'h00; off += 2;    // EtherIP version 3
                // Inner Ethernet uses the row's dedicated inner MAC (the
                // compiler fills it from encap.inner_l2, or the flow MAC).
                fb[off+0]<=r.inner_dst_mac[47:40]; fb[off+1]<=r.inner_dst_mac[39:32]; fb[off+2]<=r.inner_dst_mac[31:24];
                fb[off+3]<=r.inner_dst_mac[23:16]; fb[off+4]<=r.inner_dst_mac[15:8];  fb[off+5]<=r.inner_dst_mac[7:0];
                fb[off+6]<=r.inner_src_mac[47:40]; fb[off+7]<=r.inner_src_mac[39:32]; fb[off+8]<=r.inner_src_mac[31:24];
                fb[off+9]<=r.inner_src_mac[23:16]; fb[off+10]<=r.inner_src_mac[15:8]; fb[off+11]<=r.inner_src_mac[7:0];
                fb[off+12]<=inner_et[15:8]; fb[off+13]<=inner_et[7:0];
                off += 14;
            end
            // IPIP (1): bare inner IP follows directly (no inner ethertype).
        end else begin
            // No encap: the (inner IP or raw-L2) ethertype goes on the Ethernet.
            // L2RAW may override it (et2); all other templates use the IP family.
            et_out = (tmpl == 2'd3) ? et2 : inner_et;
            fb[off]<=et_out[15:8]; fb[off+1]<=et_out[7:0]; off += 2;
        end

        // L2RAW: raw Ethernet frame -- no L3/L4/test header. Done.
        if (tmpl == 2'd3) begin
            frame_len <= 12'(off + int'(pay_len));
            built_len <= 12'(off);
            return;
        end

        // --- Inner IP header (no ethertype: emitted above where needed) ----
        if (r.is_v6) begin
            // 40-byte IPv6 header. TC (8b) spans byte0[3:0] + byte1[7:4];
            // flow label 0. tc = tos = dscp<<2.
            fb[off+0]<={4'h6, tos[7:4]}; fb[off+1]<={tos[3:0], 4'h0};
            fb[off+2]<=8'h00; fb[off+3]<=8'h00;                // flow label = 0
            fb[off+4]<=ip_pl[15:8]; fb[off+5]<=ip_pl[7:0];     // payload length (L3RAW: raw only)
            fb[off+6]<=l4proto; fb[off+7]<=r.ttl;              // next-header (UDP/TCP), hop limit
            for (int b = 0; b < 16; b++) fb[off+8+b]  <= eff_v6src[127 - b*8 -: 8];
            for (int b = 0; b < 16; b++) fb[off+24+b] <= eff_v6dst[127 - b*8 -: 8];
            off += 40;
        end else begin
            total_len = 20 + ip_pl;                            // L3RAW: 20 + raw payload
            fb[off+0]<=8'h45; fb[off+1]<=tos;                  // ver/ihl | TOS (DSCP)
            fb[off+2]<=total_len[15:8]; fb[off+3]<=total_len[7:0];
            fb[off+4]<=8'h00; fb[off+5]<=8'h00; fb[off+6]<=8'h40; fb[off+7]<=8'h00;
            fb[off+8]<=r.ttl; fb[off+9]<=l4proto; fb[off+10]<=csum[15:8]; fb[off+11]<=csum[7:0];  // TTL | proto
            fb[off+12]<=eff_sip[31:24]; fb[off+13]<=eff_sip[23:16];
            fb[off+14]<=eff_sip[15:8];  fb[off+15]<=eff_sip[7:0];
            fb[off+16]<=eff_dip[31:24]; fb[off+17]<=eff_dip[23:16];
            fb[off+18]<=eff_dip[15:8];  fb[off+19]<=eff_dip[7:0];
            off += 20;
        end

        // L3RAW: Ethernet + IP + raw payload -- no L4, no test header. Done.
        if (tmpl == 2'd2) begin
            frame_len <= 12'(off + int'(pay_len));
            built_len <= 12'(off);
            return;
        end

        // L4 header. UDP (8 B): sport/dport/len/csum. TCP (20 B): sport/dport/
        // seq/ack/(data-offset|flags)/window/csum/urgent. The L4 csum field
        // carries the partial (ucsum) for {v6 UDP, v4 TCP, v6 TCP}; v4 UDP leaves
        // it 0. pw_ts_insert folds the departure tx_ts into it at egress.
        fb[off+0]<=eff_sp[15:8]; fb[off+1]<=eff_sp[7:0];
        fb[off+2]<=eff_dp[15:8]; fb[off+3]<=eff_dp[7:0];
        if (is_tcp) begin
            fb[off+4]<=seq[31:24]; fb[off+5]<=seq[23:16];      // seq = test-seq low-32
            fb[off+6]<=seq[15:8];  fb[off+7]<=seq[7:0];
            fb[off+8]<=8'h00; fb[off+9]<=8'h00; fb[off+10]<=8'h00; fb[off+11]<=8'h00; // ack=0
            fb[off+12]<=8'h50; fb[off+13]<=r.tcp_flags;        // data offset 5 (<<4) | flags
            fb[off+14]<=8'hFF; fb[off+15]<=8'hFF;              // window 0xFFFF
            fb[off+16]<=ucsum[15:8]; fb[off+17]<=ucsum[7:0];   // checksum (partial)
            fb[off+18]<=8'h00; fb[off+19]<=8'h00;              // urgent pointer 0
        end else begin
            fb[off+4]<=tl[15:8]; fb[off+5]<=tl[7:0];           // UDP length
            if (r.is_v6) begin fb[off+6]<=ucsum[15:8]; fb[off+7]<=ucsum[7:0]; end
            else          begin fb[off+6]<=8'h00;       fb[off+7]<=8'h00;       end
        end
        off += l4hl;
        // TEST template: write the 32-byte PacketWyrm test header (magic / ver /
        // flow_id / seq / ts). L4RAW carries full L2/L3/L4 headers but a raw
        // (zero) payload -- no test header -- so a true 64-byte frame is possible.
        if (tmpl == 2'd0) begin
            fb[off+0]<=PW_TEST_HDR_MAGIC[31:24]; fb[off+1]<=PW_TEST_HDR_MAGIC[23:16];
            fb[off+2]<=PW_TEST_HDR_MAGIC[15:8];  fb[off+3]<=PW_TEST_HDR_MAGIC[7:0];
            fb[off+4]<=8'h00; fb[off+5]<=8'h01; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
            fb[off+8]<=r.flow_id[31:24]; fb[off+9]<=r.flow_id[23:16];
            fb[off+10]<=r.flow_id[15:8]; fb[off+11]<=r.flow_id[7:0];
            fb[off+12]<=seq[63:56]; fb[off+13]<=seq[55:48]; fb[off+14]<=seq[47:40]; fb[off+15]<=seq[39:32];
            fb[off+16]<=seq[31:24]; fb[off+17]<=seq[23:16]; fb[off+18]<=seq[15:8];  fb[off+19]<=seq[7:0];
            fb[off+20]<=ts[63:56]; fb[off+21]<=ts[55:48]; fb[off+22]<=ts[47:40]; fb[off+23]<=ts[39:32];
            fb[off+24]<=ts[31:24]; fb[off+25]<=ts[23:16]; fb[off+26]<=ts[15:8];  fb[off+27]<=ts[7:0];
            built_len <= 12'(off + 32);    // header + 32-byte test-header region
        end else begin
            built_len <= 12'(off);         // L4RAW: headers only, raw zero payload
        end
        // off now points at the inner test-header/payload (the UDP block above
        // already advanced it past the 8-byte UDP header); total = + payload.
        // This covers all encap layouts (outer IP + tunnel header already added).
        // The emit FSM streams zero pad from built_len up to frame_len, so fb
        // never needs to hold the (up to 1518 B) payload.
        frame_len <= 12'(off + int'(pay_len));
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active   <= 1'b0;
            frame_stampable <= 1'b0;
            byte_off <= '0;
            rr_ptr   <= '0;
            sel      <= '0;
            for (int s = 0; s < NUM_SLOTS; s++) begin
                sequence_q[s] <= '0;
                tokens_q[s]   <= '0;
                tx_count[s]   <= '0;
                tx_bytes_count[s] <= '0;
                cur_len[s]    <= '0;
            end
        end else begin
            // Re-baseline the TX frame counters on a stats clear (the on-wire
            // sequence_q is NOT cleared -- that would break RX sequence tracking).
            if (stats_clear_i)
                for (int s = 0; s < NUM_SLOTS; s++) begin
                    tx_count[s]       <= '0;
                    tx_bytes_count[s] <= '0;
                end
            // Token buckets: accumulate per active slot, clamp to cap.
            for (int s = 0; s < NUM_SLOTS; s++) begin
                automatic logic [32:0] sum;
                if (!mine_q[s]) begin
                    tokens_q[s] <= '0;
                end else begin
                    sum = {1'b0, tokens_q[s]} + {1'b0, flow_sched_i[s].tokens_fp};
                    if (sum > {1'b0, cap_q[s]}) sum = {1'b0, cap_q[s]};
                    tokens_q[s] <= sum[31:0];
                end
            end

            if (!active) begin
                if (start) begin
                    // Accrue + clamp for the (twice-registered) picked slot.
                    // cost/cap are pre-registered per slot; the row + seq +
                    // checksums come from the precompute stage (pick_qq).
                    automatic logic [31:0] cost = cost_q[pick_qq];
                    automatic logic [31:0] cap  = cap_q[pick_qq];
                    automatic logic [32:0] acc  = {1'b0, tokens_q[pick_qq]} + {1'b0, row_qq.tokens_fp};
                    automatic logic [31:0] accv = (acc > {1'b0, cap}) ? cap : acc[31:0];
                    automatic logic [16:0] nl = {1'b0, eff_len_qq}
                                              + {1'b0, flow_sched_i[pick_qq].len_step};
                    // Stage the frame into fb every start cycle -- UNCONDITIONALLY,
                    // so the wide fb-write path is NOT lengthened by the token
                    // compare (fb setup is the dp_clk-critical path; gating it on
                    // accv>=cost blew WNS by ~0.25 ns). If we don't launch this
                    // cycle, the same slot re-stages next cycle (harmless).
                    build(row_qq, seq_qq, timestamp_i,
                          eff_sip_q, eff_dip_q, eff_v6src_q, eff_v6dst_q,
                          eff_smac_q, eff_dmac_q, eff_vlan_q,
                          eff_sp_q, eff_dp_q, csum_q, ocsum_q, psa_q, psb_q, paylen_q);
                    // Launch (emit) ONLY when the slot's tokens have really accrued
                    // to a frame's cost. pick_valid_qq no longer implies this (the
                    // active slot is kept speculatively eligible to prime the
                    // pipeline), so the token gate lives here -- this preserves rate
                    // limiting + cap=1 pacing. A slot whose pipeline is primed but
                    // whose bucket is not yet refilled simply waits (the accrual
                    // loop above keeps filling it). Only these NARROW control
                    // registers are gated -- not the wide fb -- so timing holds.
                    // Gate on the REGISTERED ready flag (tok_ready_q), not a fresh
                    // accrue+compare, to keep the arithmetic off the active path.
                    if (tok_ready_q[pick_qq]) begin
                        // Commit the per-slot sequence/length state AT LAUNCH, not
                        // at the frame's last beat: the precompute pipeline samples
                        // sequence_q/cur_len 3 cycles before a launch, and a primed
                        // back-to-back launch lands only 2-3 cycles after the
                        // previous frame's last beat -- an end-of-frame commit is
                        // still invisible to that sample, so the next frame would
                        // reuse the previous seq (dup on the wire) and skip one at
                        // the next fresh sample. Committing here keeps the writer
                        // >= 8 beats (min frame) ahead of the 3-cycle sample window,
                        // so the pipeline always reads post-commit state. seq_qq is
                        // the value THIS frame emits (modifiers/L4 csum in psb_q were
                        // derived from it), so counter := seq_qq + 1 keeps the wire
                        // and the counter self-consistent by construction.
                        sequence_q[pick_qq] <= seq_qq + 64'd1;
                        // NEXT sweep length (length just consumed + step/max/min).
                        cur_len[pick_qq] <= (nl > {1'b0, flow_sched_i[pick_qq].len_max})
                                            ? flow_sched_i[pick_qq].len_min : nl[15:0];
                        sel      <= pick_qq;
                        active   <= 1'b1;
                        // TEST template (0) carries a stampable test header; raw
                        // templates (1/2/3) must not be touched by pw_ts_insert.
                        frame_stampable <= (row_qq.frame_template == 2'd0);
                        byte_off <= '0;
                        rr_ptr   <= (pick_qq == SELW'(NUM_SLOTS-1)) ? '0 : pick_qq + 1'b1;
                        tokens_q[pick_qq] <= accv - cost;
                    end
                end
            end else if (m_tready) begin
                if (last) begin
                    // seq/cur_len for this slot were already committed at launch
                    // (see above) -- only the emit bookkeeping happens here.
                    active          <= 1'b0;
                    // TX frame + byte count for tx-rx loss / tx bps (clear wins
                    // over increment). frame_len = this frame's emitted L2 bytes.
                    if (!stats_clear_i) begin
                        tx_count[sel]       <= tx_count[sel] + 48'd1;
                        tx_bytes_count[sel] <= tx_bytes_count[sel] + 64'(frame_len);
                    end
                end else begin
                    byte_off <= byte_off + 12'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
