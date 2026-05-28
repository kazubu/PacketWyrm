// Testbench for the CSR window pipeline:
//
//   host BAR write strobes -> pw_csr_window (shadow + commit)
//                          -> pw_classifier_window (typed table)
//                          -> pw_data_plane (classifier in use)
//
// Scenarios:
//   1. Stage a TEST_RX row for UDP/50001 with global_flow_id=42 in
//      the shadow; before commit, verify the live cls_table_o is
//      still all zero (data plane stays in DROP).
//   2. Commit. Verify cls_table_o decodes correctly and the data
//      plane classifies a matching frame as TEST_RX.
//   3. Stage a second row (PUNT_TO_HOST on ethertype 0x0806) and
//      commit. Verify both rows are live (no torn entry).
//   4. Stage a *replacement* for row 0 with flags=0 (disabled).
//      Pre-commit the data plane should still match the previous
//      TEST_RX. Post-commit it should fall through to DROP.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_csr_window;

    localparam int PORTS   = 2;
    localparam int FLOWS   = 8;
    localparam int BUCKETS = 16;
    localparam int ADDR_W  = 16;

    // Wire layout matching `struct pwfpga_classifier_entry` in csr.h.
    localparam int W_KEY_OFF        = 0;
    localparam int W_MASK_OFF       = 40;
    localparam int W_LOGICAL_IF_OFF = 80;
    localparam int W_LOCAL_FLOW_OFF = 84;
    localparam int W_ACTION_OFF     = 88;
    localparam int W_PRIORITY_OFF   = 89;
    localparam int W_FLAGS_OFF      = 90;

    // Wire layout matching `struct pwfpga_match_key`.
    localparam int K_ETHERTYPE      = 0;   // u16
    localparam int K_VLAN_ID        = 2;   // u16
    localparam int K_PCP            = 4;
    localparam int K_L3_PROTO       = 5;
    localparam int K_INGRESS_PORT   = 6;
    localparam int K_IP_VERSION     = 7;
    localparam int K_UDP_SRC        = 8;   // u16
    localparam int K_UDP_DST        = 10;  // u16
    localparam int K_IPV4_SRC       = 12;  // u32
    localparam int K_IPV4_DST       = 16;  // u32
    localparam int K_MAC_SRC        = 20;  // 6 bytes
    localparam int K_MAC_DST        = 26;  // 6 bytes
    localparam int K_TEST_MAGIC     = 32;  // u32
    localparam int K_GLOBAL_FLOW_ID = 36;  // u32

    localparam logic [15:0] WIN_BASE    = 16'h1000;
    localparam logic [15:0] COMMIT_OFF  = 16'h0FFC;
    localparam logic [15:0] COMMIT_ADDR = WIN_BASE + COMMIT_OFF;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    // CSR write strobe driven by the testbench
    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [31:0]       wr_data;

    pw_classifier_table_t cls_table;
    logic                 cls_commit;

    pw_classifier_window #(
        .ADDR_W        (ADDR_W),
        .WIN_BASE      (WIN_BASE),
        .COMMIT_OFFSET (COMMIT_OFF)
    ) u_cw (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .cls_table_o    (cls_table),
        .commit_pulse_o (cls_commit)
    );

    // Data plane fed by the committed table.
    pw_frame_t            rx_frame  [PORTS];
    logic                 rx_valid  [PORTS];
    pw_frame_t            tx_frame  [PORTS];
    logic                 tx_valid  [PORTS];
    logic                 tx_ready  [PORTS];
    pw_frame_t            punt_frame;
    logic                 punt_valid;

    logic                 gen_en      [PORTS];
    logic [31:0]          gen_tok_fp  [PORTS];
    logic [15:0]          gen_burst   [PORTS];
    logic [47:0]          gen_smac    [PORTS];
    logic [47:0]          gen_dmac    [PORTS];
    logic                 gen_vlan_en [PORTS];
    logic [11:0]          gen_vlan_id [PORTS];
    logic [31:0]          gen_sip     [PORTS];
    logic [31:0]          gen_dip     [PORTS];
    logic [15:0]          gen_usp     [PORTS];
    logic [15:0]          gen_udp     [PORTS];

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
        .gen_tokens_fp_i(gen_tok_fp),
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

    // Drive a single AXI-Lite-equivalent dword write.
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

    // Bytes are little-endian on the AXI bus. Build a 32-bit dword
    // from four bytes (b0 = LSB).
    function automatic logic [31:0] dw(input logic [7:0] b0,
                                        input logic [7:0] b1,
                                        input logic [7:0] b2,
                                        input logic [7:0] b3);
        return {b3, b2, b1, b0};
    endfunction

    // 128-byte staging buffer as a packed array (byte 0 in low bits,
    // matching the AXI-Lite little-endian wire format).
    typedef logic [127:0][7:0] row_bytes_t;

    // Drive 32 dword writes (one per cycle) into `row_idx`.
    task automatic write_row(input int row_idx,
                              input row_bytes_t bytes);
        logic [15:0] row_base;
        logic [31:0] data;
        row_base = WIN_BASE + 16'(row_idx * 128);
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

    function automatic row_bytes_t put_u8(input row_bytes_t r, input int off,
                                           input logic [7:0] v);
        row_bytes_t o;
        o = r;
        o[off] = v;
        return o;
    endfunction

    task automatic commit();
        csr_write(COMMIT_ADDR, 32'h1);
        @(posedge clk);
    endtask

    // Build a UDP/IPv4 test frame with a test header. Mirrors the
    // tb_data_plane make_frame().
    function automatic pw_frame_t make_test_frame(input int port_i,
                                                  input logic [31:0] tflow,
                                                  input logic [63:0] tseq);
        pw_frame_t f;
        int        off;
        int        l4_pay_off;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];

        f.data[0]  = 8'h02; f.data[1]  = 8'ha5; f.data[2]  = 8'h02;
        f.data[3]  = 8'h00; f.data[4]  = 8'h00; f.data[5]  = 8'h02;
        f.data[6]  = 8'h02; f.data[7]  = 8'ha5; f.data[8]  = 8'h02;
        f.data[9]  = 8'h00; f.data[10] = 8'h00; f.data[11] = 8'h01;
        f.data[12] = 8'h08; f.data[13] = 8'h00;
        off = 14;

        // IPv4 hdr 20B
        f.data[off + 0]  = 8'h45;
        f.data[off + 9]  = 8'h11;
        f.data[off + 12] = 8'hc0; f.data[off + 13] = 8'h00;
        f.data[off + 14] = 8'h02; f.data[off + 15] = 8'h01;
        f.data[off + 16] = 8'hc0; f.data[off + 17] = 8'h00;
        f.data[off + 18] = 8'h02; f.data[off + 19] = 8'h02;
        off = off + 20;

        // UDP src=49152 dst=50001
        f.data[off + 0] = 8'hc0; f.data[off + 1] = 8'h00;
        f.data[off + 2] = 8'hc3; f.data[off + 3] = 8'h51;
        off = off + 8;

        l4_pay_off = off;
        f.data[l4_pay_off + 0]  = 8'hA5;
        f.data[l4_pay_off + 1]  = 8'h02;
        f.data[l4_pay_off + 2]  = 8'h7E;
        f.data[l4_pay_off + 3]  = 8'h57;
        f.data[l4_pay_off + 4]  = 8'h00;
        f.data[l4_pay_off + 5]  = 8'h01;
        f.data[l4_pay_off + 8]  = tflow[31:24];
        f.data[l4_pay_off + 9]  = tflow[23:16];
        f.data[l4_pay_off + 10] = tflow[15:8];
        f.data[l4_pay_off + 11] = tflow[7:0];
        for (int i = 0; i < 8; i++)
            f.data[l4_pay_off + 12 + i] = tseq[(7-i)*8 +: 8];
        off = off + 32;
        f.len = PW_FRAME_LEN_W'(off);
        return f;
    endfunction

    function automatic pw_frame_t make_arp(input int port_i);
        pw_frame_t f;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];
        for (int i = 0; i < 6; i++) f.data[i]     = 8'hff;
        for (int i = 0; i < 6; i++) f.data[6 + i] = 8'h02;
        f.data[12] = 8'h08;
        f.data[13] = 8'h06;
        f.len = PW_FRAME_LEN_W'(42);
        return f;
    endfunction

    task automatic inject(input int p, input pw_frame_t fr);
        rx_frame[p] = fr;
        rx_valid[p] = 1'b1;
        @(posedge clk);
        rx_valid[p] = 1'b0;
    endtask

    initial begin
        wr_en   = 1'b0;
        wr_addr = '0;
        wr_data = '0;
        for (int p = 0; p < PORTS; p++) begin
            rx_frame[p]   = pw_frame_zero();
            rx_valid[p]   = 1'b0;
            tx_ready[p]   = 1'b1;
            gen_en[p]     = 1'b0;
            gen_tok_fp[p] = 32'h00040000;
            gen_burst[p]  = 16'd256;
            gen_smac[p]   = 48'h02_a5_02_00_00_01;
            gen_dmac[p]   = 48'h02_a5_02_00_00_02;
            gen_vlan_en[p]= 1'b0;
            gen_vlan_id[p]= 12'd100;
            gen_sip[p]    = 32'hC000_0201;
            gen_dip[p]    = 32'hC000_0202;
            gen_usp[p]    = 16'd49152;
            gen_udp[p]    = 16'd50001;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------- scenario 1: stage but do not commit ----------
        scenario = "stage";
        begin
            row_bytes_t row;
            row = row_zero();
            // key: l3_proto=17 (UDP), udp_dst=50001, test_magic, flow_id=42
            row = put_u8 (row, W_KEY_OFF + K_L3_PROTO,        8'd17);
            row = put_u16(row, W_KEY_OFF + K_UDP_DST,         16'd50001);
            row = put_u32(row, W_KEY_OFF + K_TEST_MAGIC,      32'hA5027E57);
            row = put_u32(row, W_KEY_OFF + K_GLOBAL_FLOW_ID,  32'd42);
            // mask: match l3_proto, udp_dst, test_magic, flow_id
            row = put_u8 (row, W_MASK_OFF + K_L3_PROTO,       8'hFF);
            row = put_u16(row, W_MASK_OFF + K_UDP_DST,        16'hFFFF);
            row = put_u32(row, W_MASK_OFF + K_TEST_MAGIC,     32'hFFFFFFFF);
            row = put_u32(row, W_MASK_OFF + K_GLOBAL_FLOW_ID, 32'hFFFFFFFF);
            // action, priority, flags
            row = put_u8 (row, W_ACTION_OFF,   8'd1);    // TEST_RX
            row = put_u8 (row, W_PRIORITY_OFF, 8'd5);
            row = put_u16(row, W_FLAGS_OFF,    16'h0001); // ENABLE
            row = put_u32(row, W_LOCAL_FLOW_OFF, 32'd0);
            row = put_u32(row, W_LOGICAL_IF_OFF, 32'd1000);
            write_row(0, row);
        end

        // Pre-commit: live row 0 must still be disabled.
        check_eq("pre-commit row0 enable",  cls_table[0].enable  ? 1 : 0, 0);
        check_eq("pre-commit row0 action",  longint'(cls_table[0].action), 0);

        // Inject a matching frame: should DROP (no rule live).
        inject(1, make_test_frame(1, 32'd42, 64'd0));
        @(posedge clk);
        @(posedge clk);
        check_eq("pre-commit rx",   flow_rx[0],   0);
        check_eq("pre-commit drop", port_drops[1] >= 1 ? 1 : 0, 1);

        // ---------------- scenario 2: commit ---------------------------
        scenario = "commit";
        commit();
        check_eq("commit pulse seen recently (action live)",
                 longint'(cls_table[0].action), 1);
        check_eq("commit row0 enable",   cls_table[0].enable ? 1 : 0, 1);
        check_eq("commit row0 priority", cls_table[0].priority_, 5);
        check_eq("commit row0 lfid",     cls_table[0].local_flow_id, 0);
        check_eq("commit row0 lif",      cls_table[0].logical_if_id, 1000);
        check_eq("commit row0 l4_dst",   cls_table[0].key.l4_dst, 50001);
        check_eq("commit row0 l3_proto", cls_table[0].key.l3_proto, 17);
        check_eq("commit row0 magic",    cls_table[0].key.test_magic, 32'hA5027E57);
        check_eq("commit row0 flowid",   cls_table[0].key.test_flow_id, 42);
        check_eq("commit row0 mask l3", cls_table[0].mask.match_l3_proto ? 1:0, 1);
        check_eq("commit row0 mask l4", cls_table[0].mask.match_l4_dst ? 1:0, 1);
        check_eq("commit row0 mask mg", cls_table[0].mask.match_is_test ? 1:0, 1);
        check_eq("commit row0 mask fl", cls_table[0].mask.match_flow_id ? 1:0, 1);

        // Inject the same frame again: now it should classify TEST_RX.
        inject(1, make_test_frame(1, 32'd42, 64'd0));
        @(posedge clk);
        @(posedge clk);
        inject(1, make_test_frame(1, 32'd42, 64'd1));
        @(posedge clk);
        @(posedge clk);
        check_eq("post-commit rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        check_eq("post-commit lost", flow_lost[0], 0);

        // ---------------- scenario 3: stage a second row + commit ------
        scenario = "second_row";
        begin
            row_bytes_t row;
            row = row_zero();
            row = put_u16(row, W_KEY_OFF  + K_ETHERTYPE, 16'h0806); // ARP
            row = put_u16(row, W_MASK_OFF + K_ETHERTYPE, 16'hFFFF);
            row = put_u8 (row, W_ACTION_OFF,   8'd2);    // PUNT_TO_HOST
            row = put_u8 (row, W_PRIORITY_OFF, 8'd10);
            row = put_u16(row, W_FLAGS_OFF,    16'h0001);
            row = put_u32(row, W_LOGICAL_IF_OFF, 32'd2000);
            write_row(1, row);
        end
        commit();
        check_eq("row1 enable",       cls_table[1].enable ? 1 : 0, 1);
        check_eq("row1 action PUNT",  longint'(cls_table[1].action), 2);
        check_eq("row1 ethertype",    cls_table[1].key.ethertype, 16'h0806);
        check_eq("row1 logical_if",   cls_table[1].logical_if_id, 2000);
        // Old row 0 must still be live (no torn entry).
        check_eq("row0 still enable", cls_table[0].enable ? 1 : 0, 1);

        // Push an ARP frame; expect punt.
        rx_frame[0] = make_arp(0);
        rx_valid[0] = 1'b1;
        @(posedge clk);
        @(posedge clk);
        check_eq("arp punt valid", punt_valid ? 1 : 0, 1);
        rx_valid[0] = 1'b0;
        rx_frame[0] = pw_frame_zero();
        @(posedge clk);

        // ---------------- scenario 4: disable row 0 -------------------
        scenario = "disable";
        begin
            row_bytes_t row;
            longint   rx_before;
            longint   drop_before;
            row = row_zero();   // flags=0 = disabled
            write_row(0, row);
            // Before commit: row 0 still live (enabled).
            check_eq("pre-disable row0 enable", cls_table[0].enable ? 1 : 0, 1);
            commit();
            check_eq("post-disable row0 enable", cls_table[0].enable ? 1 : 0, 0);

            rx_before   = flow_rx[0];
            drop_before = port_drops[1];
            inject(1, make_test_frame(1, 32'd42, 64'd2));
            @(posedge clk);
            @(posedge clk);
            check_eq("disabled: no new rx",  flow_rx[0],         rx_before);
            check_eq("disabled: drop ticks", (port_drops[1] > drop_before) ? 1 : 0, 1);
        end

        if (errors == 0) begin
            $display("ALL CSR WINDOW SCENARIOS PASS");
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
