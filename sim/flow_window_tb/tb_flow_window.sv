// Testbench for the flow-table CSR window pipeline:
//
//   host BAR writes -> pw_csr_window -> pw_flow_window
//                                    -> pw_data_plane (flow_gen on port 0)
//
// Scenarios:
//   1. Stage a flow row (egress_port=0, enable=1, tx_enable=1) with
//      a known MAC/IP/UDP signature. Before commit, gen_enable[0]
//      stays 0; the data plane emits no frames.
//   2. Commit. Verify the decoded per-port outputs match the
//      programmed row, and the data plane actually emits frames
//      that loop back into a TEST_RX classifier rule.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_flow_window;

    localparam int PORTS   = 2;
    localparam int FLOWS   = 8;
    localparam int BUCKETS = 16;
    localparam int ADDR_W  = 16;

    // wire layout of struct pwfpga_flow_config
    localparam int F_ENABLE             = 0;
    localparam int F_EGRESS_PORT        = 1;
    localparam int F_GLOBAL_FLOW_ID     = 2;
    localparam int F_LOCAL_FLOW_ID      = 6;
    localparam int F_LOGICAL_IF_ID      = 10;
    localparam int F_DST_MAC            = 14;
    localparam int F_SRC_MAC            = 20;
    localparam int F_VLAN_ENABLE        = 26;
    localparam int F_VLAN_ID            = 27;
    localparam int F_SRC_IPV4           = 31;
    localparam int F_DST_IPV4           = 35;
    localparam int F_UDP_SRC_PORT       = 41;
    localparam int F_UDP_DST_PORT       = 43;
    localparam int F_TOKENS_PER_TICK_FP = 75;
    localparam int F_BURST_BYTES        = 79;
    localparam int F_TX_ENABLE          = 90;

    localparam logic [15:0] FLOW_WIN_BASE   = 16'h2000;
    localparam logic [15:0] FLOW_COMMIT_OFF = 16'h0FFC;
    localparam logic [15:0] FLOW_COMMIT_AD  = FLOW_WIN_BASE + FLOW_COMMIT_OFF;
    localparam logic [15:0] CLS_WIN_BASE    = 16'h1000;
    localparam logic [15:0] CLS_COMMIT_OFF  = 16'h0FFC;
    localparam logic [15:0] CLS_COMMIT_AD   = CLS_WIN_BASE + CLS_COMMIT_OFF;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    // shared write strobe for both windows
    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [31:0]       wr_data;

    pw_classifier_table_t cls_table;
    logic                 cls_commit;
    logic                 flow_commit;

    pw_classifier_window #(
        .ADDR_W        (ADDR_W),
        .WIN_BASE      (CLS_WIN_BASE),
        .COMMIT_OFFSET (CLS_COMMIT_OFF)
    ) u_cw (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .cls_table_o    (cls_table),
        .commit_pulse_o (cls_commit)
    );

    logic [PORTS-1:0]              gen_en_w;
    logic [PORTS-1:0] [31:0]       gen_tok_w;
    logic [PORTS-1:0] [15:0]       gen_burst_w;
    logic [PORTS-1:0] [47:0]       gen_smac_w;
    logic [PORTS-1:0] [47:0]       gen_dmac_w;
    logic [PORTS-1:0]              gen_vlan_en_w;
    logic [PORTS-1:0] [11:0]       gen_vlan_id_w;
    logic [PORTS-1:0] [31:0]       gen_sip_w;
    logic [PORTS-1:0] [31:0]       gen_dip_w;
    logic [PORTS-1:0] [15:0]       gen_usp_w;
    logic [PORTS-1:0] [15:0]       gen_udp_w;

    pw_flow_window #(
        .ADDR_W        (ADDR_W),
        .PORTS         (PORTS),
        .WIN_BASE      (FLOW_WIN_BASE),
        .COMMIT_OFFSET (FLOW_COMMIT_OFF)
    ) u_fw (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .gen_enable_o    (gen_en_w),
        .gen_tokens_fp_o (gen_tok_w),
        .gen_burst_o     (gen_burst_w),
        .gen_src_mac_o   (gen_smac_w),
        .gen_dst_mac_o   (gen_dmac_w),
        .gen_vlan_en_o   (gen_vlan_en_w),
        .gen_vlan_id_o   (gen_vlan_id_w),
        .gen_src_ip_o    (gen_sip_w),
        .gen_dst_ip_o    (gen_dip_w),
        .gen_udp_sp_o    (gen_usp_w),
        .gen_udp_dp_o    (gen_udp_w),
        .flow_rows_o     (),
        .commit_pulse_o  (flow_commit)
    );

    // Unpack to the data plane's unpacked arrays.
    logic        gen_en      [PORTS];
    logic [31:0] gen_tok     [PORTS];
    logic [15:0] gen_burst   [PORTS];
    logic [47:0] gen_smac    [PORTS];
    logic [47:0] gen_dmac    [PORTS];
    logic        gen_vlan_en [PORTS];
    logic [11:0] gen_vlan_id [PORTS];
    logic [31:0] gen_sip     [PORTS];
    logic [31:0] gen_dip     [PORTS];
    logic [15:0] gen_usp     [PORTS];
    logic [15:0] gen_udp     [PORTS];

    always_comb begin
        for (int p = 0; p < PORTS; p++) begin
            gen_en[p]      = gen_en_w[p];
            gen_tok[p]     = gen_tok_w[p];
            gen_burst[p]   = gen_burst_w[p];
            gen_smac[p]    = gen_smac_w[p];
            gen_dmac[p]    = gen_dmac_w[p];
            gen_vlan_en[p] = gen_vlan_en_w[p];
            gen_vlan_id[p] = gen_vlan_id_w[p];
            gen_sip[p]     = gen_sip_w[p];
            gen_dip[p]     = gen_dip_w[p];
            gen_usp[p]     = gen_usp_w[p];
            gen_udp[p]     = gen_udp_w[p];
        end
    end

    pw_frame_t            rx_frame  [PORTS];
    logic                 rx_valid  [PORTS];
    pw_frame_t            tx_frame  [PORTS];
    logic                 tx_valid  [PORTS];
    logic                 tx_ready  [PORTS];
    pw_frame_t            punt_frame;
    logic                 punt_valid;

    logic [63:0] flow_rx        [FLOWS];
    logic [63:0] flow_lost      [FLOWS];
    logic [63:0] flow_dup       [FLOWS];
    logic [63:0] flow_ooo       [FLOWS];
    logic [63:0] flow_last_seq  [FLOWS];
    logic [63:0] flow_min_lat   [FLOWS];
    logic [63:0] flow_max_lat   [FLOWS];
    logic [63:0] flow_sum_lat   [FLOWS];
    logic [63:0] flow_samples   [FLOWS];
    logic [63:0] flow_hist      [FLOWS * BUCKETS];
    logic [31:0] port_drops     [PORTS];

    logic [63:0] ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 64'd1;
    end

    pw_data_plane #(
        .PW_PORTS      (PORTS),
        .PW_NUM_FLOWS  (FLOWS),
        .PW_NUM_BUCKETS(BUCKETS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .timestamp_i    (ts),
        .cls_table_i    (cls_table),
        .rx_frame_i     (rx_frame),
        .rx_valid_i     (rx_valid),
        .tx_frame_o     (tx_frame),
        .tx_valid_o     (tx_valid),
        .tx_ready_i     (tx_ready),
        .punt_frame_o   (punt_frame),
        .punt_valid_o   (punt_valid),
        .gen_enable_i   (gen_en),
        .gen_tokens_fp_i(gen_tok),
        .gen_burst_i    (gen_burst),
        .gen_src_mac_i  (gen_smac),
        .gen_dst_mac_i  (gen_dmac),
        .gen_vlan_en_i  (gen_vlan_en),
        .gen_vlan_id_i  (gen_vlan_id),
        .gen_src_ip_i   (gen_sip),
        .gen_dst_ip_i   (gen_dip),
        .gen_udp_sp_i   (gen_usp),
        .gen_udp_dp_i   (gen_udp),
        .flow_rx        (flow_rx),
        .flow_lost      (flow_lost),
        .flow_dup       (flow_dup),
        .flow_ooo       (flow_ooo),
        .flow_last_seq  (flow_last_seq),
        .flow_min_lat   (flow_min_lat),
        .flow_max_lat   (flow_max_lat),
        .flow_sum_lat   (flow_sum_lat),
        .flow_samples   (flow_samples),
        .flow_hist      (flow_hist),
        .port_drops_o   (port_drops)
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

    task automatic csr_write(input logic [ADDR_W-1:0] addr,
                              input logic [31:0]      data);
        @(posedge clk);
        wr_en   = 1'b1;
        wr_addr = addr;
        wr_data = data;
        @(posedge clk);
        wr_en   = 1'b0;
        wr_addr = '0;
        wr_data = '0;
    endtask

    typedef logic [127:0][7:0] row_bytes_t;

    task automatic write_row(input logic [15:0] base,
                              input int row_idx,
                              input row_bytes_t bytes);
        logic [15:0] row_base;
        logic [31:0] data;
        row_base = base + 16'(row_idx * 128);
        for (int d = 0; d < 32; d++) begin
            data = {bytes[d*4+3], bytes[d*4+2], bytes[d*4+1], bytes[d*4+0]};
            csr_write(row_base + 16'(d*4), data);
        end
    endtask

    function automatic row_bytes_t row_zero();
        row_bytes_t r;
        r = '0;
        return r;
    endfunction

    function automatic row_bytes_t put_u8(input row_bytes_t r, input int off,
                                           input logic [7:0] v);
        row_bytes_t o;
        o = r;
        o[off] = v;
        return o;
    endfunction

    function automatic row_bytes_t put_u16(input row_bytes_t r, input int off,
                                            input logic [15:0] v);
        row_bytes_t o;
        o = r;
        o[off + 0] = v[7:0];
        o[off + 1] = v[15:8];
        return o;
    endfunction

    function automatic row_bytes_t put_u32(input row_bytes_t r, input int off,
                                            input logic [31:0] v);
        row_bytes_t o;
        o = r;
        o[off + 0] = v[7:0];
        o[off + 1] = v[15:8];
        o[off + 2] = v[23:16];
        o[off + 3] = v[31:24];
        return o;
    endfunction

    function automatic row_bytes_t put_mac(input row_bytes_t r, input int off,
                                            input logic [47:0] v);
        row_bytes_t o;
        o = r;
        // wire is MSB-first byte order for MAC addresses (network order).
        o[off + 0] = v[47:40];
        o[off + 1] = v[39:32];
        o[off + 2] = v[31:24];
        o[off + 3] = v[23:16];
        o[off + 4] = v[15:8];
        o[off + 5] = v[7:0];
        return o;
    endfunction

    initial begin
        wr_en   = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        for (int p = 0; p < PORTS; p++) begin
            rx_frame[p] = pw_frame_zero();
            rx_valid[p] = 1'b0;
            tx_ready[p] = 1'b1;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // pw_data_plane hard-codes the per-port flow_gen GLOBAL_FLOW_ID
        // to (32'd1 + port_index), so port 0's generator stamps
        // flow_id=1 into the test header. Classifier matches on it.
        scenario = "cls_setup";
        begin
            row_bytes_t cls;
            cls = row_zero();
            cls = put_u8 (cls, 0  + 5,  8'd17);
            cls = put_u16(cls, 0  + 10, 16'd50001);
            cls = put_u32(cls, 0  + 32, 32'hA5027E57);
            cls = put_u32(cls, 0  + 36, 32'd1);
            cls = put_u8 (cls, 40 + 5,  8'hFF);
            cls = put_u16(cls, 40 + 10, 16'hFFFF);
            cls = put_u32(cls, 40 + 32, 32'hFFFFFFFF);
            cls = put_u32(cls, 40 + 36, 32'hFFFFFFFF);
            cls = put_u8 (cls, 88,      8'd1);   // TEST_RX
            cls = put_u8 (cls, 89,      8'd5);
            cls = put_u16(cls, 90,      16'h0001);
            cls = put_u32(cls, 84,      32'd0); // local_flow_id
            write_row(CLS_WIN_BASE, 0, cls);
            csr_write(CLS_COMMIT_AD, 32'h1);
        end

        // ---- stage flow row 0 on egress port 0 (pre-commit) -------
        scenario = "stage";
        begin
            row_bytes_t row;
            row = row_zero();
            row = put_u8 (row, F_ENABLE,             8'd1);
            row = put_u8 (row, F_EGRESS_PORT,        8'd0);
            row = put_u32(row, F_GLOBAL_FLOW_ID,     32'd7);
            row = put_mac(row, F_DST_MAC,            48'h02_a5_02_00_00_02);
            row = put_mac(row, F_SRC_MAC,            48'h02_a5_02_00_00_01);
            row = put_u32(row, F_SRC_IPV4,           32'hC000_0201);
            row = put_u32(row, F_DST_IPV4,           32'hC000_0202);
            row = put_u16(row, F_UDP_SRC_PORT,       16'd49152);
            row = put_u16(row, F_UDP_DST_PORT,       16'd50001);
            row = put_u32(row, F_TOKENS_PER_TICK_FP, 32'h00040000);
            row = put_u16(row, F_BURST_BYTES,        16'd256);
            row = put_u8 (row, F_TX_ENABLE,          8'd1);
            write_row(FLOW_WIN_BASE, 0, row);
        end

        check_eq("pre-commit gen_en[0]", gen_en_w[0] ? 1 : 0, 0);
        check_eq("pre-commit flow_rx",   flow_rx[0], 0);

        // ---- commit ----------------------------------------------
        scenario = "commit";
        csr_write(FLOW_COMMIT_AD, 32'h1);
        @(posedge clk);
        @(posedge clk);
        check_eq("post-commit gen_en[0]",   gen_en_w[0] ? 1 : 0, 1);
        check_eq("post-commit gen_en[1]",   gen_en_w[1] ? 1 : 0, 0);
        check_eq("post-commit tokens_fp",   gen_tok_w[0], 32'h00040000);
        check_eq("post-commit burst",       gen_burst_w[0], 256);
        check_eq("post-commit src_ip",      gen_sip_w[0], 32'hC000_0201);
        check_eq("post-commit dst_ip",      gen_dip_w[0], 32'hC000_0202);
        check_eq("post-commit udp_src",     gen_usp_w[0], 49152);
        check_eq("post-commit udp_dst",     gen_udp_w[0], 50001);
        check_eq("post-commit dmac",        gen_dmac_w[0], 48'h02_a5_02_00_00_02);
        check_eq("post-commit smac",        gen_smac_w[0], 48'h02_a5_02_00_00_01);

        // ---- external loopback ----------------------------------
        scenario = "loopback";
        for (int n = 0; n < 200; n++) begin
            @(posedge clk);
            rx_frame[1] = tx_frame[0];
            rx_valid[1] = tx_valid[0];
        end
        rx_valid[1] = 1'b0;
        rx_frame[1] = pw_frame_zero();
        @(posedge clk);
        @(posedge clk);
        check_eq("loopback rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        check_eq("loopback lost",   flow_lost[0], 0);

        // ---- disable flow via re-commit --------------------------
        scenario = "disable";
        begin
            row_bytes_t row;
            longint     rx_before;
            row = row_zero();   // enable=0
            write_row(FLOW_WIN_BASE, 0, row);
            csr_write(FLOW_COMMIT_AD, 32'h1);
            @(posedge clk);
            @(posedge clk);
            check_eq("post-disable gen_en[0]", gen_en_w[0] ? 1 : 0, 0);
            rx_before = flow_rx[0];
            // Run 200 cycles with no rx feed; counter should not grow.
            for (int n = 0; n < 200; n++) @(posedge clk);
            check_eq("disabled: rx flat", flow_rx[0], rx_before);
        end

        if (errors == 0) begin
            $display("ALL FLOW WINDOW SCENARIOS PASS");
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
