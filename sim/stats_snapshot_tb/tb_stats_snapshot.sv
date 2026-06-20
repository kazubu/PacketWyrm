// Testbench for pw_stats_snapshot.
//
// Drives a small set of synthetic per-flow / per-port counters,
// triggers a snapshot, then reads back through the rd_addr/rd_data
// interface and verifies the wire-format byte offsets match
// `struct pw_flow_stats` / `struct pw_port_stats`.

`default_nettype none

module tb_stats_snapshot;

    localparam int PORTS         = 2;
    localparam int NUM_FLOWS     = 8;
    localparam int PORT_STRIDE   = 128;
    localparam int FLOW_STRIDE   = 128;
    localparam int FLOW_BASE     = 256;  // PWFPGA_FLOW_STATS_BASE

    // pw_flow_stats wire offsets (little-endian)
    localparam int OFF_TX_FRAMES   = 0;
    localparam int OFF_RX_FRAMES   = 16;
    localparam int OFF_EXPECTED_SEQ= 32;
    localparam int OFF_LOST        = 48;
    localparam int OFF_DUP         = 56;
    localparam int OFF_OOO         = 64;
    localparam int OFF_MIN_LAT     = 80;
    localparam int OFF_MAX_LAT     = 84;
    localparam int OFF_SUM_LAT     = 88;
    localparam int OFF_SAMPLES     = 96;
    localparam int OFF_JIT_MIN     = 104;
    localparam int OFF_JIT_MAX     = 108;
    localparam int OFF_JIT_SUM     = 112;

    // pw_port_stats wire offsets
    localparam int OFF_PORT_RXF    = 0;
    localparam int OFF_PORT_RXB    = 8;
    localparam int OFF_PORT_FCS    = 16;
    localparam int OFF_PORT_BAD    = 24;
    localparam int OFF_PORT_TXF    = 48;
    localparam int OFF_PORT_TXB    = 56;
    localparam int OFF_PORT_LU     = 64;
    localparam int OFF_PORT_LD     = 68;
    localparam int OFF_PORT_BLL    = 72;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic trigger;
    logic [31:0] port_drops [PORTS];
    logic [47:0] rx_frames_p [PORTS];
    logic [47:0] rx_bytes_p  [PORTS];
    logic [47:0] tx_frames_p [PORTS];
    logic [47:0] tx_bytes_p  [PORTS];
    logic [47:0] rx_fcs_p    [PORTS];
    logic [31:0] link_up_p   [PORTS];
    logic [31:0] link_dn_p   [PORTS];
    logic [31:0] blk_loss_p  [PORTS];
    logic [63:0] flow_rx        [NUM_FLOWS];
    logic [63:0] flow_lost      [NUM_FLOWS];
    logic [63:0] flow_dup       [NUM_FLOWS];
    logic [63:0] flow_ooo       [NUM_FLOWS];
    logic [63:0] flow_last_seq  [NUM_FLOWS];
    logic [63:0] flow_min_lat   [NUM_FLOWS];
    logic [63:0] flow_max_lat   [NUM_FLOWS];
    logic [63:0] flow_sum_lat   [NUM_FLOWS];
    logic [63:0] flow_samples   [NUM_FLOWS];
    logic [63:0] flow_jit_min   [NUM_FLOWS];
    logic [63:0] flow_jit_max   [NUM_FLOWS];
    logic [63:0] flow_jit_sum   [NUM_FLOWS];
    logic [47:0] flow_tx_s     [NUM_FLOWS];

    logic [15:0] rd_addr;
    logic [31:0] rd_data;

    pw_stats_snapshot #(
        .PORTS      (PORTS),
        .NUM_FLOWS  (NUM_FLOWS),
        .PORT_STRIDE(PORT_STRIDE),
        .FLOW_STRIDE(FLOW_STRIDE),
        .FLOW_BASE  (FLOW_BASE)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .trigger_i      (trigger),
        .port_drops_i   (port_drops),
        .rx_frames_i    (rx_frames_p),
        .rx_bytes_i     (rx_bytes_p),
        .tx_frames_i    (tx_frames_p),
        .tx_bytes_i     (tx_bytes_p),
        .rx_fcs_err_i   (rx_fcs_p),
        .link_up_cnt_i    (link_up_p),
        .link_down_cnt_i  (link_dn_p),
        .block_lock_loss_i(blk_loss_p),
        .flow_rx_i      (flow_rx),
        .flow_lost_i    (flow_lost),
        .flow_dup_i     (flow_dup),
        .flow_ooo_i     (flow_ooo),
        .flow_last_seq_i(flow_last_seq),
        .flow_min_lat_i (flow_min_lat),
        .flow_max_lat_i (flow_max_lat),
        .flow_sum_lat_i (flow_sum_lat),
        .flow_samples_i (flow_samples),
        .flow_jit_min_i (flow_jit_min),
        .flow_jit_max_i (flow_jit_max),
        .flow_jit_sum_i (flow_jit_sum),
        .flow_tx_i      (flow_tx_s),
        .rd_addr_i      (rd_addr),
        .rd_data_o      (rd_data)
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

    // Read a 64-bit field stored little-endian at byte offset `off`.
    task automatic read_u64(input logic [15:0] base, input int off,
                             output logic [63:0] v);
        logic [31:0] lo, hi;
        rd_addr = base + 16'(off);
        @(posedge clk);
        @(posedge clk);
        lo = rd_data;
        rd_addr = base + 16'(off + 4);
        @(posedge clk);
        @(posedge clk);
        hi = rd_data;
        v = {hi, lo};
    endtask

    task automatic read_u32(input logic [15:0] base, input int off,
                             output logic [31:0] v);
        rd_addr = base + 16'(off);
        @(posedge clk);
        @(posedge clk);
        v = rd_data;
    endtask

    initial begin
        trigger = 1'b0;
        rd_addr = 16'h0;
        for (int p = 0; p < PORTS; p++) begin
            port_drops[p] = '0; rx_frames_p[p] = '0; rx_bytes_p[p] = '0;
            tx_frames_p[p] = '0; tx_bytes_p[p] = '0;
            rx_fcs_p[p] = '0; link_up_p[p] = '0; link_dn_p[p] = '0; blk_loss_p[p] = '0;
        end
        for (int f = 0; f < NUM_FLOWS; f++) begin
            flow_rx[f]        = '0;
            flow_lost[f]      = '0;
            flow_dup[f]       = '0;
            flow_ooo[f]       = '0;
            flow_last_seq[f]  = '0;
            flow_min_lat[f]   = '0;
            flow_max_lat[f]   = '0;
            flow_sum_lat[f]   = '0;
            flow_samples[f]   = '0; flow_tx_s[f] = '0;
            flow_jit_min[f]   = '0;
            flow_jit_max[f]   = '0;
            flow_jit_sum[f]   = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- pre-snapshot read returns zero -----------------------
        scenario = "pre";
        begin
            logic [63:0] v;
            read_u64(FLOW_BASE, OFF_RX_FRAMES, v);
            check_eq("pre rx_frames", v, 0);
        end

        // ---- stage counters then trigger -------------------------
        scenario = "snap";
        port_drops[0]    = 32'd17;
        port_drops[1]    = 32'd99;
        rx_frames_p[0]   = 48'd1000; rx_bytes_p[0] = 48'd64000;
        tx_frames_p[0]   = 48'd900;  tx_bytes_p[0] = 48'd57600;
        rx_fcs_p[0]      = 48'd7;
        link_up_p[0]     = 32'd2; link_dn_p[0] = 32'd1; blk_loss_p[0] = 32'd3;

        flow_rx[2]       = 64'd1234;
        flow_last_seq[2] = 64'd5000;
        flow_lost[2]     = 64'd3;
        flow_dup[2]      = 64'd1;
        flow_ooo[2]      = 64'd2;
        flow_min_lat[2]  = 64'd50;
        flow_max_lat[2]  = 64'd200;
        flow_sum_lat[2]  = 64'd10000;
        flow_samples[2]  = 64'd80;
        flow_tx_s[2]     = 48'd1240;
        flow_jit_min[2]  = 64'd2;
        flow_jit_max[2]  = 64'd40;
        flow_jit_sum[2]  = 64'd790;

        flow_rx[6]       = 64'h12345678_AABBCCDD;
        flow_last_seq[6] = 64'h00000000_FFFFFFFE;

        @(posedge clk);
        trigger = 1'b1;
        @(posedge clk);
        trigger = 1'b0;
        @(posedge clk);

        // ---- read back ----------------------------------------
        begin
            logic [63:0] v;
            logic [31:0] w;

            // Port 0 bad-frame slot at offset 24
            read_u32(0,           OFF_PORT_BAD, w);
            check_eq("port0 drops", w, 17);
            read_u64(0, OFF_PORT_RXF, v); check_eq("port0 rx_frames", v, 1000);
            read_u64(0, OFF_PORT_RXB, v); check_eq("port0 rx_bytes",  v, 64000);
            read_u64(0, OFF_PORT_TXF, v); check_eq("port0 tx_frames", v, 900);
            read_u64(0, OFF_PORT_TXB, v); check_eq("port0 tx_bytes",  v, 57600);
            read_u64(0, OFF_PORT_FCS, v); check_eq("port0 fcs_error", v, 7);
            read_u32(0, OFF_PORT_LU,  w); check_eq("port0 link_up",   w, 2);
            read_u32(0, OFF_PORT_LD,  w); check_eq("port0 link_down", w, 1);
            read_u32(0, OFF_PORT_BLL, w); check_eq("port0 blk_loss",  w, 3);
            read_u32(PORT_STRIDE, OFF_PORT_BAD, w);
            check_eq("port1 drops", w, 99);

            // Flow 2 (base = FLOW_BASE + 2*128 = 0x100 + 0x100 = 0x200)
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_TX_FRAMES, v); check_eq("flow2 tx_frames", v, 1240);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_RX_FRAMES, v);
            check_eq("flow2 rx_frames", v, 1234);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_EXPECTED_SEQ, v);
            check_eq("flow2 expected_seq", v, 5000);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_LOST, v);
            check_eq("flow2 lost", v, 3);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_DUP, v);
            check_eq("flow2 dup", v, 1);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_OOO, v);
            check_eq("flow2 ooo", v, 2);
            read_u32(FLOW_BASE + 2 * FLOW_STRIDE, OFF_MIN_LAT, w);
            check_eq("flow2 min_lat", w, 50);
            read_u32(FLOW_BASE + 2 * FLOW_STRIDE, OFF_MAX_LAT, w);
            check_eq("flow2 max_lat", w, 200);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_SUM_LAT, v);
            check_eq("flow2 sum_lat", v, 10000);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_SAMPLES, v);
            check_eq("flow2 samples", v, 80);
            read_u32(FLOW_BASE + 2 * FLOW_STRIDE, OFF_JIT_MIN, w);
            check_eq("flow2 jit_min", w, 2);
            read_u32(FLOW_BASE + 2 * FLOW_STRIDE, OFF_JIT_MAX, w);
            check_eq("flow2 jit_max", w, 40);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_JIT_SUM, v);
            check_eq("flow2 jit_sum", v, 790);

            // Flow 6 — verify wide values round-trip via two u32 reads.
            read_u64(FLOW_BASE + 6 * FLOW_STRIDE, OFF_RX_FRAMES, v);
            check_eq("flow6 rx_frames", v, 64'h12345678_AABBCCDD);
            read_u64(FLOW_BASE + 6 * FLOW_STRIDE, OFF_EXPECTED_SEQ, v);
            check_eq("flow6 expected_seq", v, 64'h00000000_FFFFFFFE);

            // Flow 0 (untouched) should be all zero after snapshot.
            read_u64(FLOW_BASE + 0 * FLOW_STRIDE, OFF_RX_FRAMES, v);
            check_eq("flow0 rx_frames zero", v, 0);
        end

        // ---- second snapshot replaces the first --------------------
        scenario = "snap2";
        flow_rx[2] = 64'd9999;
        @(posedge clk);
        trigger = 1'b1;
        @(posedge clk);
        trigger = 1'b0;
        @(posedge clk);
        begin
            logic [63:0] v;
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_TX_FRAMES, v); check_eq("flow2 tx_frames", v, 1240);
            read_u64(FLOW_BASE + 2 * FLOW_STRIDE, OFF_RX_FRAMES, v);
            check_eq("flow2 rx after snap2", v, 9999);
        end

        if (errors == 0) begin
            $display("ALL STATS SNAPSHOT SCENARIOS PASS");
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
