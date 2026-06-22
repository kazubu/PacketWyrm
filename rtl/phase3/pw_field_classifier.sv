// PacketWyrm unified field + UDF comparator classifier (classifier v2).
//
// Replaces BOTH the legacy pw_classifier (an N x ~600-bit parallel masked key
// compare that hit the xcku3p route wall at ~16 entries) and the interim
// pw_slice_classifier. The route wall came from comparing a WIDE key in every
// rule; this engine breaks that by pre-computing a small set of narrow
// comparator bits and letting rules combine only those bits:
//
//   Stage 1 -- comparator bank (the cheap part):
//     * NCMP "field comparators": each {src_sel, mask, value} over a 32-bit
//       lane selected from the parser's CANONICAL fields (pw_match_key_t). The
//       fields are already extracted + position-normalized by the parser, so a
//       comparator is a mux-of-fixed-lanes + a 32-bit masked compare -- NO byte
//       mux over the raw frame (that was the slice classifier's cost). A 128-bit
//       field (IPv6 addr) is matched with 4 comparators over its 4 lanes.
//     * NUDF "slice comparators": {offset, mask, value} over the raw inner-frame
//       window (pw_slice_match) for fields the parser doesn't name (DSCP, TTL,
//       flow label, TCP flags, arbitrary bytes). Bounded byte-mux (SLICE_WIN).
//     -> NTOTAL = NCMP + NUDF match bits, registered.
//
//   Stage 2 -- rule combine (the scalable part):
//     NRULE rules, each {care[NTOTAL], action, egress, local_flow_id,
//     logical_if_id, priority, enable}. A rule hits iff enabled & valid &
//     (cmatch & care) == care. Priority winner (lowest priority_, ties -> lowest
//     index). The per-rule compare is only NTOTAL bits, so NRULE scales far past
//     the legacy ~16 wall and routes comfortably.
//
// Handles every action the legacy classifier did (TEST_RX / PUNT / MIRROR /
// FORWARD / DROP). TEST_RX high-count structured traffic still rides the
// flow-id map; this engine carries header-defined test flows + punt + forward.
//
// Latency key_valid_i -> result_o = 2 cycles (comparator register + result
// register), matching the old pw_classifier (RESULT_STAGES=2) so the data plane
// reuses the same key/window delay.

`default_nettype none

import pw_classifier_pkg::*;

module pw_field_classifier #(
    parameter int HDR_BYTES = 160,
    parameter int SLICE_WIN = 48,    // UDF match window depth (bounds the byte-mux)
    parameter int NCMP      = 12,    // field comparators (canonical-field sourced)
    parameter int NUDF      = 2,     // UDF slice comparators (raw window)
    parameter int NRULE     = 32     // combine rules
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Sources, aligned with key_valid_i (parser outputs).
    input  pw_match_key_t                key_i,
    input  wire [SLICE_WIN*8-1:0]        window_i,   // raw inner-frame bytes
    input  wire [15:0]                   base_i,     // inner-frame (L3) base
    input  wire                          key_valid_i,

    // Field-comparator programming: cmp[idx] = {src_sel, mask, value}.
    input  wire                          cmp_wr_en,
    input  wire [$clog2(NCMP)-1:0]       cmp_wr_idx,
    input  wire [4:0]                    cmp_wr_src,
    input  wire [31:0]                   cmp_wr_mask,
    input  wire [31:0]                   cmp_wr_value,

    // UDF-comparator programming: udf[idx] = {offset, mask, value}.
    input  wire                          udf_wr_en,
    input  wire [$clog2(NUDF)-1:0]       udf_wr_idx,
    input  wire [15:0]                   udf_wr_offset,
    input  wire [31:0]                   udf_wr_mask,
    input  wire [31:0]                   udf_wr_value,

    // Rule programming: rule[idx] = {care, action, egress, lfid, lif, prio, enable}.
    input  wire                          rule_wr_en,
    input  wire [$clog2(NRULE)-1:0]      rule_wr_idx,
    input  wire [NCMP+NUDF-1:0]          rule_wr_care,
    input  wire [2:0]                    rule_wr_action,
    input  wire [3:0]                    rule_wr_egress,
    input  wire [31:0]                   rule_wr_lfid,
    input  wire [31:0]                   rule_wr_lif,
    input  wire [7:0]                    rule_wr_prio,
    input  wire                          rule_wr_enable,

    output pw_class_result_t             result_o
);
    localparam int NTOTAL = NCMP + NUDF;

    // ---- canonical source lanes (32-bit), mux-selected per field comparator ----
    // The "flags" lane packs the parser's boolean classifications so a rule can
    // match e.g. is_arp / is_udp / is_test with a 1-bit mask on lane 12.
    function automatic logic [31:0] flags_lane(input pw_match_key_t k);
        return {21'b0, k.valid, k.vlan_valid, k.is_ospf, k.is_icmp6, k.is_icmp,
                k.is_udp, k.is_tcp, k.is_ipv6, k.is_ipv4, k.is_arp, k.is_test};
    endfunction
    function automatic logic [31:0] src_lane(input pw_match_key_t k, input logic [4:0] sel);
        case (sel)
            5'd0:  src_lane = {16'b0, k.l4_dst};
            5'd1:  src_lane = {16'b0, k.l4_src};
            5'd2:  src_lane = k.ipv4_dst;
            5'd3:  src_lane = k.ipv4_src;
            5'd4:  src_lane = k.ipv6_dst[127:96];
            5'd5:  src_lane = k.ipv6_dst[95:64];
            5'd6:  src_lane = k.ipv6_dst[63:32];
            5'd7:  src_lane = k.ipv6_dst[31:0];
            5'd8:  src_lane = {16'b0, k.ethertype};
            5'd9:  src_lane = {24'b0, k.l3_proto};
            5'd10: src_lane = {19'b0, k.inner_vlan_valid, k.vlan_id[11:0]}; // [11:0] vlan, [12] inner present
            5'd11: src_lane = k.test_flow_id;
            5'd12: src_lane = flags_lane(k);
            5'd13: src_lane = {28'b0, k.ingress_port};
            5'd14: src_lane = k.ipv6_src[31:0];
            5'd15: src_lane = k.ipv6_src[127:96];
            default: src_lane = 32'b0;
        endcase
    endfunction

    // ---- comparator config registers (quasi-static) ----
    logic [4:0]  c_src   [NCMP];
    logic [31:0] c_mask  [NCMP];
    logic [31:0] c_value [NCMP];
    logic [15:0] u_off   [NUDF];
    logic [31:0] u_mask  [NUDF];
    logic [31:0] u_value [NUDF];
    initial begin
        for (int i = 0; i < NCMP; i++) begin c_src[i]='0; c_mask[i]='0; c_value[i]='0; end
        for (int i = 0; i < NUDF; i++) begin u_off[i]='0; u_mask[i]='0; u_value[i]='0; end
    end
    always_ff @(posedge clk) begin
        if (cmp_wr_en) begin
            c_src[cmp_wr_idx] <= cmp_wr_src; c_mask[cmp_wr_idx] <= cmp_wr_mask;
            c_value[cmp_wr_idx] <= cmp_wr_value;
        end
        if (udf_wr_en) begin
            u_off[udf_wr_idx] <= udf_wr_offset; u_mask[udf_wr_idx] <= udf_wr_mask;
            u_value[udf_wr_idx] <= udf_wr_value;
        end
    end

    // ---- rule table registers ----
    logic [NTOTAL-1:0] r_care   [NRULE];
    pw_action_e        r_action [NRULE];
    logic [3:0]        r_egress [NRULE];
    logic [31:0]       r_lfid   [NRULE];
    logic [31:0]       r_lif    [NRULE];
    logic [7:0]        r_prio   [NRULE];
    logic              r_enable [NRULE];
    initial begin
        for (int i = 0; i < NRULE; i++) begin
            r_care[i]='0; r_action[i]=PW_ACT_DROP; r_egress[i]='0;
            r_lfid[i]='0; r_lif[i]='0; r_prio[i]='0; r_enable[i]=1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (rule_wr_en) begin
            r_care[rule_wr_idx]   <= rule_wr_care;
            r_action[rule_wr_idx] <= pw_action_e'(rule_wr_action);
            r_egress[rule_wr_idx] <= rule_wr_egress;
            r_lfid[rule_wr_idx]   <= rule_wr_lfid;
            r_lif[rule_wr_idx]    <= rule_wr_lif;
            r_prio[rule_wr_idx]   <= rule_wr_prio;
            r_enable[rule_wr_idx] <= rule_wr_enable;
        end
    end

    // ---- stage 1: comparators, registered ----
    logic [NTOTAL-1:0] cmatch_q;
    logic              cv_q;
    genvar gi;
    generate
        // field comparators (mux-of-lanes + masked compare; no byte mux)
        for (gi = 0; gi < NCMP; gi++) begin : g_cmp
            wire [31:0] lane = src_lane(key_i, c_src[gi]);
            wire        m    = ((lane & c_mask[gi]) == (c_value[gi] & c_mask[gi]));
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) cmatch_q[gi] <= 1'b0; else cmatch_q[gi] <= m;
            end
        end
        // UDF slice comparators (raw window byte-extract)
        for (gi = 0; gi < NUDF; gi++) begin : g_udf
            logic m;
            pw_slice_match #(.HDR_BYTES(SLICE_WIN)) u_sm (
                .window_i(window_i), .base_i(base_i), .offset_i(u_off[gi]),
                .mask_i(u_mask[gi]), .value_i(u_value[gi]), .match_o(m)
            );
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) cmatch_q[NCMP+gi] <= 1'b0; else cmatch_q[NCMP+gi] <= m;
            end
        end
    endgenerate
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cv_q <= 1'b0; else cv_q <= key_valid_i;
    end

    // ---- stage 2: rule combine + priority winner, registered ----
    logic [NRULE-1:0] rhit;
    always_comb begin
        for (int i = 0; i < NRULE; i++)
            rhit[i] = r_enable[i] && cv_q && ((cmatch_q & r_care[i]) == r_care[i]);
    end
    pw_class_result_t result_c;
    always_comb begin
        result_c = '0;
        result_c.action = PW_ACT_DROP;
        for (int i = 0; i < NRULE; i++) begin
            automatic logic beaten = 1'b0;
            for (int j = 0; j < NRULE; j++)
                if (j != i && rhit[j] &&
                    (r_prio[j] < r_prio[i] || (r_prio[j] == r_prio[i] && j < i)))
                    beaten = 1'b1;
            if (rhit[i] && !beaten) begin
                result_c.hit           = 1'b1;
                result_c.action        = r_action[i];
                result_c.egress_port   = r_egress[i];
                result_c.local_flow_id = r_lfid[i];
                result_c.logical_if_id = r_lif[i];
                result_c.entry_index   = PW_ENTRY_IDX_W'(i[PW_ENTRY_IDX_W-1:0]);
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) result_o <= '0; else result_o <= result_c;
    end

endmodule

`default_nettype wire
