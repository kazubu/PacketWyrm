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
    logic [31:0] gpio_sync_ctrl_w;
    logic [3:0]  sfp_i2c_drive_w;
    logic                              lat_corr_wr_en_w;
    logic [$clog2(NUM_FLOWS)-1:0]      lat_corr_wr_slot_w;
    logic [63:0]                       lat_corr_wr_data_w;
    // Capture per-flow lat-correction commit pulses (one cycle each) so the test
    // can verify atomicity (no pulse on a LO-only write) + the committed value.
    int                                lc_pulse_cnt = 0;
    logic [$clog2(NUM_FLOWS)-1:0]      lc_slot;
    logic [63:0]                       lc_data;
    always_ff @(posedge clk) begin
        if (lat_corr_wr_en_w) begin
            lc_pulse_cnt <= lc_pulse_cnt + 1;
            lc_slot      <= lat_corr_wr_slot_w;
            lc_data      <= lat_corr_wr_data_w;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 64'd1;
    end

    // Counters fed into the snapshot (driven from the TB).
    logic [31:0] port_drops      [NUM_PORTS];
    logic [47:0] ps_zero         [NUM_PORTS] = '{default: 48'd0};  // port stats not exercised here
    logic [31:0] pl_zero         [NUM_PORTS] = '{default: 32'd0};  // link-health counts not exercised here
    logic [47:0] ftx_zero        [NUM_FLOWS] = '{default: 48'd0};  // per-flow tx not exercised here
    logic [63:0] fjit_zero       [NUM_FLOWS] = '{default: 64'd0};  // per-flow jitter sum not exercised here
    logic [31:0] fjit32_zero     [NUM_FLOWS] = '{default: 32'd0};  // per-flow jitter min/max not exercised here
    logic [63:0] flow_rx         [NUM_FLOWS];
    logic [63:0] flow_lost       [NUM_FLOWS];
    logic [63:0] flow_dup        [NUM_FLOWS];
    logic [63:0] flow_ooo        [NUM_FLOWS];
    logic [63:0] flow_last_seq   [NUM_FLOWS];
    logic [63:0] flow_min_lat    [NUM_FLOWS];
    logic [63:0] flow_max_lat    [NUM_FLOWS];
    logic [63:0] flow_sum_lat    [NUM_FLOWS];
    logic [63:0] flow_samples    [NUM_FLOWS];

    // BRAM read-port responder: csr_full's snapshot drives flow_rd_addr_o;
    // model the data plane's 2-cycle read latency over the model arrays.
    logic [$clog2(NUM_FLOWS)-1:0] snap_addr, sa1, sa2;
    always_ff @(posedge clk) begin sa1 <= snap_addr; sa2 <= sa1; end
    wire [63:0] flow_rx_r   = flow_rx[sa2];
    wire [63:0] flow_lost_r = flow_lost[sa2];
    wire [63:0] flow_dup_r  = flow_dup[sa2];
    wire [63:0] flow_ooo_r  = flow_ooo[sa2];
    wire [63:0] flow_lseq_r = flow_last_seq[sa2];
    wire [63:0] flow_minl_r = flow_min_lat[sa2];
    wire [63:0] flow_maxl_r = flow_max_lat[sa2];
    wire [63:0] flow_suml_r = flow_sum_lat[sa2];
    wire [63:0] flow_samp_r = flow_samples[sa2];

    // Live histogram read port + an event-fed BRAM histogram standing
    // in for the data plane's pw_lat_histogram.
    logic [15:0] hist_rd_addr_w;
    logic [63:0] hist_rd_data_w;
    logic        h_ev   [1];
    logic [15:0] h_flow [1];
    logic [15:0] h_bkt  [1];
    // TB override of the live 64-bit count: lets the test change the count
    // BETWEEN the lo and hi dword reads (as a live incrementing bucket would)
    // to prove the lo-read latches a hi shadow and the pair cannot tear.
    logic        hist_ov_en  = 1'b0;
    logic [63:0] hist_ov_val = '0;
    wire  [63:0] hist_rd_data_mux = hist_ov_en ? hist_ov_val : hist_rd_data_w;

    // Sticky-error set stimulus (external producers' W1S input).
    logic [31:0] err_set = '0;

    // Field-classifier programming outputs captured from the CSR.
    localparam int NCMP = 12, NUDF = 2, NRULE = 32, NTOTAL = NCMP + NUDF;
    logic                     cmp_wr_en;  logic [$clog2(NCMP)-1:0] cmp_wr_idx;
    logic [4:0]               cmp_wr_src; logic [31:0] cmp_wr_mask, cmp_wr_value;
    logic                     rule_wr_en; logic [$clog2(NRULE)-1:0] rule_wr_idx;
    logic [NTOTAL-1:0]        rule_wr_care; logic [2:0] rule_wr_action;
    logic [31:0]              rule_wr_lfid; logic rule_wr_enable;
    // Sticky capture of the 1-cycle commit pulses.
    logic                     cmp_seen = 0; logic [$clog2(NCMP)-1:0] cap_cmp_idx;
    logic [4:0]               cap_cmp_src; logic [31:0] cap_cmp_mask, cap_cmp_value;
    logic                     rule_seen = 0; logic [$clog2(NRULE)-1:0] cap_rule_idx;
    logic [NTOTAL-1:0]        cap_rule_care; logic [2:0] cap_rule_action;
    logic [31:0]              cap_rule_lfid; logic cap_rule_enable;
    // Hash exact-table programming outputs (exercises the hash_acc_key write pipeline).
    logic                     hash_wr_en; logic [6:0] hash_wr_index;
    logic                     hash_wr_valid; logic [351:0] hash_wr_key;
    logic [$clog2(NUM_FLOWS)-1:0] hash_wr_lfid;
    logic                     hash_seen = 0; logic [6:0] cap_hash_idx;
    logic                     cap_hash_valid; logic [351:0] cap_hash_key;
    logic [$clog2(NUM_FLOWS)-1:0] cap_hash_lfid;
    always @(posedge clk) begin
        if (cmp_wr_en) begin
            cmp_seen <= 1; cap_cmp_idx <= cmp_wr_idx; cap_cmp_src <= cmp_wr_src;
            cap_cmp_mask <= cmp_wr_mask; cap_cmp_value <= cmp_wr_value;
        end
        if (rule_wr_en) begin
            rule_seen <= 1; cap_rule_idx <= rule_wr_idx; cap_rule_care <= rule_wr_care;
            cap_rule_action <= rule_wr_action; cap_rule_lfid <= rule_wr_lfid;
            cap_rule_enable <= rule_wr_enable;
        end
        if (hash_wr_en) begin
            hash_seen <= 1; cap_hash_idx <= hash_wr_index; cap_hash_valid <= hash_wr_valid;
            cap_hash_key <= hash_wr_key; cap_hash_lfid <= hash_wr_lfid;
        end
    end

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
        .error_status_set_i  (err_set),
        .status_err_i        (1'b0),
        .status_activity_i   (1'b0),
        .sysmon_temp_i       (16'h0),
        .sysmon_vccint_i     (16'h0),
        .sysmon_vccaux_i     (16'h0),
        .gpio_sync_ctrl_o    (gpio_sync_ctrl_w),
        .gpio_sync_ts_i      (64'hCAFE_1234_5678_9ABC),
        .gpio_sync_seq_i     (32'd42),
        .gpio_sync_gpio_in_i (6'b101010),
        .sfp_i2c_drive_low_o (sfp_i2c_drive_w),
        .sfp_i2c_in_i        (4'b1010),          // pad readback pattern
        .lat_corr_wr_en_o    (lat_corr_wr_en_w),
        .lat_corr_wr_slot_o  (lat_corr_wr_slot_w),
        .lat_corr_wr_data_o  (lat_corr_wr_data_w),
        .port_drops_i        (port_drops),
        .rx_frames_i         (ps_zero),
        .rx_bytes_i          (ps_zero),
        .tx_frames_i         (ps_zero),
        .tx_bytes_i          (ps_zero),
        .rx_fcs_err_i        (ps_zero),
        .link_up_cnt_i       (pl_zero),
        .link_down_cnt_i     (pl_zero),
        .block_lock_loss_i   (pl_zero),
        .rx_unmatched_i       (pl_zero),
        .last_unmatched_ctx_i (pl_zero),
        .last_unmatched_fid_i (pl_zero),
        .flow_rd_addr_o      (snap_addr),
        .flow_rx_i           (flow_rx_r),
        .flow_lost_i         (flow_lost_r),
        .flow_dup_i          (flow_dup_r),
        .flow_ooo_i          (flow_ooo_r),
        .flow_last_seq_i     (flow_lseq_r),
        .flow_min_lat_i      (flow_minl_r),
        .flow_max_lat_i      (flow_maxl_r),
        .flow_sum_lat_i      (flow_suml_r),
        .flow_samples_i      (flow_samp_r),
        .flow_jit_min_i      (32'd0),
        .flow_jit_max_i      (32'd0),
        .flow_jit_sum_i      (64'd0),
        .flow_tx_i           (48'd0),
        .flow_tx_bytes_i     (64'd0),
        .flow_rx_bytes_i     (64'd0),
        .hist_rd_addr_o      (hist_rd_addr_w),
        .hist_rd_data_i      (hist_rd_data_mux),
        .flow_wr_en_o        (),
        .flow_wr_addr_o      (),
        .flow_wr_data_o      (),
        .map_wr_en_o         (),
        .map_wr_addr_o       (),
        .map_wr_valid_o      (),
        .map_wr_lfid_o       (),
        .cmp_wr_en_o         (cmp_wr_en),
        .cmp_wr_idx_o        (cmp_wr_idx),
        .cmp_wr_src_o        (cmp_wr_src),
        .cmp_wr_mask_o       (cmp_wr_mask),
        .cmp_wr_value_o      (cmp_wr_value),
        .udf_wr_en_o         (),
        .udf_wr_idx_o        (),
        .udf_wr_offset_o     (),
        .udf_wr_mask_o       (),
        .udf_wr_value_o      (),
        .rule_wr_en_o        (rule_wr_en),
        .rule_wr_idx_o       (rule_wr_idx),
        .rule_wr_care_o      (rule_wr_care),
        .rule_wr_action_o    (rule_wr_action),
        .rule_wr_egress_o    (),
        .rule_wr_lfid_o      (rule_wr_lfid),
        .rule_wr_lif_o       (),
        .rule_wr_prio_o      (),
        .rule_wr_enable_o    (rule_wr_enable),
        .hash_seed_o         (),
        .hash_mask_o         (),
        .hash_wr_en_o        (hash_wr_en),
        .hash_wr_index_o     (hash_wr_index),
        .hash_wr_valid_o     (hash_wr_valid),
        .hash_wr_key_o       (hash_wr_key),
        .hash_wr_lfid_o      (hash_wr_lfid),
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

        // ---- sticky error register: external set + W1C clear ----
        // A W1C write must actually clear (single assignment point in the
        // RTL: a separate `& ~wdata` NBA would be overwritten by the
        // textually later sticky-set assignment and silently discarded).
        scenario = "error_w1c";
        begin
            logic [31:0] v;
            axi_read(16'h0110, v);
            check_eq("error_status starts clear", v, 0);
            @(negedge clk); err_set = 32'h0000_0025;   // pulse set bits 0,2,5
            @(negedge clk); err_set = '0;
            axi_read(16'h0110, v);
            check_eq("error_status sticky after set_i", v, 32'h25);
            axi_write(16'h0110, 32'h0000_0021);        // W1C bits 0+5
            axi_read(16'h0110, v);
            check_eq("error_status after W1C(0x21)", v, 32'h04);
            axi_write(16'h0110, 32'hFFFF_FFFF);        // W1C everything
            axi_read(16'h0110, v);
            check_eq("error_status all cleared", v, 0);
        end

        // ---- field-classifier programming through AXI ----
        // Comparator 3 = {src=0 (l4_dst), mask=0xFFFF, value=50001}; the entry
        // commits on the value (+8) write -> cmp_wr_en pulse with the fields.
        scenario = "fc_cmp";
        begin
            axi_write(16'h2000 + 16'(3*16) + 16'h0, 32'd0);        // src
            axi_write(16'h2000 + 16'(3*16) + 16'h4, 32'h0000_FFFF); // mask
            axi_write(16'h2000 + 16'(3*16) + 16'h8, 32'd50001);     // value (commit)
            @(posedge clk);
            check_eq("cmp_wr_en pulsed", cmp_seen ? 1 : 0, 1);
            check_eq("cmp idx",   cap_cmp_idx, 3);
            check_eq("cmp src",   cap_cmp_src, 0);
            check_eq("cmp mask",  cap_cmp_mask, 32'h0000_FFFF);
            check_eq("cmp value", cap_cmp_value, 50001);
        end
        // Rule 1: care = cmp3 (bit 3), action TEST_RX, lfid 2. word0 packs
        // {care[13:0], action[16:14], egress[20:17], prio[28:21], enable[31]};
        // commit on lif (+8).
        scenario = "fc_rule";
        begin
            logic [31:0] w0;
            w0 = 32'd0;
            w0[13:0]  = 14'h0008;   // care = bit 3
            w0[16:14] = 3'd1;       // action TEST_RX
            w0[28:21] = 8'd5;       // priority
            w0[31]    = 1'b1;       // enable
            axi_write(16'h2200 + 16'(1*16) + 16'h0, w0);
            axi_write(16'h2200 + 16'(1*16) + 16'h4, 32'd2);   // lfid
            axi_write(16'h2200 + 16'(1*16) + 16'h8, 32'd0);   // lif (commit)
            @(posedge clk);
            check_eq("rule_wr_en pulsed", rule_seen ? 1 : 0, 1);
            check_eq("rule idx",    cap_rule_idx, 1);
            check_eq("rule care",   cap_rule_care, 14'h0008);
            check_eq("rule action", longint'(cap_rule_action), 1);
            check_eq("rule lfid",   cap_rule_lfid, 2);
            check_eq("rule enable", cap_rule_enable ? 1 : 0, 1);
        end

        // ---- hash exact-table key programming (exercises the hash_acc_key
        //      1-cycle write pipeline: 11 key words @+0..+0x28, commit @+0x2C) ----
        scenario = "hash_key";
        begin
            logic [351:0] exp_key;
            int           bucket;
            logic [15:0]  hbase;
            bucket = 3;
            hbase  = 16'h3000 + 16'(bucket * 64);
            exp_key   = '0;   // hash_seen is set-once by the capture (no earlier test pulses it)
            for (int w = 0; w < 11; w++) begin
                logic [31:0] kw;
                kw = 32'hC0DE_0000 + 32'(w);     // distinct per-word so a mis-staged
                axi_write(hbase + 16'(w*4), kw);  // word would change the 352-bit key
                exp_key[w*32 +: 32] = kw;
            end
            axi_write(hbase + 16'h2C, 32'h8000_0006);   // commit: valid=1, lfid=6
            repeat (4) @(posedge clk);
            check_eq("hash_wr_en pulsed",         hash_seen ? 1 : 0, 1);
            check_eq("hash_wr_index",             cap_hash_idx, bucket);
            check_eq("hash_wr_valid",             cap_hash_valid ? 1 : 0, 1);
            check_eq("hash_wr_lfid",              cap_hash_lfid, 6);
            // the whole 352-bit key must reflect all 11 staged words (pipeline drained)
            check_eq("hash_wr_key all 11 words",  (cap_hash_key == exp_key) ? 1 : 0, 1);
        end

        // ---- stats snapshot trigger ----
        scenario = "snapshot";
        flow_rx[3]       = 64'd7777;
        flow_last_seq[3] = 64'd333;
        axi_write(REG_SNAPSHOT_TRIGGER, 32'h1);
        repeat (NUM_FLOWS + 8) @(posedge clk);   // let the flow-block walk finish
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

        // ---- histogram 64-bit read across a 2^32 carry (no tear) ----
        // Protocol: read LO (+0) then HIGH (+4) per bucket. The LO read
        // returns [31:0] and latches [63:32] into a shadow; the HIGH read
        // returns the shadow. Override the live count between the two dword
        // reads (as an incrementing bucket would) and check the pair is the
        // coherent (0x1,0xFFFFFFFF), not the torn (0x2,0xFFFFFFFF).
        scenario = "hist_carry";
        begin
            logic [31:0] lo, hi;
            hist_ov_en  = 1'b1;
            hist_ov_val = 64'h0000_0001_FFFF_FFFF;
            axi_read(WIN_HIST_BASE + 0, lo);            // flow0 bucket0 LO
            hist_ov_val = 64'h0000_0002_0000_0000;      // count carries between reads
            axi_read(WIN_HIST_BASE + 4, hi);            // HIGH: must be the shadow
            check_eq("hist lo pre-carry",           lo, 32'hFFFF_FFFF);
            check_eq("hist hi shadowed (no tear)",  hi, 32'h0000_0001);
            hist_ov_en = 1'b0;
        end

        // ---- GPIO cross-card time-sync CSR ----
        begin
            logic [31:0] v, vlo, vhi;
            // CTRL is RW: write a config word, read it back + check it reached the
            // module output (gpio_sync_ctrl_o, captured in gpio_sync_ctrl_w).
            axi_write(16'h0130, 32'h0009_0117);       // enable+master, in=1,out=1,per=9
            axi_read (16'h0130, v);
            check_eq("gpio_sync ctrl readback", v, 32'h0009_0117);
            check_eq("gpio_sync ctrl -> module", gpio_sync_ctrl_w, 32'h0009_0117);
            // latched edge timestamp (driven from the constant on the DUT input):
            // reading LOW latches HIGH for an atomic 64-bit read.
            axi_read (16'h0134, vlo);
            axi_read (16'h0138, vhi);
            check_eq("gpio_sync ts low",  vlo, 32'h5678_9ABC);
            check_eq("gpio_sync ts high", vhi, 32'hCAFE_1234);
            axi_read (16'h013C, v);
            check_eq("gpio_sync seq",     v, 32'd42);
            axi_read (16'h0140, v);
            check_eq("gpio_sync status (pad in)", v, 32'h0000_002A);  // 6'b101010

            // SFP I2C (0x0150): [3:0] drive-low reaches the module output; read
            // returns the drive reg in [3:0] and the pad-in (4'b1010) in [19:16].
            axi_write(16'h0150, 32'h0000_0006);       // drive SFP0 SDA + SFP1 SCL low
            check_eq("sfp_i2c drive -> module", sfp_i2c_drive_w, 4'h6);
            axi_read (16'h0150, v);
            check_eq("sfp_i2c drive readback",  v[3:0],   4'h6);
            check_eq("sfp_i2c pad-in readback",  v[19:16], 4'hA);   // 4'b1010
            axi_write(16'h0150, 32'h0000_0000);       // release both buses
            check_eq("sfp_i2c release -> module", sfp_i2c_drive_w, 4'h0);

            // Per-flow lat correction window (0x0180 + slot*8). LO stages, HI
            // commits {hi,shadow} as a one-cycle write pulse {slot,data} to the
            // data-plane table (captured by lc_pulse_cnt/lc_slot/lc_data below).
            // slot 3: LO=0x1234_5678, HI=0xFFFF_FF9C (a negative correction).
            begin
                int c0;
                c0 = lc_pulse_cnt;
                axi_write(16'h0180 + 16'(3*8) + 0, 32'h1234_5678);   // slot 3 LO -> stage
                repeat (3) @(posedge clk);
                check_eq("lat_corr LO-only: no commit pulse", lc_pulse_cnt, c0);  // atomic
                axi_write(16'h0180 + 16'(3*8) + 4, 32'hFFFF_FF9C);   // slot 3 HI -> commit
                repeat (3) @(posedge clk);
                check_eq("lat_corr commit pulsed",  lc_pulse_cnt, c0 + 1);
                check_eq("lat_corr commit slot",    lc_slot, 3);
                check_eq("lat_corr commit data lo", lc_data[31:0],  32'h1234_5678);
                check_eq("lat_corr commit data hi", lc_data[63:32], 32'hFFFF_FF9C);
                // a different slot commits independently with its own staged lo
                c0 = lc_pulse_cnt;
                axi_write(16'h0180 + 16'(5*8) + 0, 32'hAAAA_BBBB);   // slot 5 LO
                axi_write(16'h0180 + 16'(5*8) + 4, 32'h0000_0000);   // slot 5 HI
                repeat (3) @(posedge clk);
                check_eq("lat_corr slot5 pulsed",   lc_pulse_cnt, c0 + 1);
                check_eq("lat_corr slot5 slot",     lc_slot, 5);
                check_eq("lat_corr slot5 data lo",  lc_data[31:0],  32'hAAAA_BBBB);
                check_eq("lat_corr slot5 data hi",  lc_data[63:32], 32'h0000_0000);
            end
        end

        // ---- gpio_sync TS_HIGH latch must reset ----
        // The gpio scenario above read TS_LOW, latching TS_HIGH=0xCAFE_1234.
        // Reset the DUT: a TS_HIGH read BEFORE any TS_LOW read must return 0
        // (gpio_sync_ts_high_latched is in the read-FSM reset list), not the
        // stale pre-reset latch.
        scenario = "gpio_latch_reset";
        begin
            logic [31:0] v;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            axi_read(16'h0138, v);   // TS_HIGH first: no TS_LOW read since reset
            check_eq("gpio_sync ts_high resets to 0", v, 0);
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
