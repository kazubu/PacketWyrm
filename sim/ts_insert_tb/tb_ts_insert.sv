// Testbench for pw_ts_insert: egress tx_timestamp overwrite + IPv6 UDP
// checksum fixup. Builds synthetic frames matching the generator layout:
//   - IPv4 no-VLAN test packet -> bytes 62..69 overwritten (magic-gated);
//   - IPv4 VLAN test packet    -> bytes 66..73 overwritten;
//   - IPv4 non-test packet (wrong magic) -> unchanged;
//   - IPv6 generator frame (tuser=1) -> tx_ts@82 overwritten AND the partial
//     UDP checksum@60 finalized so the wire frame's UDP checksum is valid;
//   - IPv6 forwarded frame (tuser=0) -> untouched (csum + ts preserved).

`default_nettype none

module tb_ts_insert;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic [63:0] ts_now;
    logic [63:0] s_td, m_td;
    logic [7:0]  s_tk, m_tk;
    logic        s_tv, s_tr, s_tl, s_tu, m_tv, m_tr, m_tl, m_tu;

    pw_ts_insert dut (
        .clk(clk), .rst_n(rst_n), .ts_now(ts_now),
        .s_tdata(s_td), .s_tkeep(s_tk), .s_tvalid(s_tv), .s_tready(s_tr), .s_tlast(s_tl), .s_tuser(s_tu),
        .m_tdata(m_td), .m_tkeep(m_tk), .m_tvalid(m_tv), .m_tready(m_tr), .m_tlast(m_tl), .m_tuser(m_tu)
    );

    int errors = 0;
    task automatic chk(string w, longint g, longint e);
        if (g !== e) begin $display("[FAIL] %s got=%02x exp=%02x", w, g, e); errors++; end
    endtask
    task automatic chk1(string w, logic g);
        if (g !== 1'b1) begin $display("[FAIL] %s", w); errors++; end
    endtask

    logic [7:0] fin  [96];
    logic [7:0] fout [96];

    // Drive a 96-byte frame with a given SOF tuser, capture the output bytes.
    task automatic run_frame(input logic [63:0] tsv, input bit tuser);
        int beats = 12;   // 96 bytes / 8
        ts_now = tsv;
        m_tr   = 1'b1;
        // Drive inputs on negedge so the DUT's beat counter (incremented on
        // posedge as each beat is accepted) aligns with the data presented.
        for (int b = 0; b < beats; b++) begin
            @(negedge clk);
            for (int l = 0; l < 8; l++) s_td[l*8 +: 8] = fin[b*8 + l];
            s_tv = 1'b1; s_tk = 8'hFF; s_tl = (b == beats - 1); s_tu = tuser;
            #1;  // combinational overwrite settles; beat_reg == b
            for (int l = 0; l < 8; l++) fout[b*8 + l] = m_td[l*8 +: 8];
        end
        @(negedge clk); s_tv = 1'b0; s_tl = 1'b0; s_tu = 1'b0;
        @(posedge clk);
    endtask

    task automatic build_base(input bit vlan, input logic [31:0] magic);
        int po;
        for (int i = 0; i < 96; i++) fin[i] = 8'(i);     // distinctive pattern
        // ethertype / VLAN tag at bytes 12-13 (IPv4)
        if (vlan) begin fin[12] = 8'h81; fin[13] = 8'h00; end
        else      begin fin[12] = 8'h08; fin[13] = 8'h00; end
        po = vlan ? 46 : 42;                              // test payload start
        fin[po+0] = magic[31:24]; fin[po+1] = magic[23:16];
        fin[po+2] = magic[15:8];  fin[po+3] = magic[7:0];
        for (int i = 0; i < 8; i++) fin[po + 20 + i] = 8'hEE;  // ts field sentinel
    endtask

    // IPv6 partial UDP checksum over fin[] (matches pw_flow_gen_multi): pseudo-
    // header (src@22, dst@38, ulen, nh=17) + UDP hdr (csum=0) + payload@62 minus
    // the 8-byte tx_ts (words 10..13). Raw ~sum (no 0xFFFF rule).
    function automatic logic [15:0] partial6();
        logic [31:0] s; logic [15:0] ulen; s = 0;
        ulen = {fin[58], fin[59]};
        for (int w = 0; w < 8; w++) s += {fin[22 + w*2], fin[23 + w*2]};   // src
        for (int w = 0; w < 8; w++) s += {fin[38 + w*2], fin[39 + w*2]};   // dst
        s += {16'b0, ulen};                                                // upper-layer length
        s += 32'h0000_0011;                                                // next-header 17
        s += {fin[54], fin[55]} + {fin[56], fin[57]} + {16'b0, ulen};      // UDP hdr (csum 0)
        for (int w = 0; w < 16; w++)                                       // payload minus tx_ts
            if (w < 10 || w > 13) s += {fin[62 + w*2], fin[63 + w*2]};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return ~s[15:0];
    endfunction

    // Build an IPv6 test frame: ethertype 0x86DD, nh=17, UDP length 40, partial
    // checksum at bytes 60..61, tx_ts sentinel at 82..89.
    task automatic build_v6();
        logic [15:0] c;
        for (int i = 0; i < 96; i++) fin[i] = 8'(i);
        fin[12] = 8'h86; fin[13] = 8'hDD;                 // ethertype IPv6
        fin[20] = 8'd17;                                  // next-header UDP
        fin[58] = 8'h00; fin[59] = 8'h28;                 // UDP length = 40
        fin[62] = 8'hA5; fin[63] = 8'h02; fin[64] = 8'h7E; fin[65] = 8'h57;  // magic
        for (int i = 0; i < 8; i++) fin[82 + i] = 8'hEE;  // tx_ts sentinel
        c = partial6();
        fin[60] = c[15:8]; fin[61] = c[7:0];              // partial csum field
    endtask

    // Validate the FULL UDP checksum over an output frame (incl the csum field
    // @60 and the now-stamped tx_ts @82): a valid frame folds to 0xFFFF.
    function automatic logic full6_ok(input logic [7:0] f [96]);
        logic [31:0] s; logic [15:0] ulen; s = 0;
        ulen = {f[58], f[59]};
        for (int w = 0; w < 8; w++) s += {f[22 + w*2], f[23 + w*2]};
        for (int w = 0; w < 8; w++) s += {f[38 + w*2], f[39 + w*2]};
        s += {16'b0, ulen};
        s += 32'h0000_0011;
        for (int w = 0; w < 4; w++) s += {f[54 + w*2], f[55 + w*2]};   // UDP hdr incl csum
        for (int w = 0; w < 16; w++) s += {f[62 + w*2], f[63 + w*2]};  // full payload incl ts
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return (s[15:0] == 16'hFFFF);
    endfunction

    initial begin
        ts_now = 0; s_td = 0; s_tk = 0; s_tv = 0; s_tl = 0; s_tu = 0; m_tr = 0;
        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---- 1: IPv4 no-VLAN test packet -> ts at 62..69 overwritten ----
        build_base(0, 32'hA5027E57);
        run_frame(64'h1122_3344_5566_7788, 1'b0);   // IPv4 keys on magic, not tuser
        chk("nv ts[62]", fout[62], 8'h11); chk("nv ts[63]", fout[63], 8'h22);
        chk("nv ts[64]", fout[64], 8'h33); chk("nv ts[65]", fout[65], 8'h44);
        chk("nv ts[66]", fout[66], 8'h55); chk("nv ts[67]", fout[67], 8'h66);
        chk("nv ts[68]", fout[68], 8'h77); chk("nv ts[69]", fout[69], 8'h88);
        chk("nv pre  [61] untouched", fout[61], fin[61]);
        chk("nv post [70] untouched", fout[70], fin[70]);
        chk("nv magic[42] untouched", fout[42], 8'hA5);

        // ---- 2: IPv4 non-test packet (wrong magic) -> unchanged ----
        build_base(0, 32'hDEADBEEF);
        run_frame(64'hAAAA_AAAA_AAAA_AAAA, 1'b0);
        chk("non-test ts[62] kept", fout[62], 8'hEE);
        chk("non-test ts[69] kept", fout[69], 8'hEE);

        // ---- 3: IPv4 VLAN test packet -> ts at 66..73 overwritten ----
        build_base(1, 32'hA5027E57);
        run_frame(64'hDEAD_BEEF_CAFE_F00D, 1'b0);
        chk("vl ts[66]", fout[66], 8'hDE); chk("vl ts[67]", fout[67], 8'hAD);
        chk("vl ts[68]", fout[68], 8'hBE); chk("vl ts[69]", fout[69], 8'hEF);
        chk("vl ts[70]", fout[70], 8'hCA); chk("vl ts[71]", fout[71], 8'hFE);
        chk("vl ts[72]", fout[72], 8'hF0); chk("vl ts[73]", fout[73], 8'h0D);
        chk("vl pre [65] untouched", fout[65], fin[65]);

        // ---- 4: IPv6 generator frame (tuser=1) -> ts@82 + csum@60 fixed ----
        build_v6();
        run_frame(64'h0102_0304_0506_0708, 1'b1);
        chk("v6 ts[82]", fout[82], 8'h01); chk("v6 ts[83]", fout[83], 8'h02);
        chk("v6 ts[84]", fout[84], 8'h03); chk("v6 ts[85]", fout[85], 8'h04);
        chk("v6 ts[86]", fout[86], 8'h05); chk("v6 ts[87]", fout[87], 8'h06);
        chk("v6 ts[88]", fout[88], 8'h07); chk("v6 ts[89]", fout[89], 8'h08);
        chk("v6 magic[62] untouched", fout[62], 8'hA5);
        chk1("v6 finalized UDP checksum valid", full6_ok(fout));
        // the csum field actually changed from the partial value
        if (fout[60] === fin[60] && fout[61] === fin[61]) begin
            $display("[FAIL] v6 csum field not updated"); errors++;
        end

        // ---- 5: IPv6 forwarded frame (tuser=0) -> untouched ----
        build_v6();
        run_frame(64'hCAFE_BABE_DEAD_F00D, 1'b0);
        chk("fwd6 ts[82] kept", fout[82], 8'hEE);
        chk("fwd6 ts[89] kept", fout[89], 8'hEE);
        chk("fwd6 csum[60] kept", fout[60], fin[60]);
        chk("fwd6 csum[61] kept", fout[61], fin[61]);

        if (errors == 0) $display("ALL TS_INSERT SCENARIOS PASS");
        else             $display("TS_INSERT FAILURES: %0d", errors);
        $finish;
    end
    initial begin #30000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
