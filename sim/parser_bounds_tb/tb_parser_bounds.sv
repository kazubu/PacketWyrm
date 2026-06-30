// Testbench: pw_parser_axis fed RAW crafted frames that hit the inner-window
// (INNER_W) boundary cases the generator-driven TBs can't produce:
//   A. inner IPv4 with max options (IHL=60) + UDP  -> L4 ports land at inner[60..63]
//      (the exact INNER_W=64 boundary).
//   B. outer IPv6 + EtherIP + inner IPv6 + UDP + test header -> large `eff` (deep
//      encap window).
//   C. QinQ (double VLAN) + IPv4 + UDP -> eff at the VLAN-shifted L3 start.
// Each asserts the parsed key fields that read through the shifted inner[] window.
`default_nettype none

import pw_classifier_pkg::*;

module tb_parser_bounds;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [63:0] td = 0; logic [7:0] tk = 0; logic tv = 0, tl = 0;
    pw_match_key_t key; logic key_valid;
    pw_match_key_t kc;   // key captured AT the key_valid cycle (key_o is only valid then)

    int g_pass = 0, g_fail = 0;
    task chk(input string n, input logic c);
        if (c) begin g_pass++; $display("[ ok ] %s", n); end
        else   begin g_fail++; $display("[FAIL] %s", n); end
    endtask

    pw_parser_axis dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(td), .s_tkeep(tk), .s_tvalid(tv), .s_tready(), .s_tlast(tl),
        .ingress_port_i(4'd1),
        .rx_wire_ts_i(64'd0),
        .key_o(key), .key_valid_o(key_valid), .rx_wire_ts_o(), .window_o(), .base_o()
    );

    // frame byte buffer + builder helpers
    logic [7:0] fr [0:255];
    int         flen;
    task automatic put8 (input int o, input logic [7:0]  v); fr[o] = v; endtask
    task automatic put16(input int o, input logic [15:0] v); fr[o]=v[15:8]; fr[o+1]=v[7:0]; endtask
    task automatic put32(input int o, input logic [31:0] v);
        fr[o]=v[31:24]; fr[o+1]=v[23:16]; fr[o+2]=v[15:8]; fr[o+3]=v[7:0];
    endtask

    // drive fr[0..flen-1] as 64-bit AXIS beats, then wait for the key
    task automatic push_and_wait;
        @(negedge clk);
        for (int off = 0; off < flen; off += 8) begin
            logic [63:0] d; logic [7:0] k;
            d = '0; k = '0;
            for (int b = 0; b < 8 && (off + b) < flen; b++) begin
                d[b*8 +: 8] = fr[off + b]; k[b] = 1'b1;
            end
            td = d; tk = k; tv = 1'b1; tl = ((off + 8) >= flen);
            @(negedge clk);
        end
        td = '0; tk = '0; tv = 1'b0; tl = 1'b0;
        begin
            int t = 0;
            while (!key_valid && t < 40) begin @(posedge clk); t++; end
        end
        kc = key;          // capture NOW: key_o is only valid during the key_valid cycle
    endtask

    task automatic clear_frame; for (int i = 0; i < 256; i++) fr[i] = 8'h00; endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1; @(negedge clk);

        // ---- Case A: IPv4 IHL=60 (max options) + UDP + test header ----
        // eff=14, IPv4 hdr 14..73 (60 B), UDP 74..81 -> ports at inner[60..63].
        clear_frame;
        put16(12, 16'h0800);                 // ethertype IPv4
        put8 (14, 8'h4F);                     // ver 4, IHL 15 -> 60 B
        put8 (14+9, 8'd17);                   // proto UDP
        put32(14+12, 32'h0A00_0001);          // src
        put32(14+16, 32'h0A00_0002);          // dst
        put16(74, 16'd5000);                  // UDP src port  (inner[60..61])
        put16(76, 16'd5001);                  // UDP dst port  (inner[62..63])
        put32(82, 32'hA502_7E57);         // test magic at payload (74+8)
        put32(82+8, 32'd11);                  // flow_id
        flen = 82 + 32;
        push_and_wait();
        chk("A is_ipv4",      kc.is_ipv4);
        chk("A is_udp",       kc.is_udp);
        chk("A ipv4_dst",     kc.ipv4_dst == 32'h0A00_0002);
        chk("A l4_src 5000",  kc.l4_src == 16'd5000);   // boundary inner[60..61]
        chk("A l4_dst 5001",  kc.l4_dst == 16'd5001);   // boundary inner[62..63]
        chk("A is_test",      kc.is_test);
        chk("A flow_id 11",   kc.test_flow_id == 32'd11);

        // ---- Case B: outer IPv6 + EtherIP + inner IPv6 + UDP + test ----
        // eth14 + outer v6(40,nh=97) + EtherIP(2) + inner eth(14) + inner v6(40) + UDP8 + test32
        // eff = 14+40+2+14 = 70 ; inner v6 70..109 ; UDP 110..117 -> inner[40..47]
        clear_frame;
        put16(12, 16'h86DD);                  // ethertype IPv6 (outer)
        put8 (14, 8'h60);                     // outer v6 ver
        put8 (14+6, 8'd97);                    // outer next-header = EtherIP
        // EtherIP @54 (2 bytes: version nibble), inner eth @56
        put8 (54, 8'h30);                     // EtherIP v3 hdr
        put16(56+12, 16'h86DD);               // inner eth ethertype IPv6
        put8 (70, 8'h60);                     // inner v6 ver
        put8 (70+6, 8'd17);                    // inner next-header = UDP
        put32(70+8,  32'h2001_0DB8);          // inner v6 src [0:3]
        put32(70+24, 32'hDEAD_0001);          // inner v6 dst [0:3]
        put16(110, 16'd6000);                 // UDP src (inner[40..41])
        put16(112, 16'd6001);                 // UDP dst (inner[42..43])
        put32(118, 32'hA502_7E57);        // test magic at payload (70+40+8)
        put32(118+8, 32'd22);                 // flow_id
        flen = 118 + 32;
        push_and_wait();
        chk("B is_ipv6",      kc.is_ipv6);
        chk("B inner is_udp", kc.is_udp);
        chk("B ipv6_src hi",  kc.ipv6_src[127:96] == 32'h2001_0DB8);
        chk("B ipv6_dst hi",  kc.ipv6_dst[127:96] == 32'hDEAD_0001);
        chk("B l4_src 6000",  kc.l4_src == 16'd6000);
        chk("B l4_dst 6001",  kc.l4_dst == 16'd6001);
        chk("B is_test",      kc.is_test);
        chk("B flow_id 22",   kc.test_flow_id == 32'd22);

        // ---- Case C: QinQ (double VLAN) + IPv4 + UDP ----
        // eth12 + S-VLAN(0x88a8,4) + C-VLAN(0x8100,4) + ethertype + IPv4(20) + UDP8 + test32
        // l3_off = 22 ; eff = 22 ; IPv4 22..41 ; UDP 42..45 -> inner[20..23]
        clear_frame;
        put16(12, 16'h88A8);                  // S-tag TPID
        put16(14, 16'h0064);                  // S-VID 100
        put16(16, 16'h8100);                  // C-tag TPID
        put16(18, 16'h00C8);                  // C-VID 200
        put16(20, 16'h0800);                  // ethertype IPv4
        put8 (22, 8'h45);                     // ver4 IHL5 (20 B)
        put8 (22+9, 8'd17);                    // proto UDP
        put32(22+12, 32'hC0A8_0101);          // src
        put32(22+16, 32'hC0A8_0102);          // dst
        put16(42, 16'd7000);                  // UDP src (inner[20..21])
        put16(44, 16'd7001);                  // UDP dst (inner[22..23])
        put32(50, 32'hA502_7E57);         // test magic at payload (42+8)
        put32(50+8, 32'd33);                  // flow_id
        flen = 50 + 32;
        push_and_wait();
        chk("C is_ipv4",        kc.is_ipv4);
        chk("C vlan_valid",     kc.vlan_valid);
        chk("C inner_vlan",     kc.inner_vlan_valid);
        chk("C ipv4_dst",       kc.ipv4_dst == 32'hC0A8_0102);
        chk("C l4_src 7000",    kc.l4_src == 16'd7000);
        chk("C l4_dst 7001",    kc.l4_dst == 16'd7001);
        chk("C flow_id 33",     kc.test_flow_id == 32'd33);

        $display("parser_bounds: %0d passed, %0d failed", g_pass, g_fail);
        if (g_fail == 0) $display("ALL PARSER_BOUNDS SCENARIOS PASS");
        else begin $display("FAILED"); $fatal; end
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule
`default_nettype wire
