// Testbench: pw_parser_axis fed RAW crafted frames that hit the inner-window
// (INNER_W) boundary cases the generator-driven TBs can't produce:
//   A. inner IPv4 with max options (IHL=60) + UDP  -> L4 ports land at inner[60..63]
//      (the exact INNER_W=64 boundary).
//   B. outer IPv6 + EtherIP + inner IPv6 + UDP + test header -> large `eff` (deep
//      encap window).
//   C. QinQ (double VLAN) + IPv4 + UDP -> eff at the VLAN-shifted L3 start.
//   D. truncated GRE after a longer GRE frame left residual selector bytes in
//      hdr[] (never cleared between frames) -> must NOT read past frame_len:
//      classify on the outer only, no residual-driven inner family.
//   E. same for a truncated EtherIP frame (residual inner-ethertype bytes).
//   F. flagged GRE (C/K/S set or version != 0): header is longer than the bare
//      4 bytes the descent assumes -> treated as non-encap (outer-only key).
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
        .key_o(key), .key_valid_o(key_valid), .rx_wire_ts_o(), .frame_len_o(), .window_o(), .base_o()
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

        // ---- Case D: truncated GRE after a poisoning GRE frame ----
        // D0: a full GRE v4-in-v6 frame (outer v6 nh=47, GRE @54, ptype 0800
        // @56..57, inner v4 @58, UDP @78, test @86). Parses as inner v4 test
        // AND leaves 0x0800 residue at hdr[56..57].
        clear_frame;
        put16(12, 16'h86DD);                  // outer ethertype IPv6
        put8 (14, 8'h60);                     // outer v6 ver
        put8 (14+6, 8'd47);                   // outer next-header = GRE
        put16(54, 16'h0000);                  // GRE: no flags, ver 0
        put16(56, 16'h0800);                  // GRE protocol-type = IPv4
        put8 (58, 8'h45);                     // inner v4 ver/ihl
        put8 (58+9, 8'd17);                   // inner proto UDP
        put16(78, 16'd8000);                  // UDP src
        put16(80, 16'd8001);                  // UDP dst
        put32(86, 32'hA502_7E57);             // test magic (78+8)
        put32(86+8, 32'd44);                  // flow_id
        flen = 86 + 32;
        push_and_wait();
        chk("D0 gre inner is_ipv4", kc.is_ipv4);
        chk("D0 gre is_udp",        kc.is_udp);
        chk("D0 gre l4_src 8000",   kc.l4_src == 16'd8000);
        chk("D0 gre is_test",       kc.is_test);
        chk("D0 gre flow_id 44",    kc.test_flow_id == 32'd44);
        // D1: outer v6 nh=47 but the frame ENDS at the outer header (flen=54:
        // no GRE bytes at all). The residual 0x0800 at hdr[56..57] from D0
        // must not be read as this frame's GRE protocol type: the descent is
        // length-guarded -> non-encap, key carries the outer family only.
        clear_frame;
        put16(12, 16'h86DD);
        put8 (14, 8'h60);
        put8 (14+6, 8'd47);                   // GRE, but truncated
        flen = 54;
        push_and_wait();
        chk("D1 trunc-GRE residual is_ipv4 clear", !kc.is_ipv4);
        chk("D1 trunc-GRE outer is_ipv6 kept",     kc.is_ipv6);
        chk("D1 trunc-GRE not udp",                !kc.is_udp);
        chk("D1 trunc-GRE not test",               !kc.is_test);

        // ---- Case E: truncated EtherIP after a poisoning payload ----
        // E0: plain v4/UDP frame whose PAYLOAD carries 0x86DD at bytes 48..49
        // (where a later EtherIP descent would look for the inner ethertype).
        clear_frame;
        put16(12, 16'h0800);
        put8 (14, 8'h45);
        put8 (14+9, 8'd17);                   // proto UDP
        put16(34, 16'd1111); put16(36, 16'd2222);
        put16(48, 16'h86DD);                  // poison: fake inner ethertype
        flen = 96;
        push_and_wait();
        chk("E0 poison frame is_ipv4", kc.is_ipv4);
        // E1: outer v4 proto=97 (EtherIP) but the frame ends before the inner
        // ethertype (flen=40 < 14+20+16). The residual 0x86DD at hdr[48..49]
        // must not classify this frame as inner v6.
        clear_frame;
        put16(12, 16'h0800);
        put8 (14, 8'h45);
        put8 (14+9, 8'd97);                   // proto = EtherIP, but truncated
        flen = 40;
        push_and_wait();
        chk("E1 trunc-EtherIP residual is_ipv6 clear", !kc.is_ipv6);
        chk("E1 trunc-EtherIP outer is_ipv4 kept",     kc.is_ipv4);
        chk("E1 trunc-EtherIP not test",               !kc.is_test);

        // ---- Case F: flagged GRE -> treated as non-encap ----
        // F1: outer v4 proto=47, GRE @34 with the K flag set (byte0=0x20): the
        // real header is 8 bytes, so the fixed 4-byte descent would parse the
        // key field as an inner IPv4 header. Bytes 38.. are crafted to look
        // like a valid inner v4/UDP test frame -- with the flag check the
        // parser must NOT descend: outer-only key (l3_proto=47, no UDP/test).
        clear_frame;
        put16(12, 16'h0800);
        put8 (14, 8'h45);
        put8 (14+9, 8'd47);                   // proto GRE
        put8 (34, 8'h20);                     // GRE byte0: K flag set
        put8 (35, 8'h00);                     // ver 0
        put16(36, 16'h0800);                  // ptype IPv4
        put8 (38, 8'h45);                     // fake inner v4 (at the WRONG offset)
        put8 (38+9, 8'd17);
        put16(58, 16'd9000); put16(60, 16'd9001);
        put32(66, 32'hA502_7E57);             // fake inner test magic
        put32(66+8, 32'd55);
        flen = 66 + 32;
        push_and_wait();
        chk("F1 flagged-GRE outer is_ipv4",  kc.is_ipv4);
        chk("F1 flagged-GRE l3_proto 47",    kc.l3_proto == 8'd47);
        chk("F1 flagged-GRE not udp",        !kc.is_udp);
        chk("F1 flagged-GRE not test",       !kc.is_test);
        // F2: same frame with flags clear but version=1 (byte1[2:0]) -> also
        // treated as non-encap.
        put8 (34, 8'h00);
        put8 (35, 8'h01);                     // version != 0
        push_and_wait();
        chk("F2 gre-ver!=0 outer is_ipv4",   kc.is_ipv4);
        chk("F2 gre-ver!=0 l3_proto 47",     kc.l3_proto == 8'd47);
        chk("F2 gre-ver!=0 not test",        !kc.is_test);
        // F3 (control): flags clear + ver 0 -> the descent runs and the fake
        // inner parses as a v4/UDP test flow (proves F1/F2 changed the outcome
        // via the flag check, not some other guard).
        put8 (35, 8'h00);
        push_and_wait();
        chk("F3 bare-GRE descends: is_udp",  kc.is_udp);
        chk("F3 bare-GRE is_test",           kc.is_test);
        chk("F3 bare-GRE flow_id 55",        kc.test_flow_id == 32'd55);

        $display("parser_bounds: %0d passed, %0d failed", g_pass, g_fail);
        if (g_fail == 0) $display("ALL PARSER_BOUNDS SCENARIOS PASS");
        else begin $display("FAILED"); $fatal; end
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule
`default_nettype wire
