// Unit testbench for pw_punt_rx_window.
//
// Pushes a punt frame in on the AXIS slave, then drains it via the
// registered CSR read interface (status -> info -> lif -> data words),
// pops it, and checks the slot frees. Also checks tready backpressure
// while a frame is buffered, and the overflow path for an oversized frame.

`default_nettype none

module tb_punt_window;

    localparam int ADDR_W   = 16;
    localparam int BUF_BEATS = 8;          // tiny, to exercise overflow
    localparam int DATA_OFF = 16'h0020;   // production: 0x10/0x14 = RX timestamp

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic [63:0] s_tdata; logic [7:0] s_tkeep; logic s_tvalid, s_tlast;
    logic [99:0] s_tuser; wire s_tready;   // {rx_ts[63:0], ingress[3:0], lif[31:0]}
    logic        rd_en;   logic [ADDR_W-1:0] rd_addr; logic [31:0] rd_data;
    logic        pop;     wire frame_valid;

    pw_punt_rx_window #(.ADDR_W(ADDR_W), .BUF_BEATS(BUF_BEATS), .DATA_OFF(DATA_OFF)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .s_tlast(s_tlast), .s_tuser(s_tuser),
        .rd_en_i(rd_en), .rd_addr_i(rd_addr), .rd_data_o(rd_data),
        .pop_i(pop), .frame_valid_o(frame_valid)
    );

    int errors = 0; string scen = "init";
    task automatic chk(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d (0x%0h) exp=%0d", scen, what, got, got, exp); errors++;
        end else $display("[ ok %s] %s: 0x%0h", scen, what, got);
    endtask

    // Registered read: drive rd_en/addr, sample rd_data the next cycle.
    task automatic rdreg(input [ADDR_W-1:0] a, output [31:0] d);
        @(negedge clk); rd_en = 1'b1; rd_addr = a;
        @(posedge clk); @(negedge clk); rd_en = 1'b0;
        d = rd_data;
    endtask

    task automatic send_beat(input [63:0] data, input [7:0] keep, input logic last);
        @(negedge clk);
        s_tvalid = 1'b1; s_tdata = data; s_tkeep = keep; s_tlast = last;
        @(posedge clk);
        @(negedge clk); s_tvalid = 1'b0; s_tlast = 1'b0;
    endtask

    logic [31:0] d;

    initial begin
        s_tvalid=0; s_tlast=0; s_tdata=0; s_tkeep=0; s_tuser=0;
        rd_en=0; rd_addr=0; pop=0;
        repeat(3) @(posedge clk); rst_n = 1'b1; @(posedge clk);

        // --- scenario 1: push a 2.5-beat frame (20 bytes), drain it ---
        scen = "capture";
        chk("tready idle", s_tready, 1);
        s_tuser = {64'hCAFE_0000_1234_5678, 4'd1, 32'h0000_ABCD};  // rx_ts, ingress 1, lif 0xABCD
        send_beat(64'h1122334455667788, 8'hFF, 1'b0);
        send_beat(64'h99AABBCCDDEEFF00, 8'hFF, 1'b0);
        send_beat(64'h00000000DEADBEEF, 8'h0F, 1'b1);  // 4 valid bytes -> 20 total
        repeat(2) @(posedge clk);

        chk("frame_valid tap", frame_valid, 1);
        rdreg(16'h000, d); chk("STATUS valid",   d[0], 1);
        rdreg(16'h000, d); chk("STATUS no ovf",  d[1], 0);
        rdreg(16'h004, d); chk("INFO byte_len",  d[13:0], 20);
        rdreg(16'h004, d); chk("INFO ingress",   d[19:16], 1);
        rdreg(16'h008, d); chk("LIF",            d, 32'h0000_ABCD);
        rdreg(16'h010, d); chk("RX_TS low",      d, 32'h1234_5678);
        rdreg(16'h014, d); chk("RX_TS high",     d, 32'hCAFE_0000);
        chk("tready backpressured", s_tready, 0);

        // data words (little-endian within each 64-bit beat)
        rdreg(DATA_OFF + 16'h0, d); chk("word0", d, 32'h55667788);
        rdreg(DATA_OFF + 16'h4, d); chk("word1", d, 32'h11223344);
        rdreg(DATA_OFF + 16'h8, d); chk("word2", d, 32'hDDEEFF00);
        rdreg(DATA_OFF + 16'h10,d); chk("word4", d, 32'hDEADBEEF);

        // --- scenario 2: pop frees the slot ---
        scen = "pop";
        @(negedge clk); pop = 1'b1; @(posedge clk); @(negedge clk); pop = 1'b0;
        repeat(2) @(posedge clk);
        chk("frame_valid cleared", frame_valid, 0);
        chk("tready re-armed", s_tready, 1);
        rdreg(16'h000, d); chk("STATUS valid clear", d[0], 0);

        // --- scenario 3: oversized frame (BUF_BEATS+2) -> dropped, overflow ---
        scen = "overflow";
        s_tuser = {4'd0, 32'h0000_0001};
        for (int i = 0; i < BUF_BEATS + 2; i++)
            send_beat(64'h0 + i, 8'hFF, (i == BUF_BEATS + 1));
        repeat(2) @(posedge clk);
        rdreg(16'h000, d); chk("overflow no frame", d[0], 0);
        rdreg(16'h000, d); chk("overflow flag",     d[1], 1);
        chk("tready re-armed after drop", s_tready, 1);

        if (errors == 0) $display("ALL PUNT_WINDOW SCENARIOS PASS");
        else begin $display("FAILED with %0d error(s)", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("WATCHDOG TIMEOUT"); $fatal; end

endmodule

`default_nettype wire
