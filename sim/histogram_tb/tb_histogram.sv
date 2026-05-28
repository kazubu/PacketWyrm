// Testbench for pw_histogram_snapshot.

`default_nettype none

module tb_histogram;

    localparam int NUM_FLOWS   = 8;
    localparam int NUM_BUCKETS = 16;
    localparam int HIST_STRIDE = 512;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic            trigger;
    logic [63:0]     hist [NUM_FLOWS * NUM_BUCKETS];
    logic [15:0]     rd_addr;
    logic [31:0]     rd_data;

    pw_histogram_snapshot #(
        .NUM_FLOWS  (NUM_FLOWS),
        .NUM_BUCKETS(NUM_BUCKETS),
        .HIST_STRIDE(HIST_STRIDE)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .trigger_i (trigger),
        .hist_i    (hist),
        .rd_addr_i (rd_addr),
        .rd_data_o (rd_data)
    );

    int    errors = 0;
    string scenario = "init";

    task automatic check_eq(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d expected=%0d",
                     scenario, what, got, exp);
            errors++;
        end else begin
            $display("[ ok %s] %s: %0d", scenario, what, got);
        end
    endtask

    task automatic read_u64(input logic [15:0] base, input int bucket,
                             output logic [63:0] v);
        logic [31:0] lo, hi;
        rd_addr = base + 16'(bucket * 8);
        @(posedge clk);
        @(posedge clk);
        lo = rd_data;
        rd_addr = base + 16'(bucket * 8 + 4);
        @(posedge clk);
        @(posedge clk);
        hi = rd_data;
        v = {hi, lo};
    endtask

    initial begin
        trigger = 1'b0;
        rd_addr = '0;
        for (int i = 0; i < NUM_FLOWS * NUM_BUCKETS; i++) hist[i] = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- pre-trigger reads zero ----
        scenario = "pre";
        begin
            logic [63:0] v;
            read_u64(16'h0, 0, v);
            check_eq("pre flow0 bucket0", v, 0);
        end

        // ---- populate, trigger ----
        scenario = "snap";
        // Flow 3: every bucket non-zero with a known pattern.
        for (int b = 0; b < NUM_BUCKETS; b++)
            hist[3 * NUM_BUCKETS + b] = 64'd1000 + 64'(b);
        // Flow 7: only bucket 5 set, with a wide value.
        hist[7 * NUM_BUCKETS + 5] = 64'hDEADBEEF_CAFEBABE;

        @(posedge clk);
        trigger = 1'b1;
        @(posedge clk);
        trigger = 1'b0;
        @(posedge clk);

        begin
            logic [63:0] v;
            for (int b = 0; b < NUM_BUCKETS; b++) begin
                read_u64(16'(3 * HIST_STRIDE), b, v);
                check_eq($sformatf("flow3 bucket%0d", b), v, 1000 + b);
            end
            read_u64(16'(7 * HIST_STRIDE), 5, v);
            check_eq("flow7 bucket5 wide", v, 64'hDEADBEEF_CAFEBABE);
            // untouched flow/bucket stays zero
            read_u64(16'(7 * HIST_STRIDE), 0, v);
            check_eq("flow7 bucket0 zero", v, 0);
            read_u64(16'(0), 5, v);
            check_eq("flow0 bucket5 zero", v, 0);
        end

        // ---- re-trigger replaces the shadow ----
        scenario = "snap2";
        hist[3 * NUM_BUCKETS + 0] = 64'd99999;
        @(posedge clk);
        trigger = 1'b1;
        @(posedge clk);
        trigger = 1'b0;
        @(posedge clk);
        begin
            logic [63:0] v;
            read_u64(16'(3 * HIST_STRIDE), 0, v);
            check_eq("flow3 bucket0 after re-trigger", v, 99999);
        end

        if (errors == 0) begin
            $display("ALL HISTOGRAM SCENARIOS PASS");
            $finish;
        end else begin
            $display("FAILED with %0d error(s)", errors);
            $fatal;
        end
    end

    initial begin
        #100000;
        $display("WATCHDOG TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
