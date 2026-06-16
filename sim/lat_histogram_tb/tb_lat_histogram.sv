// Testbench for pw_lat_histogram (BRAM-backed latency histogram).
//
// Exercises the accumulate path (single-source and simultaneous
// two-source events), the live registered read port, and the clear
// walk. Replaces the old pw_histogram_snapshot unit test now that the
// histogram is BRAM-backed and read live (no snapshot latch).

`default_nettype none

module tb_lat_histogram;

    localparam int NUM_FLOWS   = 8;
    localparam int NUM_BUCKETS = 16;
    localparam int N_EV        = 2;
    localparam int DEPTH       = NUM_FLOWS * NUM_BUCKETS;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic        clear;
    logic        ev_valid  [N_EV];
    logic [15:0] ev_flow   [N_EV];
    logic [15:0] ev_bucket [N_EV];
    logic [15:0] rd_addr;
    logic [63:0] rd_data;

    pw_lat_histogram #(
        .NUM_FLOWS  (NUM_FLOWS),
        .NUM_BUCKETS(NUM_BUCKETS),
        .N_EV       (N_EV),
        .RD_ADDR_W  (16)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .clear_i    (clear),
        .ev_valid_i (ev_valid),
        .ev_flow_i  (ev_flow),
        .ev_bucket_i(ev_bucket),
        .rd_addr_i  (rd_addr),
        .rd_data_o  (rd_data)
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

    // Flat address of (flow, bucket).
    function automatic logic [15:0] flat(input int flow, input int bucket);
        return 16'(flow * NUM_BUCKETS + bucket);
    endfunction

    // Registered read: present the flat address, wait for the 1-cycle
    // BRAM latency, then sample.
    task automatic read_flat(input int flow, input int bucket,
                             output logic [63:0] v);
        rd_addr = flat(flow, bucket);
        @(posedge clk);
        @(posedge clk);
        v = rd_data;
    endtask

    // One single-source event (1-cycle pulse), then a few idle cycles
    // so the two-phase RMW engine retires it before the next event.
    task automatic ev1(input int src, input int flow, input int bucket);
        ev_valid[src]  = 1'b1;
        ev_flow[src]   = 16'(flow);
        ev_bucket[src] = 16'(bucket);
        @(posedge clk);
        ev_valid[src]  = 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // Simultaneous events on both sources in the same cycle, then idle
    // so the engine drains both pending entries (round-robin).
    task automatic ev2(input int f0, input int b0, input int f1, input int b1);
        ev_valid[0] = 1'b1; ev_flow[0] = 16'(f0); ev_bucket[0] = 16'(b0);
        ev_valid[1] = 1'b1; ev_flow[1] = 16'(f1); ev_bucket[1] = 16'(b1);
        @(posedge clk);
        ev_valid[0] = 1'b0;
        ev_valid[1] = 1'b0;
        repeat (6) @(posedge clk);
    endtask

    logic [63:0] v;

    initial begin
        clear = 1'b0;
        rd_addr = 16'h0;
        for (int s = 0; s < N_EV; s++) begin
            ev_valid[s]  = 1'b0;
            ev_flow[s]   = '0;
            ev_bucket[s] = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        // The post-reset clear walk takes DEPTH cycles; wait it out.
        repeat (DEPTH + 16) @(posedge clk);

        // ---- scenario 1: empty after reset ----
        scenario = "empty";
        read_flat(0, 0, v); check_eq("flow0 bucket0", v, 0);
        read_flat(3, 2, v); check_eq("flow3 bucket2", v, 0);
        read_flat(7, 15, v); check_eq("flow7 bucket15", v, 0);

        // ---- scenario 2: single-source accumulate ----
        scenario = "accum1";
        for (int i = 0; i < 5; i++) ev1(0, 3, 2);
        read_flat(3, 2, v); check_eq("flow3 bucket2 == 5", v, 5);
        // neighbours untouched
        read_flat(3, 1, v); check_eq("flow3 bucket1 == 0", v, 0);
        read_flat(3, 3, v); check_eq("flow3 bucket3 == 0", v, 0);
        read_flat(4, 2, v); check_eq("flow4 bucket2 == 0", v, 0);

        // a different bucket of the same flow
        for (int i = 0; i < 3; i++) ev1(1, 3, 9);
        read_flat(3, 9, v); check_eq("flow3 bucket9 == 3", v, 3);
        read_flat(3, 2, v); check_eq("flow3 bucket2 still 5", v, 5);

        // ---- scenario 3: simultaneous two-source events ----
        // Distinct flows (the real invariant: a flow's RX is on one
        // port), so the round-robin engine must retire both with no loss.
        scenario = "accum2";
        for (int i = 0; i < 4; i++) ev2(1, 4, 5, 7);
        read_flat(1, 4, v); check_eq("flow1 bucket4 == 4", v, 4);
        read_flat(5, 7, v); check_eq("flow5 bucket7 == 4", v, 4);

        // ---- scenario 4: clear ----
        scenario = "clear";
        clear = 1'b1; @(posedge clk); clear = 1'b0;
        repeat (DEPTH + 16) @(posedge clk);
        read_flat(3, 2, v); check_eq("flow3 bucket2 cleared", v, 0);
        read_flat(1, 4, v); check_eq("flow1 bucket4 cleared", v, 0);
        read_flat(5, 7, v); check_eq("flow5 bucket7 cleared", v, 0);

        // accumulate works again after clear
        for (int i = 0; i < 2; i++) ev1(0, 6, 1);
        read_flat(6, 1, v); check_eq("flow6 bucket1 == 2 post-clear", v, 2);

        if (errors == 0) $display("ALL LAT_HISTOGRAM SCENARIOS PASS");
        else             $display("LAT_HISTOGRAM FAILURES: %0d", errors);
        $finish;
    end

endmodule

`default_nettype wire
