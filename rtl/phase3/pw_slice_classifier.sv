// PacketWyrm generic slice-based classifier.
//
// Classifies a frame by ARBITRARY header bytes (offset/mask/value), so flows
// are defined by header match -- the payload is free (no dependence on the
// test-header flow_id, unlike pw_flowid_map). This is the RMT/P4-style "user-
// defined field" engine (docs/design/generic-classifier.md).
//
// Two stages, both cheap + routable (unlike the 600-bit-key parallel match):
//   * NSLICE shared pw_slice_match units, each programmed {offset,mask,value}
//     over the parser's captured header window -> one slice-match bit. The
//     wide byte-extract+compare happens once per unit, NOT per flow.
//   * NRULE rules, each a care-mask over the NSLICE bits + an action/result.
//     A rule hits iff (slice_match & care) == care (all required slices match).
//     Priority winner (lowest priority_, ties -> lowest index) -> result. The
//     per-rule compare is only NSLICE bits wide, so NRULE scales far past the
//     ~16 the full-key classifier was capped at.
//
// Latency key_valid_i -> result_o = 2 cycles (slice-match register + result
// register), matching pw_classifier (RESULT_STAGES=2) so the data plane reuses
// the same key delay.

`default_nettype none

import pw_classifier_pkg::*;

module pw_slice_classifier #(
    parameter int HDR_BYTES = 160,
    // Slice match window: the units only mux over the first SLICE_WIN bytes of
    // the captured header (the byte-mux is the dominant LUT cost, so this is
    // bounded well below HDR_BYTES). 48 reaches L3/L4 of a non-encapsulated
    // frame (base + udp_dst/ipv4_dst); deep-encap inner matching is out of reach
    // here and uses the flow-id map instead. base+offset >= SLICE_WIN -> no match.
    parameter int SLICE_WIN = HDR_BYTES,
    parameter int NSLICE    = 16,
    parameter int NRULE     = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // From the parser (aligned with key_valid_i): captured header window +
    // inner-frame base offset (so slice offsets are relative to the inner frame).
    input  wire [HDR_BYTES*8-1:0]        window_i,
    input  wire [15:0]                   base_i,
    input  wire                          key_valid_i,

    // Slice config programming: slice[idx] = {offset, mask, value}.
    input  wire                          slice_wr_en,
    input  wire [$clog2(NSLICE)-1:0]     slice_wr_idx,
    input  wire [15:0]                   slice_wr_offset,
    input  wire [31:0]                   slice_wr_mask,
    input  wire [31:0]                   slice_wr_value,

    // Rule programming: rule[idx] = {care, action, egress, local_flow_id, prio, enable}.
    input  wire                          rule_wr_en,
    input  wire [$clog2(NRULE)-1:0]      rule_wr_idx,
    input  wire [NSLICE-1:0]             rule_wr_care,
    input  wire [2:0]                    rule_wr_action,
    input  wire [3:0]                    rule_wr_egress,
    input  wire [31:0]                   rule_wr_lfid,
    input  wire [7:0]                    rule_wr_prio,
    input  wire                          rule_wr_enable,

    output pw_class_result_t             result_o
);

    // ---- slice config registers (small; quasi-static) ----
    logic [15:0] s_offset [NSLICE];
    logic [31:0] s_mask   [NSLICE];
    logic [31:0] s_value  [NSLICE];
    initial begin
        for (int i = 0; i < NSLICE; i++) begin s_offset[i]='0; s_mask[i]='0; s_value[i]='0; end
    end
    always_ff @(posedge clk) begin
        if (slice_wr_en) begin
            s_offset[slice_wr_idx] <= slice_wr_offset;
            s_mask[slice_wr_idx]   <= slice_wr_mask;
            s_value[slice_wr_idx]  <= slice_wr_value;
        end
    end

    // ---- rule table registers ----
    logic [NSLICE-1:0] r_care   [NRULE];
    pw_action_e        r_action [NRULE];
    logic [3:0]        r_egress [NRULE];
    logic [31:0]       r_lfid   [NRULE];
    logic [7:0]        r_prio   [NRULE];
    logic              r_enable [NRULE];
    initial begin
        for (int i = 0; i < NRULE; i++) begin
            r_care[i]='0; r_action[i]=PW_ACT_DROP; r_egress[i]='0;
            r_lfid[i]='0; r_prio[i]='0; r_enable[i]=1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (rule_wr_en) begin
            r_care[rule_wr_idx]   <= rule_wr_care;
            r_action[rule_wr_idx] <= pw_action_e'(rule_wr_action);
            r_egress[rule_wr_idx] <= rule_wr_egress;
            r_lfid[rule_wr_idx]   <= rule_wr_lfid;
            r_prio[rule_wr_idx]   <= rule_wr_prio;
            r_enable[rule_wr_idx] <= rule_wr_enable;
        end
    end

    // ---- stage 1: slice extract + match, registered ----
    logic [NSLICE-1:0] smatch_q;
    logic              sv_q;
    genvar gi;
    generate
        for (gi = 0; gi < NSLICE; gi++) begin : g_slice
            logic m;
            // Only the low SLICE_WIN bytes feed the match units (bounds the mux).
            pw_slice_match #(.HDR_BYTES(SLICE_WIN)) u_sm (
                .window_i(window_i[SLICE_WIN*8-1:0]), .base_i(base_i), .offset_i(s_offset[gi]),
                .mask_i(s_mask[gi]), .value_i(s_value[gi]), .match_o(m)
            );
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) smatch_q[gi] <= 1'b0;
                else        smatch_q[gi] <= m;
            end
        end
    endgenerate
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sv_q <= 1'b0; else sv_q <= key_valid_i;
    end

    // ---- stage 2: rule combine + priority winner, registered ----
    // rule hit = enabled & valid & all cared slices match.
    logic [NRULE-1:0] rhit;
    always_comb begin
        for (int i = 0; i < NRULE; i++)
            rhit[i] = r_enable[i] && sv_q && ((smatch_q & r_care[i]) == r_care[i]);
    end
    // priority winner (lowest prio_, ties -> lowest index) -- O(N^2) parallel.
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
                result_c.entry_index   = PW_ENTRY_IDX_W'(i);
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) result_o <= '0;
        else        result_o <= result_c;
    end

endmodule

`default_nettype wire
