// End-to-end test for pw_csr_full.
//
// Drives the full AXI4-Lite slave from a small bus master task,
// exercises identity reads, a classifier write+commit that reaches
// the data plane via cls_table_o, a stats snapshot trigger that
// latches the live checker counters, and a histogram read.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_csr_full;

    localparam int NUM_PORTS = 2;
    localparam int NUM_FLOWS = 8;
    localparam int NUM_HIST  = 16;
    localparam int ADDR_W    = 16;

    // wire offsets within pwfpga_classifier_entry
    localparam int W_KEY_OFF    = 0;
    localparam int W_MASK_OFF   = 40;
    localparam int W_LOGICAL_IF = 80;
    localparam int W_LOCAL_FLOW = 84;
    localparam int W_ACTION     = 88;
    localparam int W_PRIORITY   = 89;
    localparam int W_FLAGS      = 90;

    // CSR address constants (16-bit, mirroring csr.h)
    localparam logic [15:0] REG_DEVICE_ID         = 16'h0000;
    localparam logic [15:0] REG_VERSION           = 16'h0004;
    localparam logic [15:0] REG_NUM_FLOWS         = 16'h0018;
    localparam logic [15:0] WIN_CLS_BASE          = 16'h2000;
    localparam logic [15:0] REG_CLS_COMMIT        = WIN_CLS_BASE + 16'h3FFC;
    localparam logic [15:0] WIN_STATS_BASE        = 16'hC000;
    localparam logic [15:0] REG_SNAPSHOT_TRIGGER  = WIN_STATS_BASE + 16'h3FFC;
    localparam logic [15:0] FLOW_BASE_IN_SNAP     = 16'h0100;
    localparam int          OFF_RX_FRAMES         = 16;
    localparam logic [15:0] WIN_HIST_BASE         = 16'hA000;
    localparam int          HIST_STRIDE_B         = 128;   // 16 buckets * 8 B

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    // AXI-Lite signals
    logic [ADDR_W-1:0] awaddr; logic awvalid; logic awready;
    logic [31:0]       wdata;  logic [3:0] wstrb; logic wvalid; logic wready;
    logic [1:0]        bresp;  logic bvalid; logic bready;
    logic [ADDR_W-1:0] araddr; logic arvalid; logic arready;
    logic [31:0]       rdata;  logic [1:0] rresp; logic rvalid; logic rready;

    logic [63:0] ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 64'd1;
    end

    // Counters fed into the snapshot (driven from the TB).
    logic [31:0] port_drops      [NUM_PORTS];
    logic [47:0] ps_zero         [NUM_PORTS] = '{default: 48'd0};  // port stats not exercised here
    logic [47:0] ftx_zero        [NUM_FLOWS] = '{default: 48'd0};  // per-flow tx not exercised here
    logic [63:0] flow_rx         [NUM_FLOWS];
    logic [63:0] flow_lost       [NUM_FLOWS];
    logic [63:0] flow_dup        [NUM_FLOWS];
    logic [63:0] flow_ooo        [NUM_FLOWS];
    logic [63:0] flow_last_seq   [NUM_FLOWS];
    logic [63:0] flow_min_lat    [NUM_FLOWS];
    logic [63:0] flow_max_lat    [NUM_FLOWS];
    logic [63:0] flow_sum_lat    [NUM_FLOWS];
    logic [63:0] flow_samples    [NUM_FLOWS];

    // Live histogram read port + an event-fed BRAM histogram standing
    // in for the data plane's pw_lat_histogram.
    logic [15:0] hist_rd_addr_w;
    logic [63:0] hist_rd_data_w;
    logic        h_ev   [1];
    logic [15:0] h_flow [1];
    logic [15:0] h_bkt  [1];

    pw_classifier_table_t          cls_table;

    pw_csr_full #(
        .ADDR_W         (ADDR_W),
        .NUM_PORTS      (NUM_PORTS),
        .NUM_FLOWS      (NUM_FLOWS),
        .NUM_CLASSIFIER (8),
        .NUM_HIST_BINS  (NUM_HIST)
    ) dut (
        .s_axi_aclk     (clk),
        .s_axi_aresetn  (rst_n),
        .s_axi_awaddr   (awaddr),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (wstrb),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bresp    (bresp),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_araddr   (araddr),
        .s_axi_arvalid  (arvalid),
        .s_axi_arready  (arready),
        .s_axi_rdata    (rdata),
        .s_axi_rresp    (rresp),
        .s_axi_rvalid   (rvalid),
        .s_axi_rready   (rready),
        .timestamp_i    (ts),
        .global_control_o    (),
        .error_status_set_i  (32'h0),
        .port_drops_i        (port_drops),
        .rx_frames_i         (ps_zero),
        .rx_bytes_i          (ps_zero),
        .tx_frames_i         (ps_zero),
        .tx_bytes_i          (ps_zero),
        .flow_rx_i           (flow_rx),
        .flow_lost_i         (flow_lost),
        .flow_dup_i          (flow_dup),
        .flow_ooo_i          (flow_ooo),
        .flow_last_seq_i     (flow_last_seq),
        .flow_min_lat_i      (flow_min_lat),
        .flow_max_lat_i      (flow_max_lat),
        .flow_sum_lat_i      (flow_sum_lat),
        .flow_samples_i      (flow_samples),
        .flow_tx_i           (ftx_zero),
        .hist_rd_addr_o      (hist_rd_addr_w),
        .hist_rd_data_i      (hist_rd_data_w),
        .cls_table_o         (cls_table),
        .flow_wr_en_o        (),
        .flow_wr_addr_o      (),
        .flow_wr_data_o      (),
        .stats_clear_o       (),
        .dp_soft_rst_o       (),
        .spi_sck_o           (),
        .spi_cs_n_o          (),
        .spi_mosi_o          (),
        .spi_miso_i          (1'b0),
        .icap_reboot_o       (),
        .punt_rd_en_o        (),
        .punt_rd_addr_o      (),
        .punt_rd_data_i      (32'h0),
        .punt_pop_o          (),
        .inj_m_tdata         (),
        .inj_m_tkeep         (),
        .inj_m_tvalid        (),
        .inj_m_tready        (1'b1),
        .inj_m_tlast         (),
        .inj_egress_o        ()
    );

    // BRAM histogram backing the CSR's addressed read port, fed by
    // events exactly as the data plane's RX checkers would.
    pw_lat_histogram #(
        .NUM_FLOWS  (NUM_FLOWS),
        .NUM_BUCKETS(NUM_HIST),
        .N_EV       (1),
        .RD_ADDR_W  (16)
    ) u_hist (
        .clk        (clk),
        .rst_n      (rst_n),
        .clear_i    (1'b0),
        .ev_valid_i (h_ev),
        .ev_flow_i  (h_flow),
        .ev_bucket_i(h_bkt),
        .rd_addr_i  (hist_rd_addr_w),
        .rd_data_o  (hist_rd_data_w)
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

    // Tiny AXI-Lite bus master: blocking write + read.
    task automatic axi_write(input logic [ADDR_W-1:0] addr,
                              input logic [31:0]       data);
        @(posedge clk);
        awaddr  = addr;
        awvalid = 1'b1;
        wdata   = data;
        wstrb   = 4'hF;
        wvalid  = 1'b1;
        bready  = 1'b1;
        do @(posedge clk); while (!bvalid);
        awvalid = 1'b0;
        wvalid  = 1'b0;
        bready  = 1'b0;
    endtask

    task automatic axi_read(input  logic [ADDR_W-1:0] addr,
                             output logic [31:0]       data);
        @(posedge clk);
        araddr  = addr;
        arvalid = 1'b1;
        rready  = 1'b1;
        do @(posedge clk); while (!rvalid);
        data    = rdata;
        arvalid = 1'b0;
        rready  = 1'b0;
    endtask

    // 128-byte row buffer
    typedef logic [127:0][7:0] row_bytes_t;

    function automatic row_bytes_t row_zero();
        row_bytes_t r;
        r = '0;
        return r;
    endfunction

    function automatic row_bytes_t put_u8(input row_bytes_t r, input int off,
                                           input logic [7:0] v);
        row_bytes_t o; o = r; o[off] = v; return o;
    endfunction

    function automatic row_bytes_t put_u16(input row_bytes_t r, input int off,
                                            input logic [15:0] v);
        row_bytes_t o; o = r;
        o[off + 0] = v[7:0];
        o[off + 1] = v[15:8];
        return o;
    endfunction

    function automatic row_bytes_t put_u32(input row_bytes_t r, input int off,
                                            input logic [31:0] v);
        row_bytes_t o; o = r;
        o[off + 0] = v[7:0];
        o[off + 1] = v[15:8];
        o[off + 2] = v[23:16];
        o[off + 3] = v[31:24];
        return o;
    endfunction

    task automatic write_cls_row(input int row_idx, input row_bytes_t bytes);
        logic [15:0] row_base;
        logic [31:0] dword;
        row_base = WIN_CLS_BASE + 16'(row_idx * 128);
        for (int d = 0; d < 32; d++) begin
            dword = {bytes[d*4+3], bytes[d*4+2], bytes[d*4+1], bytes[d*4+0]};
            axi_write(row_base + 16'(d*4), dword);
        end
    endtask

    initial begin
        awaddr = '0; awvalid = 1'b0;
        wdata = '0;  wstrb = 4'hF; wvalid = 1'b0;
        bready = 1'b0;
        araddr = '0; arvalid = 1'b0; rready = 1'b0;
        for (int p = 0; p < NUM_PORTS; p++) port_drops[p] = '0;
        for (int f = 0; f < NUM_FLOWS; f++) begin
            flow_rx[f]=0; flow_lost[f]=0; flow_dup[f]=0; flow_ooo[f]=0;
            flow_last_seq[f]=0; flow_min_lat[f]=0; flow_max_lat[f]=0;
            flow_sum_lat[f]=0; flow_samples[f]=0;
        end
        h_ev[0] = 1'b0; h_flow[0] = '0; h_bkt[0] = '0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- identity registers ----
        scenario = "identity";
        begin
            logic [31:0] v;
            axi_read(REG_DEVICE_ID, v);
            check_eq("device_id", v, 32'hA502BEEF);
            axi_read(REG_VERSION, v);
            check_eq("version",   v, 32'h00010000);
            axi_read(REG_NUM_FLOWS, v);
            check_eq("num_flows", v, NUM_FLOWS);
        end

        // ---- classifier row write+commit through AXI ----
        scenario = "cls_commit";
        begin
            row_bytes_t cls;
            cls = row_zero();
            cls = put_u8 (cls, W_KEY_OFF  + 5,  8'd17);
            cls = put_u16(cls, W_KEY_OFF  + 10, 16'd50001);
            cls = put_u8 (cls, W_MASK_OFF + 5,  8'hFF);
            cls = put_u16(cls, W_MASK_OFF + 10, 16'hFFFF);
            cls = put_u8 (cls, W_ACTION,   8'd1);    // TEST_RX
            cls = put_u8 (cls, W_PRIORITY, 8'd5);
            cls = put_u16(cls, W_FLAGS,    16'h0001);
            cls = put_u32(cls, W_LOCAL_FLOW, 32'd2);
            write_cls_row(2, cls);
            check_eq("pre-commit row2 enable", cls_table[2].enable ? 1 : 0, 0);
            axi_write(REG_CLS_COMMIT, 32'h1);
            @(posedge clk);
            @(posedge clk);
            check_eq("post-commit row2 enable", cls_table[2].enable ? 1 : 0, 1);
            check_eq("post-commit row2 action", longint'(cls_table[2].action), 1);
            check_eq("post-commit row2 l4_dst", cls_table[2].key.l4_dst, 50001);
            check_eq("post-commit row2 lfid",   cls_table[2].local_flow_id, 2);
        end

        // ---- stats snapshot trigger ----
        scenario = "snapshot";
        flow_rx[3]       = 64'd7777;
        flow_last_seq[3] = 64'd333;
        axi_write(REG_SNAPSHOT_TRIGGER, 32'h1);
        @(posedge clk);
        @(posedge clk);
        begin
            logic [31:0] lo, hi;
            // pw_flow_stats.rx_frames is at offset 16 within the
            // per-flow block, flow 3 -> WIN_STATS + 0x100 + 3*128
            axi_read(WIN_STATS_BASE + FLOW_BASE_IN_SNAP + 3*128 + OFF_RX_FRAMES, lo);
            axi_read(WIN_STATS_BASE + FLOW_BASE_IN_SNAP + 3*128 + OFF_RX_FRAMES + 4, hi);
            check_eq("snap flow3 rx_frames lo", lo, 7777);
            check_eq("snap flow3 rx_frames hi", hi, 0);
        end

        // ---- histogram readback (live BRAM, addressed pass-through) ----
        // Inject 6 events for flow 3 / bucket 2 into the BRAM histogram
        // (spaced so the two-phase RMW retires each), then read the
        // count back through the CSR's WIN_HIST window.
        scenario = "histogram";
        // Let the BRAM histogram's post-reset clear walk
        // (NUM_FLOWS*NUM_HIST cycles) finish before injecting events.
        repeat (NUM_FLOWS * NUM_HIST + 16) @(posedge clk);
        for (int i = 0; i < 6; i++) begin
            h_ev[0] = 1'b1; h_flow[0] = 16'd3; h_bkt[0] = 16'd2;
            @(posedge clk);
            h_ev[0] = 1'b0;
            repeat (3) @(posedge clk);
        end
        begin
            logic [31:0] lo, hi;
            // flow 3 hist base = WIN_HIST + 3 * 128; bucket 2 = +16
            axi_read(WIN_HIST_BASE + 3*HIST_STRIDE_B + 2*8, lo);
            axi_read(WIN_HIST_BASE + 3*HIST_STRIDE_B + 2*8 + 4, hi);
            check_eq("hist flow3 bucket2 lo", lo, 32'd6);
            check_eq("hist flow3 bucket2 hi", hi, 0);
            // an untouched bucket reads zero
            axi_read(WIN_HIST_BASE + 3*HIST_STRIDE_B + 5*8, lo);
            check_eq("hist flow3 bucket5 zero", lo, 0);
        end

        if (errors == 0) begin
            $display("ALL CSR FULL SCENARIOS PASS");
            $finish;
        end else begin
            $display("FAILED with %0d error(s)", errors);
            $fatal;
        end
    end

    initial begin
        #500000;
        $display("WATCHDOG TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
