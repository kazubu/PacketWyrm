// Unit testbench for pw_frame_saf (store-and-forward frame buffer).
//
// Checks: keep -> frame drains out identical with its route tag; discard
// -> nothing drains; two keep frames drain in FIFO order; an oversized
// keep frame overflows -> dropped whole, overflow_drop pulses, nothing
// of it drains.

`default_nettype none

module tb_frame_saf;

    localparam int DEPTH = 16;     // small, to exercise overflow
    localparam int RW    = 5;
    localparam int MW    = 36;     // metadata width (matches data plane)

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic [63:0] s_tdata; logic [7:0] s_tkeep; logic s_tvalid, s_tlast;
    logic        dec_valid, dec_keep; logic [RW-1:0] dec_route; logic [MW-1:0] dec_meta;
    logic        ovf;
    logic [63:0] m_tdata; logic [7:0] m_tkeep; logic m_tvalid, m_tready, m_tlast;
    logic [RW-1:0] m_route; logic [MW-1:0] m_meta;

    pw_frame_saf #(.DEPTH_BEATS(DEPTH), .DESC_DEPTH(4), .ROUTE_W(RW), .META_W(MW)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tlast(s_tlast),
        .dec_valid_i(dec_valid), .dec_keep_i(dec_keep), .dec_route_i(dec_route),
        .dec_meta_i(dec_meta),
        .overflow_drop_o(ovf),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast), .m_route(m_route), .m_meta(m_meta)
    );

    int errors = 0;
    string scen = "init";
    task automatic chk(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d exp=%0d", scen, what, got, exp); errors++;
        end else $display("[ ok %s] %s: %0d", scen, what, got);
    endtask

    // overflow sticky capture
    logic ovf_seen;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) ovf_seen <= 1'b0; else if (ovf) ovf_seen <= 1'b1;

    // drain collector
    logic [63:0] drained_data [$];
    logic [RW-1:0] drained_route [$];
    logic [MW-1:0] drained_meta [$];
    logic          drained_last [$];
    always_ff @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            drained_data.push_back(m_tdata);
            drained_route.push_back(m_route);
            drained_meta.push_back(m_meta);
            drained_last.push_back(m_tlast);
        end
    end

    // Send a frame of `n` beats, beat i carries {fid, i}. Then pulse the
    // decision exactly one cycle after tlast (per the SAF timing contract).
    task automatic send_frame(input int n, input logic [31:0] fid,
                              input logic keep, input logic [RW-1:0] route);
        for (int i = 0; i < n; i++) begin
            @(negedge clk);
            s_tvalid = 1'b1;
            s_tdata  = {fid, 32'(i)};
            s_tkeep  = 8'hFF;
            s_tlast  = (i == n - 1);
            @(posedge clk);
        end
        @(negedge clk);
        s_tvalid = 1'b0; s_tlast = 1'b0;
        dec_valid = 1'b1; dec_keep = keep; dec_route = route;
        dec_meta  = {4'(route), fid};   // deterministic from frame args
        @(posedge clk);
        @(negedge clk);
        dec_valid = 1'b0;
    endtask

    initial begin
        s_tvalid = 0; s_tlast = 0; s_tdata = 0; s_tkeep = 0;
        dec_valid = 0; dec_keep = 0; dec_route = 0;
        m_tready = 1'b1;       // always drain
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // --- scenario 1: keep one 3-beat frame, route 5 ---
        scen = "keep1";
        send_frame(3, 32'hAA, 1'b1, 5'd5);
        repeat (8) @(posedge clk);
        chk("drained beats", drained_data.size(), 3);
        chk("beat0", drained_data[0], {32'hAA, 32'd0});
        chk("beat2", drained_data[2], {32'hAA, 32'd2});
        chk("route", drained_route[0], 5);
        chk("meta", drained_meta[0], {4'd5, 32'hAA});
        chk("last on beat2", drained_last[2], 1);
        chk("last not on beat0", drained_last[0], 0);
        chk("no overflow", ovf_seen, 0);
        drained_data.delete(); drained_route.delete(); drained_meta.delete(); drained_last.delete();

        // --- scenario 2: discard a frame -> nothing drains ---
        scen = "discard";
        send_frame(2, 32'hBB, 1'b0, 5'd0);
        repeat (8) @(posedge clk);
        chk("discard drains nothing", drained_data.size(), 0);
        chk("no overflow", ovf_seen, 0);

        // --- scenario 3: two keep frames, FIFO order + distinct routes ---
        scen = "two";
        send_frame(2, 32'hC1, 1'b1, 5'd1);
        send_frame(4, 32'hC2, 1'b1, 5'd9);
        repeat (12) @(posedge clk);
        chk("total beats", drained_data.size(), 6);
        chk("f1 beat0", drained_data[0], {32'hC1, 32'd0});
        chk("f1 route", drained_route[0], 1);
        chk("f1 last@1", drained_last[1], 1);
        chk("f2 beat0", drained_data[2], {32'hC2, 32'd0});
        chk("f2 route", drained_route[2], 9);
        chk("f2 last@5", drained_last[5], 1);
        drained_data.delete(); drained_route.delete(); drained_meta.delete(); drained_last.delete();

        // --- scenario 4: oversized keep frame overflows -> dropped whole ---
        scen = "overflow";
        ovf_seen = 1'b0;
        send_frame(DEPTH + 4, 32'hDD, 1'b1, 5'd7);   // > DEPTH beats
        repeat (8) @(posedge clk);
        chk("overflow pulsed", ovf_seen, 1);
        chk("overflow drains nothing", drained_data.size(), 0);

        // --- scenario 5: FIFO recovers after overflow (keep a normal frame) ---
        scen = "recover";
        send_frame(2, 32'hEE, 1'b1, 5'd3);
        repeat (8) @(posedge clk);
        chk("recovered beats", drained_data.size(), 2);
        chk("recovered beat0", drained_data[0], {32'hEE, 32'd0});
        chk("recovered route", drained_route[0], 3);
        drained_data.delete(); drained_route.delete(); drained_meta.delete(); drained_last.delete();

        // --- scenario 6: zero-beat "keep" must NOT push a stuck descriptor ---
        // A dec_keep pulse with no beats written (wr_spec==wr_commit) can only
        // come from a reset-boundary race; it must be treated as a drop (no
        // descriptor), or the drain (rd_ptr already == wr_commit) could never
        // advance it and would wedge. Pulse a bare keep, then send a normal keep
        // frame and confirm it drains cleanly (no stuck 0-beat descriptor ahead).
        scen = "zero_beat_keep";
        @(negedge clk);
        dec_valid = 1'b1; dec_keep = 1'b1; dec_route = 5'd4; dec_meta = '0;   // no beats streamed
        @(posedge clk); @(negedge clk); dec_valid = 1'b0;
        repeat (4) @(posedge clk);
        chk("zero-beat keep drains nothing", drained_data.size(), 0);
        send_frame(2, 32'hAB, 1'b1, 5'd2);
        repeat (8) @(posedge clk);
        chk("next frame still drains (not wedged)", drained_data.size(), 2);
        if (drained_data.size() == 2) begin
            chk("next beat0", drained_data[0], {32'hAB, 32'd0});
            chk("next route", drained_route[0], 2);
        end

        if (errors == 0) $display("ALL FRAME_SAF SCENARIOS PASS");
        else begin $display("FAILED with %0d error(s)", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("WATCHDOG TIMEOUT"); $fatal; end

endmodule

`default_nettype wire
