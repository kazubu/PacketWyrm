// Testbench for pw_ts_insert: egress tx_timestamp overwrite.
// Builds synthetic frames matching the generator layout and checks:
//   - a test packet (no-VLAN) gets bytes 62..69 overwritten with the
//     SOF-latched timestamp (big-endian), other bytes untouched;
//   - a VLAN test packet gets bytes 66..73 overwritten;
//   - a non-test packet (wrong magic) passes through unchanged.

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

    logic [7:0] fin  [96];
    logic [7:0] fout [96];

    // Drive a 96-byte frame, capture the (overwritten) output bytes.
    task automatic run_frame(input logic [63:0] tsv);
        int beats = 12;   // 96 bytes / 8
        ts_now = tsv;
        m_tr   = 1'b1;
        // Drive inputs on negedge so the DUT's beat counter (incremented on
        // posedge as each beat is accepted) aligns with the data presented.
        for (int b = 0; b < beats; b++) begin
            @(negedge clk);
            for (int l = 0; l < 8; l++) s_td[l*8 +: 8] = fin[b*8 + l];
            s_tv = 1'b1; s_tk = 8'hFF; s_tl = (b == beats - 1); s_tu = 1'b0;
            #1;  // combinational overwrite settles; beat_reg == b
            for (int l = 0; l < 8; l++) fout[b*8 + l] = m_td[l*8 +: 8];
        end
        @(negedge clk); s_tv = 1'b0; s_tl = 1'b0;
        @(posedge clk);
    endtask

    task automatic build_base(input bit vlan, input logic [31:0] magic);
        int po;
        for (int i = 0; i < 96; i++) fin[i] = 8'(i);     // distinctive pattern
        // ethertype / VLAN tag at bytes 12-13
        if (vlan) begin fin[12] = 8'h81; fin[13] = 8'h00; end
        else      begin fin[12] = 8'h08; fin[13] = 8'h00; end
        po = vlan ? 46 : 42;                              // test payload start
        fin[po+0] = magic[31:24]; fin[po+1] = magic[23:16];
        fin[po+2] = magic[15:8];  fin[po+3] = magic[7:0];
        for (int i = 0; i < 8; i++) fin[po + 20 + i] = 8'hEE;  // ts field sentinel
    endtask

    initial begin
        ts_now = 0; s_td = 0; s_tk = 0; s_tv = 0; s_tl = 0; s_tu = 0; m_tr = 0;
        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---- 1: no-VLAN test packet -> ts at 62..69 overwritten ----
        build_base(0, 32'hA5027E57);
        run_frame(64'h1122_3344_5566_7788);
        chk("nv ts[62]", fout[62], 8'h11); chk("nv ts[63]", fout[63], 8'h22);
        chk("nv ts[64]", fout[64], 8'h33); chk("nv ts[65]", fout[65], 8'h44);
        chk("nv ts[66]", fout[66], 8'h55); chk("nv ts[67]", fout[67], 8'h66);
        chk("nv ts[68]", fout[68], 8'h77); chk("nv ts[69]", fout[69], 8'h88);
        chk("nv pre  [61] untouched", fout[61], fin[61]);
        chk("nv post [70] untouched", fout[70], fin[70]);
        chk("nv magic[42] untouched", fout[42], 8'hA5);

        // ---- 2: non-test packet (wrong magic) -> unchanged ----
        build_base(0, 32'hDEADBEEF);
        run_frame(64'hAAAA_AAAA_AAAA_AAAA);
        chk("non-test ts[62] kept", fout[62], 8'hEE);
        chk("non-test ts[69] kept", fout[69], 8'hEE);

        // ---- 3: VLAN test packet -> ts at 66..73 overwritten ----
        build_base(1, 32'hA5027E57);
        run_frame(64'hDEAD_BEEF_CAFE_F00D);
        chk("vl ts[66]", fout[66], 8'hDE); chk("vl ts[67]", fout[67], 8'hAD);
        chk("vl ts[68]", fout[68], 8'hBE); chk("vl ts[69]", fout[69], 8'hEF);
        chk("vl ts[70]", fout[70], 8'hCA); chk("vl ts[71]", fout[71], 8'hFE);
        chk("vl ts[72]", fout[72], 8'hF0); chk("vl ts[73]", fout[73], 8'h0D);
        chk("vl pre [65] untouched", fout[65], fin[65]);

        if (errors == 0) $display("ALL TS_INSERT SCENARIOS PASS");
        else             $display("TS_INSERT FAILURES: %0d", errors);
        $finish;
    end
    initial begin #20000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
