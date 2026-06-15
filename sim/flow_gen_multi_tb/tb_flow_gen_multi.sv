// Unit testbench: pw_flow_gen_multi -> pw_parser_axis. Two enabled flow
// slots (distinct flow_ids / IPs) share one egress port; confirm the
// parser recovers BOTH flows interleaved, each with a monotonic sequence
// (round-robin scheduling + per-flow sequence counters).
`default_nettype none

import pw_classifier_pkg::*;

module tb_flow_gen_multi;
    localparam int SLOTS = 4;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [63:0] ts = 0;

    logic        f_en   [SLOTS];
    logic [31:0] f_fid  [SLOTS];
    logic [31:0] f_tok  [SLOTS];
    logic [15:0] f_burst[SLOTS];
    logic [47:0] f_smac [SLOTS];
    logic [47:0] f_dmac [SLOTS];
    logic        f_ven  [SLOTS];
    logic [11:0] f_vid  [SLOTS];
    logic [31:0] f_sip  [SLOTS];
    logic [31:0] f_dip  [SLOTS];
    logic [15:0] f_usp  [SLOTS];
    logic [15:0] f_udp  [SLOTS];

    logic [63:0] td; logic [7:0] tk; logic tv, tl;

    pw_flow_gen_multi #(.NUM_SLOTS(SLOTS), .FRAME_LEN_PAYLOAD(32)) gen (
        .clk(clk), .rst_n(rst_n), .timestamp_i(ts),
        .f_enable_i(f_en), .f_flow_id_i(f_fid), .f_tokens_fp_i(f_tok), .f_burst_i(f_burst),
        .f_src_mac_i(f_smac), .f_dst_mac_i(f_dmac), .f_vlan_en_i(f_ven), .f_vlan_id_i(f_vid),
        .f_src_ipv4_i(f_sip), .f_dst_ipv4_i(f_dip), .f_udp_sp_i(f_usp), .f_udp_dp_i(f_udp),
        .m_tdata(td), .m_tkeep(tk), .m_tvalid(tv), .m_tready(1'b1), .m_tlast(tl)
    );

    pw_match_key_t key; logic key_valid;
    pw_parser_axis dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(td), .s_tkeep(tk), .s_tvalid(tv), .s_tready(), .s_tlast(tl),
        .ingress_port_i(4'd0), .key_o(key), .key_valid_o(key_valid)
    );

    int  g_pass = 0, g_fail = 0;
    task chk(input string n, input logic c);
        if (c) begin g_pass++; $display("[ ok ] %s", n); end
        else   begin g_fail++; $display("[FAIL] %s", n); end
    endtask

    // Per-flow_id tracking.
    int      seen_a = 0, seen_b = 0;            // flow_id 1, flow_id 3
    logic [63:0] lastseq_a, lastseq_b;
    logic    ok_a = 1, ok_b = 1;

    always_ff @(posedge clk) begin
        ts <= ts + 1;
        if (rst_n && key_valid && key.is_test) begin
            if (key.test_flow_id == 32'd1) begin
                if (seen_a > 0 && key.test_sequence != lastseq_a + 1) ok_a = 0;
                lastseq_a = key.test_sequence; seen_a++;
            end else if (key.test_flow_id == 32'd3) begin
                if (seen_b > 0 && key.test_sequence != lastseq_b + 1) ok_b = 0;
                lastseq_b = key.test_sequence; seen_b++;
            end
        end
    end

    initial begin
        for (int s = 0; s < SLOTS; s++) begin
            f_en[s]=0; f_fid[s]=0; f_tok[s]=0; f_burst[s]=16'd128;
            f_smac[s]=48'h02_00_00_00_00_01; f_dmac[s]=48'hFF_FF_FF_FF_FF_FF;
            f_ven[s]=0; f_vid[s]=0; f_sip[s]=32'h0A000001; f_dip[s]=32'h0A000002;
            f_usp[s]=16'd4000; f_udp[s]=16'd4001;
        end
        // slot 0: flow_id 1, slot 2: flow_id 3 -- both enabled, same rate.
        f_en[0]=1; f_fid[0]=32'd1; f_tok[0]=32'h00200000; f_sip[0]=32'h0A000001;
        f_en[2]=1; f_fid[2]=32'd3; f_tok[2]=32'h00200000; f_sip[2]=32'h0A000003;

        repeat (4) @(posedge clk); rst_n = 1;
        repeat (3000) @(posedge clk);

        chk("flow_id 1 seen (>=20)", seen_a >= 20);
        chk("flow_id 3 seen (>=20)", seen_b >= 20);
        chk("flow_id 1 sequence monotonic", ok_a);
        chk("flow_id 3 sequence monotonic", ok_b);
        // round-robin fairness: counts within 2x of each other
        chk("both flows roughly balanced",
            (seen_a <= 2*seen_b + 4) && (seen_b <= 2*seen_a + 4));
        $display("flow_gen_multi: fid1=%0d fid3=%0d (%0d pass, %0d fail)", seen_a, seen_b, g_pass, g_fail);
        if (g_fail == 0) $display("ALL FLOW_GEN_MULTI SCENARIOS PASS");
        else $display("FAILED with %0d error(s)", g_fail);
        $finish;
    end

    initial begin #400000; $display("WATCHDOG TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
