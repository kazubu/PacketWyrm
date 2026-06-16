// Testbench for pw_icap_reboot: verify the IPROG command stream.
// On a trigger pulse the FSM must drive CSIB low and emit the 9-word
// IPROG sequence (bit-swapped per byte), including the sync and IPROG
// command words, then deselect.

`default_nettype none

module tb_icap_reboot;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;
    logic reboot;
    logic csib, rdwrb, busy;
    logic [31:0] icap_i;

    pw_icap_reboot #(.WBSTAR(32'h0), .ICAP_BITSWAP(1)) dut (
        .clk(clk), .rst_n(rst_n), .reboot_i(reboot),
        .icap_csib(csib), .icap_rdwrb(rdwrb), .icap_i(icap_i), .icap_busy_o(busy)
    );

    function automatic logic [31:0] bswap(input logic [31:0] w);
        logic [31:0] o;
        for (int b = 0; b < 4; b++) for (int i = 0; i < 8; i++) o[b*8+i] = w[b*8+(7-i)];
        return o;
    endfunction

    logic [31:0] cap [16];
    int          ncap = 0;
    // capture words while selected for write
    always @(posedge clk) if (rst_n && !csib && !rdwrb) begin cap[ncap] = icap_i; ncap++; end

    int errors = 0;
    task automatic chk(string w, longint g, longint e);
        if (g !== e) begin $display("[FAIL] %s got=%0h exp=%0h", w, g, e); errors++; end
        else $display("[ ok ] %s = %0h", w, g);
    endtask

    initial begin
        reboot = 0;
        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        // idle: deselected
        chk("idle csib high", csib, 1);
        // trigger
        reboot = 1; @(posedge clk); reboot = 0;
        // run to completion
        repeat (20) @(posedge clk);
        chk("emitted 9 words", ncap, 9);
        chk("word0 dummy",  cap[0], bswap(32'hFFFFFFFF));
        chk("word1 sync",   cap[1], bswap(32'hAA995566));
        chk("word3 wbstar", cap[3], bswap(32'h30020001));
        chk("word4 addr0",  cap[4], bswap(32'h00000000));
        chk("word5 cmd",    cap[5], bswap(32'h30008001));
        chk("word6 IPROG",  cap[6], bswap(32'h0000000F));
        chk("returned idle", csib, 1);
        if (errors == 0) $display("ALL ICAP_REBOOT SCENARIOS PASS");
        else             $display("ICAP_REBOOT FAILURES: %0d", errors);
        $finish;
    end
    initial begin #10000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
