// Testbench: pw_flow_gen_axis -> pw_parser_axis. Confirms the streaming
// parser recovers the classification key (IPv4/UDP + test header
// sequence / flow_id) from the generated 64-bit AXIS frames.
`default_nettype none

import pw_classifier_pkg::*;

module tb_parser_axis;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [63:0] td; logic [7:0] tk; logic tv, tl;
    logic [63:0] ts = 0;

    pw_match_key_t key; logic key_valid;

    int g_pass = 0, g_fail = 0;
    task chk(input string n, input logic c);
        if (c) begin g_pass++; $display("[ ok ] %s", n); end
        else   begin g_fail++; $display("[FAIL] %s", n); end
    endtask

    pw_flow_gen_axis #(.GLOBAL_FLOW_ID(32'd7), .FRAME_LEN_PAYLOAD(32)) gen (
        .clk(clk), .rst_n(rst_n), .enable_i(1'b1),
        .tokens_per_tick_fp_i(32'd00200000), .burst_bytes_i(16'd128),
        .egress_port_i(4'd0),
        .src_mac_i(48'h02_00_00_00_00_01), .dst_mac_i(48'hFF_FF_FF_FF_FF_FF),
        .vlan_enable_i(1'b0), .vlan_id_i(12'd0),
        .src_ipv4_i(32'h0A000001), .dst_ipv4_i(32'h0A000002),
        .udp_src_port_i(16'd4000), .udp_dst_port_i(16'd4001),
        .timestamp_i(ts),
        .m_tdata(td), .m_tkeep(tk), .m_tvalid(tv), .m_tready(1'b1), .m_tlast(tl)
    );

    pw_parser_axis dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(td), .s_tkeep(tk), .s_tvalid(tv), .s_tready(), .s_tlast(tl),
        .ingress_port_i(4'd3),
        .key_o(key), .key_valid_o(key_valid)
    );

    int seen = 0;
    logic [63:0] last_seq;
    always_ff @(posedge clk) begin
        ts <= ts + 1;
        if (rst_n && key_valid && key.is_test) begin
            if (seen == 0) begin
                chk("is_ipv4",       key.is_ipv4);
                chk("is_udp",        key.is_udp);
                chk("ethertype 0800",key.ethertype == 16'h0800);
                chk("ipv4_src",      key.ipv4_src == 32'h0A000001);
                chk("ipv4_dst",      key.ipv4_dst == 32'h0A000002);
                chk("l4_src 4000",   key.l4_src == 16'd4000);
                chk("l4_dst 4001",   key.l4_dst == 16'd4001);
                chk("flow_id 7",     key.test_flow_id == 32'd7);
                chk("ingress 3",     key.ingress_port == 4'd3);
                chk("seq0 == 0",     key.test_sequence == 64'd0);
            end else begin
                chk($sformatf("seq monotonic #%0d", seen), key.test_sequence == last_seq + 1);
            end
            last_seq = key.test_sequence;
            seen++;
        end
    end

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (2500) @(posedge clk);
        chk("parsed >= 3 test frames", seen >= 3);
        $display("parser_axis: %0d passed, %0d failed (%0d keys)", g_pass, g_fail, seen);
        if (g_fail == 0) $display("ALL PARSER_AXIS SCENARIOS PASS");
        $finish;
    end
endmodule
`default_nettype wire
