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
// / seq / timestamp). IP/UDP checksums left zero (MAC TX recomputes).
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
    parameter int HDR_MAX_BYTES     = 112   // IPv6 (40) + VLAN (4) + UDP (8) + payload (32) + eth (14) = 98
) (
    input  wire           clk,
    input  wire           rst_n,

    input  wire [63:0]    timestamp_i,

    // Decoded flow rows (full table); slots whose egress != EGRESS_PORT are
    // ignored here (another port's generator drives them).
    input  pw_flow_row_t  f_rows_i [NUM_SLOTS],

    // 64-bit AXIS egress
    output logic [63:0]   m_tdata,
    output logic [7:0]    m_tkeep,
    output logic          m_tvalid,
    input  wire           m_tready,
    output logic          m_tlast
);
    localparam logic [31:0] PW_TEST_HDR_MAGIC = 32'hA502_7E57;
    localparam int          SELW = $clog2(NUM_SLOTS);

    function automatic int frame_bytes(input logic vlen, input logic v6);
        return 14 + (vlen ? 4 : 0) + (v6 ? 40 : 20) + 8 + FRAME_LEN_PAYLOAD;
    endfunction

    // This slot belongs to this generator's egress port.
    function automatic logic mine(input pw_flow_row_t r);
        return r.valid && (r.egress == 4'(EGRESS_PORT));
    endfunction

    // Per-slot state.
    logic [63:0] sequence_q [NUM_SLOTS];
    logic [31:0] tokens_q   [NUM_SLOTS];   // Q16.16

    // In-flight frame (built from the selected slot at frame start).
    logic [HDR_MAX_BYTES-1:0][7:0] fb;
    logic [11:0]                   frame_len;
    logic [SELW-1:0]               sel;
    logic                          active;
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
                mine_q[s] <= mine(f_rows_i[s]);
                cost_q[s] <= {16'(frame_bytes(f_rows_i[s].vlan_en, f_rows_i[s].is_v6)), 16'h0};
                cap_q[s]  <= {f_rows_i[s].burst, 16'h0};
            end
        end
    end

    logic [NUM_SLOTS-1:0] eligible;
    always_comb begin
        for (int s = 0; s < NUM_SLOTS; s++)
            eligible[s] = mine_q[s] && (tokens_q[s] >= cost_q[s]);
    end
    logic [NUM_SLOTS-1:0] eligible_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) eligible_q <= '0;
        else        eligible_q <= eligible;
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

    always_comb begin
        m_tdata = '0;
        m_tkeep = '0;
        for (int k = 0; k < 8; k++) begin
            if (({20'b0, byte_off} + k) < {20'b0, frame_len}) begin
                m_tdata[k*8 +: 8] = fb[byte_off + k[11:0]];
                m_tkeep[k]        = 1'b1;
            end
        end
    end
    assign m_tvalid = active;
    assign m_tlast  = last;

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
    // IPv4 header checksum over the (mostly constant) header with the
    // effective src/dst addresses, the DSCP (TOS byte) and the TTL.
    // Constants: ver/ihl=0x45, flags/frag=0x4000, proto=0x11 (UDP); id and
    // csum contribute 0. tos = {dscp[5:0],2'b00} (6-bit DSCP, ECN=0).
    function automatic logic [15:0] ip_csum16(input logic [15:0] tot,
                                              input logic [31:0] sip, input logic [31:0] dip,
                                              input logic [7:0]  dscp, input logic [7:0] ttl);
        logic [31:0] s;
        s = {16'b0, 8'h45, dscp[5:0], 2'b00}     // ver/ihl | TOS
          + {16'b0, tot} + 32'h4000              // total length | flags/frag
          + {16'b0, ttl, 8'h11}                  // TTL | proto (UDP)
          + {16'b0, sip[31:16]} + {16'b0, sip[15:0]}
          + {16'b0, dip[31:16]} + {16'b0, dip[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        return ~s[15:0];
    endfunction

    // IPv6 UDP *partial* checksum (the tx_timestamp is deliberately excluded).
    // Sums the IPv6 pseudo-header (src + dst + upper-layer length + next-
    // header) + UDP header + the 32-byte L4 payload (test header: magic / ver /
    // flow_id / seq + 4 pad bytes) but NOT the 8-byte tx_timestamp. The egress
    // stamper (pw_ts_insert) overwrites tx_timestamp with the departure time
    // and folds those 4 words into this partial sum, producing the final,
    // valid UDP checksum on the wire (and applying the RFC 768 0->0xFFFF rule).
    // Excluding ts here is what lets the stamper fix the checksum in one pass:
    // the csum field (byte 60) leaves before the ts field (byte 82), so the
    // stamper can only *add* the (known, SOF-latched) ts, never subtract the
    // old one. We therefore emit the raw one's-complement (~s, no 0xFFFF rule)
    // so that ~csum == s exactly for the stamper to extend. Per-flow constant
    // apart from seq (which the stamper does not touch).
    function automatic logic [15:0] udp6_csum(
            input logic [127:0] src, input logic [127:0] dst,
            input logic [15:0] sport, input logic [15:0] dport, input logic [15:0] ulen,
            input logic [31:0] flow_id, input logic [63:0] seq);
        logic [31:0] s;
        // Single balanced-tree sum (NOT sequential `+=`): synthesis maps one
        // multi-term `+` expression to an adder TREE, whereas separate `+=`
        // statements become a long carry CHAIN. This cone is the dp_clk-
        // critical path (the deepest in the data plane), so the tree depth
        // matters. One's-complement addition is associative/commutative, so
        // the folded result is identical. ~30 16-bit terms: IPv6 pseudo-header
        // (src + dst + upper-layer length + next-header) + UDP header + the
        // test-header payload (magic / ver / flow_id / seq) -- but NOT the
        // tx_timestamp, which pw_ts_insert folds in at egress.
        s = {16'b0, src[127:112]} + {16'b0, src[111:96]} + {16'b0, src[95:80]}
          + {16'b0, src[79:64]}   + {16'b0, src[63:48]}  + {16'b0, src[47:32]}
          + {16'b0, src[31:16]}   + {16'b0, src[15:0]}
          + {16'b0, dst[127:112]} + {16'b0, dst[111:96]} + {16'b0, dst[95:80]}
          + {16'b0, dst[79:64]}   + {16'b0, dst[63:48]}  + {16'b0, dst[47:32]}
          + {16'b0, dst[31:16]}   + {16'b0, dst[15:0]}
          + {16'b0, ulen} + 32'h0000_0011                  // pseudo-hdr: ulen + next-header 17
          + {16'b0, sport} + {16'b0, dport} + {16'b0, ulen}            // UDP hdr (csum 0)
          + {16'b0, PW_TEST_HDR_MAGIC[31:16]} + {16'b0, PW_TEST_HDR_MAGIC[15:0]}
          + 32'h0000_0001                                  // version=0x0001, reserved=0
          + {16'b0, flow_id[31:16]} + {16'b0, flow_id[15:0]}
          + {16'b0, seq[63:48]} + {16'b0, seq[47:32]} + {16'b0, seq[31:16]} + {16'b0, seq[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        s = {16'b0, s[31:16]} + {16'b0, s[15:0]};
        return ~s[15:0];               // raw partial; stamper finalizes
    endfunction

    // --- precompute pipeline (two stages after the registered pick_q) -------
    // The effective (modifier-applied) header fields + checksums depend only on
    // the picked row and its sequence number -- both pick-stable -- so they are
    // precomputed off pick_q (NOT the combinational `pick`: that would chain
    // the 32-way priority encoder into the checksum adders). The path is split
    // into two register stages because, fused, it was the dp_clk-critical path:
    //
    //   Stage A (row latch): isolate the 32:1 mux of the wide (256-byte) flow
    //   rows -- f_rows_i[pick_q] -- into its own register. The mux pulls from
    //   the spread row array (route-heavy, ~4.3 ns), so it must drive ONLY a
    //   register, with no logic after it, to close.
    //
    //   Stage B (checksum): mod32/scramble + the IPv4/IPv6 checksum adders read
    //   the COMPACT local latch row_l (short routes) instead of the spread mux.
    //
    // build() then consumes the stage-B registers and only lays out bytes. (B
    // excludes the live tx_timestamp from udp6_csum -- that is what makes the
    // whole checksum pick-stable and thus precomputable here.)
    logic [SELW-1:0]  pick_l;
    logic             pvalid_l;
    pw_flow_row_t     row_l;
    logic [63:0]      seq_l;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pick_l <= '0; pvalid_l <= 1'b0; row_l <= '0; seq_l <= '0; end
        else begin
            pick_l   <= pick_q;
            pvalid_l <= pick_valid_q;
            row_l    <= f_rows_i[pick_q];      // the wide 32:1 mux, isolated
            seq_l    <= sequence_q[pick_q];
        end
    end

    logic [31:0]  pc_sip, pc_dip;
    logic [127:0] pc_v6src, pc_v6dst;
    logic [15:0]  pc_sp, pc_dp, pc_csum, pc_ucsum;
    always_comb begin
        pc_sip   = mod32(row_l.sip_mod, row_l.src_ipv4, row_l.sip_mask, seq_l);
        pc_dip   = mod32(row_l.dip_mod, row_l.dst_ipv4, row_l.dip_mask, seq_l);
        // IPv6 address modifiers apply to the low 32 bits (host/interface-ID
        // portion); the upper 96 bits are static. Reuses the same modifier
        // fields as the IPv4 src/dst (a flow is either v4 or v6).
        pc_v6src = {row_l.ipv6_src[127:32], mod32(row_l.sip_mod, row_l.ipv6_src[31:0], row_l.sip_mask, seq_l)};
        pc_v6dst = {row_l.ipv6_dst[127:32], mod32(row_l.dip_mod, row_l.ipv6_dst[31:0], row_l.dip_mask, seq_l)};
        pc_sp    = mod16(row_l.sp_mod,  row_l.udp_sp,   row_l.sp_mask,  seq_l);
        pc_dp    = mod16(row_l.dp_mod,  row_l.udp_dp,   row_l.dp_mask,  seq_l);
        pc_csum  = ip_csum16(16'(20 + 8 + FRAME_LEN_PAYLOAD), pc_sip, pc_dip,
                             row_l.dscp, row_l.ttl);
        pc_ucsum = udp6_csum(pc_v6src, pc_v6dst, pc_sp, pc_dp,
                             16'(8 + FRAME_LEN_PAYLOAD), row_l.flow_id, seq_l);
    end

    // Stage B latch (consumed by build): picked row + seq + precomputed fields.
    logic [SELW-1:0]  pick_qq;
    logic             pick_valid_qq;
    pw_flow_row_t     row_qq;
    logic [63:0]      seq_qq;
    logic [31:0]      eff_sip_q, eff_dip_q;
    logic [127:0]     eff_v6src_q, eff_v6dst_q;
    logic [15:0]      eff_sp_q, eff_dp_q, csum_q, ucsum_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pick_qq <= '0; pick_valid_qq <= 1'b0; row_qq <= '0; seq_qq <= '0;
            eff_sip_q <= '0; eff_dip_q <= '0; eff_sp_q <= '0; eff_dp_q <= '0;
            eff_v6src_q <= '0; eff_v6dst_q <= '0;
            csum_q    <= '0; ucsum_q  <= '0;
        end else begin
            pick_qq       <= pick_l;
            pick_valid_qq <= pvalid_l;
            row_qq        <= row_l;
            seq_qq        <= seq_l;
            eff_sip_q <= pc_sip;  eff_dip_q <= pc_dip;
            eff_v6src_q <= pc_v6src; eff_v6dst_q <= pc_v6dst;
            eff_sp_q  <= pc_sp;   eff_dp_q  <= pc_dp;
            csum_q    <= pc_csum; ucsum_q   <= pc_ucsum;
        end
    end

    // Build a slot's frame into fb at frame start. The effective header fields
    // and checksums are supplied precomputed (eff_* / csum / ucsum, registered
    // and aligned with the picked row); build() only lays out bytes.
    task automatic build(input pw_flow_row_t r, input logic [63:0] seq, input logic [63:0] ts,
                         input logic [31:0] eff_sip, input logic [31:0] eff_dip,
                         input logic [127:0] eff_v6src, input logic [127:0] eff_v6dst,
                         input logic [15:0] eff_sp,  input logic [15:0] eff_dp,
                         input logic [15:0] csum,    input logic [15:0] ucsum);
        int off, tl, total_len;
        logic [7:0] tos;
        tos = {r.dscp[5:0], 2'b00};        // IPv4 TOS / IPv6 TC byte (DSCP<<2, ECN 0)
        for (int i = 0; i < HDR_MAX_BYTES; i++) fb[i] <= 8'h00;
        fb[0]<=r.dst_mac[47:40]; fb[1]<=r.dst_mac[39:32]; fb[2]<=r.dst_mac[31:24];
        fb[3]<=r.dst_mac[23:16]; fb[4]<=r.dst_mac[15:8];  fb[5]<=r.dst_mac[7:0];
        fb[6]<=r.src_mac[47:40]; fb[7]<=r.src_mac[39:32]; fb[8]<=r.src_mac[31:24];
        fb[9]<=r.src_mac[23:16]; fb[10]<=r.src_mac[15:8]; fb[11]<=r.src_mac[7:0];
        off = 12;
        if (r.vlan_en) begin
            fb[off]<=8'h81; fb[off+1]<=8'h00;
            fb[off+2]<={4'h0,r.vlan_id[11:8]}; fb[off+3]<=r.vlan_id[7:0];
            off += 4;
        end
        tl = 8 + FRAME_LEN_PAYLOAD;        // UDP length, common to v4/v6
        if (r.is_v6) begin
            fb[off]<=8'h86; fb[off+1]<=8'hDD; off += 2;        // ethertype IPv6
            // 40-byte IPv6 header. TC (8b) spans byte0[3:0] + byte1[7:4];
            // flow label 0. tc = tos = dscp<<2.
            fb[off+0]<={4'h6, tos[7:4]}; fb[off+1]<={tos[3:0], 4'h0};
            fb[off+2]<=8'h00; fb[off+3]<=8'h00;                // flow label = 0
            fb[off+4]<=tl[15:8]; fb[off+5]<=tl[7:0];           // payload length = UDP+payload
            fb[off+6]<=8'd17; fb[off+7]<=r.ttl;                // next-header UDP, hop limit
            for (int b = 0; b < 16; b++) fb[off+8+b]  <= eff_v6src[127 - b*8 -: 8];
            for (int b = 0; b < 16; b++) fb[off+24+b] <= eff_v6dst[127 - b*8 -: 8];
            off += 40;
        end else begin
            fb[off]<=8'h08; fb[off+1]<=8'h00; off += 2;        // ethertype IPv4
            total_len = 20 + 8 + FRAME_LEN_PAYLOAD;
            fb[off+0]<=8'h45; fb[off+1]<=tos;                  // ver/ihl | TOS (DSCP)
            fb[off+2]<=total_len[15:8]; fb[off+3]<=total_len[7:0];
            fb[off+4]<=8'h00; fb[off+5]<=8'h00; fb[off+6]<=8'h40; fb[off+7]<=8'h00;
            fb[off+8]<=r.ttl; fb[off+9]<=8'h11; fb[off+10]<=csum[15:8]; fb[off+11]<=csum[7:0];  // TTL | proto
            fb[off+12]<=eff_sip[31:24]; fb[off+13]<=eff_sip[23:16];
            fb[off+14]<=eff_sip[15:8];  fb[off+15]<=eff_sip[7:0];
            fb[off+16]<=eff_dip[31:24]; fb[off+17]<=eff_dip[23:16];
            fb[off+18]<=eff_dip[15:8];  fb[off+19]<=eff_dip[7:0];
            off += 20;
        end
        // UDP header (csum: 0 for IPv4, computed/non-zero for IPv6)
        fb[off+0]<=eff_sp[15:8]; fb[off+1]<=eff_sp[7:0];
        fb[off+2]<=eff_dp[15:8]; fb[off+3]<=eff_dp[7:0];
        fb[off+4]<=tl[15:8]; fb[off+5]<=tl[7:0];
        if (r.is_v6) begin fb[off+6]<=ucsum[15:8]; fb[off+7]<=ucsum[7:0]; end
        else          begin fb[off+6]<=8'h00;       fb[off+7]<=8'h00;       end
        off += 8;
        fb[off+0]<=PW_TEST_HDR_MAGIC[31:24]; fb[off+1]<=PW_TEST_HDR_MAGIC[23:16];
        fb[off+2]<=PW_TEST_HDR_MAGIC[15:8];  fb[off+3]<=PW_TEST_HDR_MAGIC[7:0];
        fb[off+4]<=8'h00; fb[off+5]<=8'h01; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
        fb[off+8]<=r.flow_id[31:24]; fb[off+9]<=r.flow_id[23:16];
        fb[off+10]<=r.flow_id[15:8]; fb[off+11]<=r.flow_id[7:0];
        fb[off+12]<=seq[63:56]; fb[off+13]<=seq[55:48]; fb[off+14]<=seq[47:40]; fb[off+15]<=seq[39:32];
        fb[off+16]<=seq[31:24]; fb[off+17]<=seq[23:16]; fb[off+18]<=seq[15:8];  fb[off+19]<=seq[7:0];
        fb[off+20]<=ts[63:56]; fb[off+21]<=ts[55:48]; fb[off+22]<=ts[47:40]; fb[off+23]<=ts[39:32];
        fb[off+24]<=ts[31:24]; fb[off+25]<=ts[23:16]; fb[off+26]<=ts[15:8];  fb[off+27]<=ts[7:0];
        frame_len <= 12'(14 + (r.vlan_en ? 4 : 0) + (r.is_v6 ? 40 : 20) + 8 + FRAME_LEN_PAYLOAD);
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active   <= 1'b0;
            byte_off <= '0;
            rr_ptr   <= '0;
            sel      <= '0;
            for (int s = 0; s < NUM_SLOTS; s++) begin
                sequence_q[s] <= '0;
                tokens_q[s]   <= '0;
            end
        end else begin
            // Token buckets: accumulate per active slot, clamp to cap.
            for (int s = 0; s < NUM_SLOTS; s++) begin
                automatic logic [32:0] sum;
                if (!mine_q[s]) begin
                    tokens_q[s] <= '0;
                end else begin
                    sum = {1'b0, tokens_q[s]} + {1'b0, f_rows_i[s].tokens_fp};
                    if (sum > {1'b0, cap_q[s]}) sum = {1'b0, cap_q[s]};
                    tokens_q[s] <= sum[31:0];
                end
            end

            if (!active) begin
                if (start) begin
                    // Accrue + clamp + deduct for the (twice-registered) picked
                    // slot; this write overrides the accrual loop above (last
                    // write wins). cost/cap are pre-registered per slot; the row
                    // + seq + checksums come from the precompute stage (pick_qq).
                    automatic logic [31:0] cost = cost_q[pick_qq];
                    automatic logic [31:0] cap  = cap_q[pick_qq];
                    automatic logic [32:0] acc  = {1'b0, tokens_q[pick_qq]} + {1'b0, row_qq.tokens_fp};
                    automatic logic [31:0] accv = (acc > {1'b0, cap}) ? cap : acc[31:0];
                    build(row_qq, seq_qq, timestamp_i,
                          eff_sip_q, eff_dip_q, eff_v6src_q, eff_v6dst_q,
                          eff_sp_q, eff_dp_q, csum_q, ucsum_q);
                    sel      <= pick_qq;
                    active   <= 1'b1;
                    byte_off <= '0;
                    rr_ptr   <= (pick_qq == SELW'(NUM_SLOTS-1)) ? '0 : pick_qq + 1'b1;
                    tokens_q[pick_qq] <= (accv >= cost) ? (accv - cost) : '0;
                end
            end else if (m_tready) begin
                if (last) begin
                    active          <= 1'b0;
                    sequence_q[sel] <= sequence_q[sel] + 64'd1;
                end else begin
                    byte_off <= byte_off + 12'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
