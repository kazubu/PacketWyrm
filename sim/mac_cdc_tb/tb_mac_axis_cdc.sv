// Unit testbench: pw_mac_axis_cdc TX-FIFO soft flush.
//
// Proves the DP_RESET egress-recovery path: a frame sitting in the MAC-TX
// FIFO while the MAC read side is stalled is DISCARDED by the soft flush
// (tx_soft_flush_dp + tx_soft_flush_mac), and the FIFO immediately accepts +
// forwards fresh traffic afterwards. The control scenario (no flush) shows the
// same frames drain normally once the MAC accepts again -- so a passing flush
// scenario can only mean the flush actually reset the FIFO, not that the stall
// was self-clearing. (The true HW wedge is a stuck pointer; sim can't corrupt
// pointers, but it CAN prove the flush mechanism re-zeros the FIFO.)
`default_nettype none

module tb_mac_axis_cdc;
    localparam int PORTS = 1, DATA_W = 64, DEPTH = 2048;

    logic dp_clk = 0, tx_clk = 0, rx_clk = 0;
    always #5  dp_clk = ~dp_clk;   // ~100 MHz
    always #6  tx_clk = ~tx_clk;   // independent (exercise CDC)
    always #7  rx_clk = ~rx_clk;
    logic dp_rst = 1, tx_rst = 1, rx_rst = 1;

    // DUT TX-side drive (dp_clk write) / MAC-side observe (tx_clk read).
    logic [63:0] dptx_d [PORTS]; logic [7:0] dptx_k [PORTS];
    logic dptx_v [PORTS], dptx_l [PORTS], dptx_u [PORTS]; logic dptx_r [PORTS];
    logic [63:0] mactx_d [PORTS]; logic [7:0] mactx_k [PORTS];
    logic mactx_v [PORTS], mactx_l [PORTS], mactx_u [PORTS]; logic mactx_r [PORTS];

    // RX side tied off (not under test).
    logic [63:0] macrx_d [PORTS] = '{default:'0}; logic [7:0] macrx_k [PORTS] = '{default:'0};
    logic macrx_v [PORTS] = '{default:1'b0}, macrx_l [PORTS] = '{default:1'b0}, macrx_u [PORTS] = '{default:1'b0};
    logic [63:0] dprx_d [PORTS]; logic [7:0] dprx_k [PORTS];
    logic dprx_v [PORTS], dprx_l [PORTS], dprx_u [PORTS]; logic dprx_r [PORTS];

    // Drive ONLY the dp_clk soft-flush pulse, exactly as the board top does;
    // the DUT performs the stretch + per-tx_clk CDC internally and exports the
    // synchronized per-port flush level (drives ts_insert reset on the board).
    logic dp_soft_flush = 0; wire tx_soft_flush_o [PORTS];

    wire rx_clk_a [PORTS]; wire tx_clk_a [PORTS]; wire rx_rst_a [PORTS]; wire tx_rst_a [PORTS];
    assign rx_clk_a[0] = rx_clk; assign tx_clk_a[0] = tx_clk;
    assign rx_rst_a[0] = rx_rst; assign tx_rst_a[0] = tx_rst;

    pw_mac_axis_cdc #(.PORTS(PORTS), .DATA_W(DATA_W), .DEPTH(DEPTH)) dut (
        .dp_clk(dp_clk), .dp_rst(dp_rst),
        .rx_clk(rx_clk_a), .rx_rst(rx_rst_a), .tx_clk(tx_clk_a), .tx_rst(tx_rst_a),
        .mac_rx_tdata(macrx_d), .mac_rx_tkeep(macrx_k), .mac_rx_tvalid(macrx_v),
        .mac_rx_tlast(macrx_l), .mac_rx_tuser(macrx_u),
        .mac_tx_tdata(mactx_d), .mac_tx_tkeep(mactx_k), .mac_tx_tvalid(mactx_v),
        .mac_tx_tready(mactx_r), .mac_tx_tlast(mactx_l), .mac_tx_tuser(mactx_u),
        .dp_rx_tdata(dprx_d), .dp_rx_tkeep(dprx_k), .dp_rx_tvalid(dprx_v),
        .dp_rx_tready(dprx_r), .dp_rx_tlast(dprx_l), .dp_rx_tuser(dprx_u),
        .dp_tx_tdata(dptx_d), .dp_tx_tkeep(dptx_k), .dp_tx_tvalid(dptx_v),
        .dp_tx_tready(dptx_r), .dp_tx_tlast(dptx_l), .dp_tx_tuser(dptx_u),
        .dp_soft_flush(dp_soft_flush), .tx_soft_flush_o(tx_soft_flush_o)
    );
    assign dprx_r[0] = 1'b1;

    int pass = 0, fail = 0;
    task chk(input string n, input logic c);
        if (c) begin pass++; $display("[ ok ] %s", n); end
        else   begin fail++; $display("[FAIL] %s", n); end
    endtask

    // Count frames (tlast beats) leaving the MAC TX side.
    int mac_frames = 0;
    always_ff @(posedge tx_clk) if (mactx_v[0] && mactx_r[0] && mactx_l[0]) mac_frames++;

    // Observe that the dp_clk pulse actually reaches the tx_clk domain via the
    // DUT's internal stretch + 3-FF synchroniser (this drives ts_insert reset).
    logic flush_seen_tx = 0;
    always_ff @(posedge tx_clk) if (tx_soft_flush_o[0]) flush_seen_tx <= 1'b1;

    // MAC-TX output beat capture: verify a frame is byte-correct (matches
    // push_frame's seed^beat pattern) and count accepted beats. All counters are
    // written ONLY here (no mixed blocking/NBA race); the test arms via arm_req.
    logic [7:0] exp_seed = 8'h00;
    logic       arm_req  = 1'b0;
    int  beat_idx = 0, beats_seen = 0, beat_errs = 0;
    always_ff @(posedge tx_clk) begin
        if (arm_req) begin
            beat_idx <= 0; beats_seen <= 0; beat_errs <= 0;
        end else if (mactx_v[0] && mactx_r[0]) begin
            if (mactx_d[0] != ({8{exp_seed}} ^ {56'd0, 8'(beat_idx[7:0])})) beat_errs <= beat_errs + 1;
            beats_seen <= beats_seen + 1;
            beat_idx   <= mactx_l[0] ? 0 : beat_idx + 1;
        end
    end
    task automatic arm_capture(input logic [7:0] s);
        // Drive on negedge so arm_req/exp_seed are stable at the posedge the
        // capture always_ff samples (no posedge-edge race; portable).
        @(negedge tx_clk); exp_seed = s; arm_req = 1'b1;
        @(negedge tx_clk); arm_req = 1'b0;
    endtask
    // Single dp_clk flush pulse (no settle wait) -- for overlapping flushes.
    task automatic flush_pulse();
        @(negedge dp_clk); dp_soft_flush = 1'b1;
        @(negedge dp_clk); dp_soft_flush = 1'b0;
    endtask

    // Push one 4-beat frame into the dp_tx (write) side, byte-tagged by `seed`.
    // Drive on negedge (stable at the posedge the DUT samples) and present each
    // beat EXACTLY once: holding the same beat across the next iteration's edge
    // would let the FIFO accept it twice (a stimulus bug, not the DUT).
    task automatic push_frame(input logic [7:0] seed);
        for (int b = 0; b < 4; b++) begin
            @(negedge dp_clk);
            dptx_d[0] = {8{seed}} ^ {56'd0, 8'(b)};
            dptx_k[0] = 8'hFF; dptx_u[0] = 1'b0;
            dptx_l[0] = (b == 3); dptx_v[0] = 1'b1;
            @(posedge dp_clk);                       // beat sampled here
            while (!dptx_r[0]) begin @(negedge dp_clk); @(posedge dp_clk); end
        end
        @(negedge dp_clk); dptx_v[0] = 1'b0; dptx_l[0] = 1'b0;
    endtask

    // Wait until mac_frames reaches `target` (or timeout tx_clk cycles).
    task automatic wait_frames(input int target, input int timeout);
        int w; w = 0;
        while (mac_frames < target && w < timeout) begin @(posedge tx_clk); w++; end
    endtask
    // Quiesce: let any in-flight frame finish, then zero the counter.
    task automatic settle_and_clear();
        repeat (300) @(posedge tx_clk);
        mac_frames = 0;
    endtask

    task automatic do_flush();
        // One dp_clk pulse, exactly like the board. The DUT stretches it and
        // CDCs the level into each tx_clk; wait out the stretch + sync + drain.
        // Drive on negedge so the level is stable at the posedge the DUT's
        // always_ff samples (no posedge-edge race; portable across simulators).
        @(negedge dp_clk); dp_soft_flush = 1'b1;
        @(negedge dp_clk); dp_soft_flush = 1'b0;
        repeat (60) @(posedge dp_clk);
        repeat (60) @(posedge tx_clk);
    endtask

    initial begin
        dptx_v[0] = 0; dptx_l[0] = 0; dptx_u[0] = 0; dptx_d[0] = '0; dptx_k[0] = '0;
        mactx_r[0] = 1'b0;                       // MAC read side stalled to start
        repeat (10) @(posedge dp_clk);
        dp_rst = 0; @(posedge tx_clk); tx_rst = 0; @(posedge rx_clk); rx_rst = 0;
        repeat (20) @(posedge dp_clk);

        // ---- Scenario 1: flush discards a stalled frame ----
        // MAC stalled; push a full frame -> it commits into the TX FIFO.
        push_frame(8'hA1);
        repeat (60) @(posedge tx_clk);
        chk("stalled frame did not leave MAC (read side held)", mac_frames == 0);

        // Flush the TX FIFO; then let the MAC accept.
        do_flush();
        chk("dp pulse reached tx_clk via internal stretch+CDC", flush_seen_tx == 1'b1);
        mactx_r[0] = 1'b1;
        repeat (400) @(posedge tx_clk);
        chk("flush DISCARDED the stalled frame (0 frames out)", mac_frames == 0);

        // FIFO must be healthy: a fresh frame flows straight through.
        push_frame(8'hB2);
        wait_frames(1, 1000);
        chk("post-flush fresh frame transmitted (exactly 1)", mac_frames == 1);

        // ---- Scenario 2 (control): no flush -> stalled frame drains ----
        settle_and_clear();
        mactx_r[0] = 1'b0;                       // stall again
        push_frame(8'hC3);
        repeat (60) @(posedge tx_clk);
        chk("control: stalled frame held (0 out)", mac_frames == 0);
        mactx_r[0] = 1'b1;                       // release WITHOUT flush
        wait_frames(1, 1000);
        chk("control: without flush the frame DRAINS (1 out)", mac_frames == 1);

        // ---- Scenario 3: flush discards MULTIPLE stalled frames ----
        settle_and_clear();
        mactx_r[0] = 1'b0;                       // stall
        push_frame(8'hD4); push_frame(8'hD5);    // two frames committed while stalled
        repeat (60) @(posedge tx_clk);
        chk("two stalled frames held (0 out)", mac_frames == 0);
        do_flush();
        mactx_r[0] = 1'b1;
        repeat (400) @(posedge tx_clk);
        chk("flush DISCARDED both stalled frames (0 out)", mac_frames == 0);
        push_frame(8'hE5);
        wait_frames(1, 1000);
        chk("recovers after multi-frame flush (exactly 1)", mac_frames == 1);

        // ---- Scenario 4: OVERLAPPING consecutive DP_RESET (2nd within 1st) ----
        // The second pulse arrives while the first's stretch is still active
        // (reloading the counter) -- a true back-to-back, not two settled flushes.
        settle_and_clear();
        mactx_r[0] = 1'b0;
        push_frame(8'h44);
        flush_pulse();                           // 1st pulse -> ~24-cycle stretch
        repeat (6) @(posedge dp_clk);            // still mid-stretch
        flush_pulse();                           // 2nd pulse DURING the 1st
        repeat (60) @(posedge dp_clk); repeat (60) @(posedge tx_clk);
        mactx_r[0] = 1'b1;
        repeat (400) @(posedge tx_clk);
        chk("overlapping consecutive flush: frame discarded (0 out)", mac_frames == 0);
        arm_capture(8'h45);
        push_frame(8'h45);
        wait_frames(1, 1000);
        chk("recovers after overlapping flush (exactly 1, byte-correct)",
            mac_frames == 1 && beats_seen == 4 && beat_errs == 0);

        // ---- Scenario 5: flush MID-HANDSHAKE (old tlast suppressed) ----
        // Drain 2 beats of the old frame to the MAC, PAUSE (so it can't finish
        // while the flush propagates), flush the half-emitted frame, and verify:
        // (a) its tlast never appears (truncated), (b) the next frame is complete
        // AND byte-perfect (every beat = seed^beat). This is the wedge-recovery
        // case that actually matters on the wire.
        settle_and_clear();
        mactx_r[0] = 1'b0;
        push_frame(8'h66);                       // old frame fully buffered
        arm_capture(8'h66);
        mactx_r[0] = 1'b1;                        // start draining to the MAC
        wait (beats_seen >= 2);                  // 2 beats out, no tlast yet
        mactx_r[0] = 1'b0;                        // pause so it can't complete
        flush_pulse();                           // flush the half-emitted frame
        repeat (60) @(posedge dp_clk); repeat (60) @(posedge tx_clk);
        chk("mid-handshake flush: old frame truncated (no tlast)", mac_frames == 0);
        mactx_r[0] = 1'b1;
        repeat (200) @(posedge tx_clk);
        chk("mid-handshake flush: old frame still never completes", mac_frames == 0);
        arm_capture(8'h77);
        push_frame(8'h77);
        wait_frames(1, 1000);
        chk("post-flush fresh frame complete + byte-correct (4 beats, 0 errs)",
            mac_frames == 1 && beats_seen == 4 && beat_errs == 0);

        $display("mac_axis_cdc: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("ALL MAC_AXIS_CDC SCENARIOS PASS");
        else           $display("SOME MAC_AXIS_CDC SCENARIOS FAILED");
        $finish;
    end

    // Watchdog.
    initial begin #500000; $display("[FAIL] timeout"); $finish; end
endmodule

`default_nettype wire
