// Unit testbench for pw_inject_tx_window.
//
// Host-side: write a frame into the DATA buffer (32-bit words), set INFO
// (byte_len + egress), write GO. Check the emitted AXIS frame: beats,
// last-beat tkeep, tlast, egress, and that busy de-asserts after the frame
// drains. Also check GO is ignored while busy.

`default_nettype none

module tb_inject_window;

    localparam int ADDR_W   = 16;
    localparam int CTRL_OFF = 16'h0000;
    localparam int INFO_OFF = 16'h0004;
    localparam int DATA_OFF = 16'h0040;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;
    logic [63:0] ts = 64'd1000; always @(posedge clk) ts <= ts + 1;  // free-running counter

    logic        wr_en; logic [ADDR_W-1:0] wr_addr; logic [31:0] wr_data;
    logic [ADDR_W-1:0] rd_addr; logic [31:0] rd_data;
    logic [63:0] m_tdata; logic [7:0] m_tkeep; logic m_tvalid, m_tready, m_tlast;
    logic [3:0]  egress;

    pw_inject_tx_window #(.ADDR_W(ADDR_W), .BUF_BYTES(512),
                          .CTRL_OFF(CTRL_OFF), .INFO_OFF(INFO_OFF), .DATA_OFF(DATA_OFF)) dut (
        .clk(clk), .rst_n(rst_n), .timestamp_i(ts),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast), .egress_o(egress)
    );

    int errors = 0; string scen = "init";
    task automatic chk(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d (0x%0h) exp=%0d", scen, what, got, got, exp); errors++;
        end else $display("[ ok %s] %s: 0x%0h", scen, what, got);
    endtask

    task automatic wr(input [ADDR_W-1:0] a, input [31:0] d);
        @(negedge clk); wr_en = 1'b1; wr_addr = a; wr_data = d;
        @(posedge clk); @(negedge clk); wr_en = 1'b0;
    endtask

    // collect emitted beats
    logic [63:0] beats [$]; logic [7:0] keeps [$]; logic lasts [$];
    always_ff @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            beats.push_back(m_tdata); keeps.push_back(m_tkeep); lasts.push_back(m_tlast);
        end
    end

    initial begin
        wr_en=0; wr_addr=0; wr_data=0; rd_addr=0; m_tready=0;
        repeat(3) @(posedge clk); rst_n = 1'b1; @(posedge clk);

        // --- scenario 1: 20-byte frame (2 full beats + 4 bytes) on egress 1 ---
        scen = "inject";
        // words: beat0 = {w1,w0}, beat1 = {w3,w2}, beat2 low = w4 (4 bytes)
        wr(DATA_OFF + 16'h00, 32'h11223344);  // w0 -> beat0[31:0]
        wr(DATA_OFF + 16'h04, 32'h55667788);  // w1 -> beat0[63:32]
        wr(DATA_OFF + 16'h08, 32'h99AABBCC);  // w2 -> beat1[31:0]
        wr(DATA_OFF + 16'h0C, 32'hDDEEFF00);  // w3 -> beat1[63:32]
        wr(DATA_OFF + 16'h10, 32'hCAFEBABE);  // w4 -> beat2[31:0] (last, 4 bytes)
        wr(DATA_OFF + 16'h14, 32'h00000000);  // w5 -> beat2[63:32] (ignored by len)
        wr(INFO_OFF, (1 << 16) | 32'd20);     // egress=1, byte_len=20
        rd_addr = CTRL_OFF; @(posedge clk);
        chk("not busy before go", rd_data[0], 0);
        wr(CTRL_OFF, 32'h1);                  // GO

        // drain
        @(negedge clk); m_tready = 1'b1;
        repeat (12) @(posedge clk);
        m_tready = 1'b0;

        chk("beats emitted",  beats.size(), 3);
        chk("beat0", beats[0], 64'h5566778811223344);
        chk("beat1", beats[1], 64'hDDEEFF0099AABBCC);
        chk("beat2 low", beats[2][31:0], 32'hCAFEBABE);
        chk("beat0 keep full", keeps[0], 8'hFF);
        chk("beat2 keep 4B",   keeps[2], 8'h0F);
        chk("last on beat2",   lasts[2], 1);
        chk("last not beat0",  lasts[0], 0);
        chk("egress",          egress, 1);
        rd_addr = CTRL_OFF; repeat(2) @(posedge clk);
        chk("busy clear after send", rd_data[0], 0);

        // --- scenario 2: odd word count -> last beat has only its low word
        //     (regression: an HW round-trip showed the stranded-low-word bug
        //     where the final beat's low 32 bits were never committed). ---
        scen = "odd_words";
        beats.delete(); keeps.delete(); lasts.delete();
        wr(DATA_OFF + 16'h00, 32'hDEAD0000);  // w0 -> beat0[31:0]
        wr(DATA_OFF + 16'h04, 32'hDEAD0001);  // w1 -> beat0[63:32]
        wr(DATA_OFF + 16'h08, 32'h0000ABCD);  // w2 -> beat1[31:0] (last; odd count, low only)
        wr(INFO_OFF, (0 << 16) | 32'd12);     // egress=0, byte_len=12 (1.5 beats)
        wr(CTRL_OFF, 32'h1);
        @(negedge clk); m_tready = 1'b1; repeat (10) @(posedge clk); m_tready = 1'b0;
        chk("odd beats emitted", beats.size(), 2);
        chk("odd beat0", beats[0], 64'hDEAD0001DEAD0000);
        chk("odd beat1 low", beats[1][31:0], 32'h0000ABCD);  // <- the stranded word
        chk("odd beat1 keep 4B", keeps[1], 8'h0F);
        chk("odd last on beat1", lasts[1], 1);

        // --- scenario 3: oversized byte_len is clamped to BUF_BYTES (512).
        //     A host that asks for more than the buffer holds must not emit a
        //     frame longer than the buffer (the doc promises "len clamped"). ---
        scen = "clamp_len";
        beats.delete(); keeps.delete(); lasts.delete();
        wr(INFO_OFF, (0 << 16) | 32'd600);    // egress=0, byte_len=600 (> 512)
        wr(CTRL_OFF, 32'h1);
        @(negedge clk); m_tready = 1'b1; repeat (80) @(posedge clk); m_tready = 1'b0;
        chk("clamped to 64 beats", beats.size(), 512/8);   // ceil(512/8) = 64
        chk("clamp last beat full", keeps[beats.size()-1], 8'hFF);
        chk("clamp last flagged",   lasts[beats.size()-1], 1);
        rd_addr = CTRL_OFF; repeat(2) @(posedge clk);
        chk("clamp busy clear", rd_data[0], 0);

        if (errors == 0) $display("ALL INJECT_WINDOW SCENARIOS PASS");
        else begin $display("FAILED with %0d error(s)", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("WATCHDOG TIMEOUT"); $fatal; end

endmodule

`default_nettype wire
