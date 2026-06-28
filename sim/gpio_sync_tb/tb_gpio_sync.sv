// Unit testbench for pw_gpio_sync: the J5 GPIO cross-card time-sync block.
// Verifies slave capture (latch the free-running counter at the sync-in rising
// edge + bump the sequence), master pulse generation + self-capture, the
// drive/hi-Z (gpio_t) discipline, and the repeater forward.
`default_nettype none

module tb_gpio_sync;
    localparam int NGPIO = 6;
    logic clk = 0; always #5 clk = ~clk;     // 100 MHz sim clock (period 10)
    logic rst_n = 0;

    logic [63:0] ts = 0;                      // stand-in free-running counter
    always_ff @(posedge clk) ts <= ts + 1'b1;

    logic [NGPIO-1:0] gpio_i = '0, gpio_o, gpio_t;
    logic [31:0]      ctrl = '0;
    logic [63:0]      sync_ts;
    logic [31:0]      sync_seq;
    logic [NGPIO-1:0] gpio_in;

    pw_gpio_sync #(.NGPIO(NGPIO)) dut (
        .clk(clk), .rst_n(rst_n), .timestamp_i(ts),
        .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_t(gpio_t),
        .ctrl_i(ctrl),
        .sync_ts_o(sync_ts), .sync_seq_o(sync_seq), .gpio_in_o(gpio_in)
    );

    int errors = 0;
    task automatic chk(string n, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s got=%0d exp=%0d", n, got, exp); errors++; end
        else $display("[ ok ] %s = %0d", n, got);
    endtask
    task automatic chkb(string n, logic c);
        if (c) $display("[ ok ] %s", n); else begin $display("[FAIL] %s", n); errors++; end
    endtask

    // ctrl field packer
    function automatic logic [31:0] mkctrl(bit en, bit master, bit rep,
                                           int in_sel, int out_sel, int per_log2);
        return {12'h0, per_log2[3:0], 5'h0, out_sel[2:0], 1'b0, in_sel[2:0],
                1'b0, rep, master, en};
    endfunction

    initial begin
        repeat (4) @(posedge clk); rst_n = 1; @(negedge clk);

        // ===== SLAVE: capture the counter at a sync-in rising edge =====
        // in_sel=2, out_sel=3, slave (not master), enabled.
        ctrl = mkctrl(1, 0, 0, /*in*/2, /*out*/3, 0);
        @(negedge clk);
        chk("slave seq starts 0", sync_seq, 0);
        // only the sync-out pin is driven; all others hi-Z
        chkb("out pin driven (t=0)",  gpio_t[3] == 1'b0);
        chkb("in  pin hi-Z (t=1)",    gpio_t[2] == 1'b1);
        chkb("other pin hi-Z (t=1)",  gpio_t[0] == 1'b1);

        // drive a clean pulse on gpio_i[2]; expect ONE capture on the rising edge
        @(negedge clk); gpio_i[2] = 1'b1;
        // wait for the 2-FF sync (2) + edge-detect (1) to land the capture
        repeat (6) @(posedge clk);
        chk("slave captured once", sync_seq, 1);
        chkb("slave latched a plausible ts", sync_ts > 0 && sync_ts < ts);
        // holding the level high must NOT re-capture (edge, not level)
        repeat (10) @(posedge clk);
        chk("no re-capture on level", sync_seq, 1);
        // a second pulse -> second capture
        @(negedge clk); gpio_i[2] = 1'b0; repeat (4) @(posedge clk);
        @(negedge clk); gpio_i[2] = 1'b1; repeat (6) @(posedge clk);
        chk("slave second capture", sync_seq, 2);
        gpio_i[2] = 1'b0;

        // ===== MASTER: generate a periodic pulse + self-capture =====
        // small period (2^4 = 16 cycles) so the test runs quickly. out_sel=1.
        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(negedge clk);
        ctrl = mkctrl(1, 1, 0, /*in*/0, /*out*/1, /*per_log2*/4);
        // observe the sync-out pin pulse and the self-capture sequence advance
        begin
            int seen_high = 0; longint seq0;
            seq0 = sync_seq;
            for (int i = 0; i < 200; i++) begin
                @(posedge clk);
                if (gpio_o[1]) seen_high++;
            end
            chkb("master drove sync-out high", seen_high > 0);
            chkb("master self-captured edges", sync_seq > seq0);
            chkb("master out pin driven",      gpio_t[1] == 1'b0);
        end

        // ===== REPEATER: forward an incoming edge out the sync-out pin =====
        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(negedge clk);
        ctrl = mkctrl(1, 0, /*rep*/1, /*in*/2, /*out*/3, 0);
        @(negedge clk); gpio_i[2] = 1'b1;
        begin
            int fwd = 0;
            for (int i = 0; i < 24; i++) begin @(posedge clk); if (gpio_o[3]) fwd++; end
            chkb("repeater forwarded edge to sync-out", fwd > 0);
        end
        gpio_i[2] = 1'b0;

        if (errors == 0) $display("ALL GPIO_SYNC SCENARIOS PASS");
        else             $display("FAILED with %0d error(s)", errors);
        $finish;
    end
    initial begin #100000; $display("WATCHDOG"); $fatal; end
endmodule
`default_nettype wire
