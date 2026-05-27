// Testbench for the PacketWyrm Phase 3 data plane (driven by
// the sim tool's --binary mode).
//
// Scenarios:
//   1. inject a non-matching frame  -> DROP, drop counter ticks
//   2. inject an ARP-shaped frame   -> PUNT_TO_HOST observed on
//                                     punt channel
//   3. enable flow_gen on port 0,
//      loopback its egress into rx port 1, verify checker sees
//      N frames with lost==0
//   4. drop a chunk of loopbacked
//      frames -> checker counts lost == dropped
//   5. duplicate a frame on rx
//      port 1 -> checker dup counter ticks

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_data_plane;

    localparam int PORTS = 2;
    localparam int FLOWS = 4;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic [63:0] ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 64'd1;
    end

    pw_classifier_table_t cls_table;
    pw_frame_t            rx_frame  [PORTS];
    logic                 rx_valid  [PORTS];
    pw_frame_t            tx_frame  [PORTS];
    logic                 tx_valid  [PORTS];
    logic                 tx_ready  [PORTS];
    pw_frame_t            punt_frame;
    logic                 punt_valid;

    logic                 gen_en   [PORTS];
    logic [15:0]          gen_gap  [PORTS];
    logic [47:0]          gen_smac [PORTS];
    logic [47:0]          gen_dmac [PORTS];
    logic                 gen_vlan_en [PORTS];
    logic [11:0]          gen_vlan_id [PORTS];
    logic [31:0]          gen_sip  [PORTS];
    logic [31:0]          gen_dip  [PORTS];
    logic [15:0]          gen_usp  [PORTS];
    logic [15:0]          gen_udp  [PORTS];

    logic [63:0] flow_rx        [FLOWS];
    logic [63:0] flow_lost      [FLOWS];
    logic [63:0] flow_dup       [FLOWS];
    logic [63:0] flow_ooo       [FLOWS];
    logic [63:0] flow_last_seq  [FLOWS];
    logic [31:0] port_drops     [PORTS];

    pw_data_plane #(.PW_PORTS(PORTS), .PW_NUM_FLOWS(FLOWS)) dut (
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
        .gen_gap_i      (gen_gap),
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
        .port_drops_o   (port_drops)
    );

    int     errors = 0;
    string  scenario = "init";

    task automatic check_eq(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d expected=%0d",
                     scenario, what, got, exp);
            errors++;
        end else begin
            $display("[ ok %s] %s: %0d", scenario, what, got);
        end
    endtask

    // Build a stand-alone IPv4/UDP frame with optional test header.
    function automatic pw_frame_t make_frame(input int port_i,
                                             input bit with_vlan,
                                             input bit with_test,
                                             input logic [31:0] tflow,
                                             input logic [63:0] tseq);
        pw_frame_t f;
        int        off;
        int        l4_pay_off;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];

        f.data[0]  = 8'h02; f.data[1] = 8'ha5; f.data[2] = 8'h02;
        f.data[3]  = 8'h00; f.data[4] = 8'h00; f.data[5] = 8'h02;
        f.data[6]  = 8'h02; f.data[7] = 8'ha5; f.data[8] = 8'h02;
        f.data[9]  = 8'h00; f.data[10]= 8'h00; f.data[11]= 8'h01;
        off = 12;

        if (with_vlan) begin
            f.data[off + 0] = 8'h81;
            f.data[off + 1] = 8'h00;
            f.data[off + 2] = 8'h00;
            f.data[off + 3] = 8'h64;
            off = off + 4;
        end

        f.data[off + 0] = 8'h08;
        f.data[off + 1] = 8'h00;
        off = off + 2;

        // IPv4 hdr 20B src=192.0.2.1 dst=192.0.2.2 proto=UDP
        f.data[off + 0]  = 8'h45;
        f.data[off + 1]  = 8'h00;
        f.data[off + 2]  = 8'h00;
        f.data[off + 3]  = 8'h3c;
        f.data[off + 4]  = 8'h00;
        f.data[off + 5]  = 8'h00;
        f.data[off + 6]  = 8'h40;
        f.data[off + 7]  = 8'h00;
        f.data[off + 8]  = 8'h40;
        f.data[off + 9]  = 8'h11;
        f.data[off + 10] = 8'h00;
        f.data[off + 11] = 8'h00;
        f.data[off + 12] = 8'hc0;
        f.data[off + 13] = 8'h00;
        f.data[off + 14] = 8'h02;
        f.data[off + 15] = 8'h01;
        f.data[off + 16] = 8'hc0;
        f.data[off + 17] = 8'h00;
        f.data[off + 18] = 8'h02;
        f.data[off + 19] = 8'h02;
        off = off + 20;

        // UDP src=49152 dst=50001
        f.data[off + 0] = 8'hc0;
        f.data[off + 1] = 8'h00;
        f.data[off + 2] = 8'hc3;
        f.data[off + 3] = 8'h51;
        f.data[off + 4] = 8'h00;
        f.data[off + 5] = 8'h28;
        f.data[off + 6] = 8'h00;
        f.data[off + 7] = 8'h00;
        off = off + 8;

        if (with_test) begin
            l4_pay_off = off;
            f.data[l4_pay_off + 0]  = 8'hA5;
            f.data[l4_pay_off + 1]  = 8'h02;
            f.data[l4_pay_off + 2]  = 8'h7E;
            f.data[l4_pay_off + 3]  = 8'h57;
            f.data[l4_pay_off + 4]  = 8'h00;
            f.data[l4_pay_off + 5]  = 8'h01;
            f.data[l4_pay_off + 6]  = 8'h00;
            f.data[l4_pay_off + 7]  = 8'h00;
            f.data[l4_pay_off + 8]  = tflow[31:24];
            f.data[l4_pay_off + 9]  = tflow[23:16];
            f.data[l4_pay_off + 10] = tflow[15:8];
            f.data[l4_pay_off + 11] = tflow[7:0];
            f.data[l4_pay_off + 12] = tseq[63:56];
            f.data[l4_pay_off + 13] = tseq[55:48];
            f.data[l4_pay_off + 14] = tseq[47:40];
            f.data[l4_pay_off + 15] = tseq[39:32];
            f.data[l4_pay_off + 16] = tseq[31:24];
            f.data[l4_pay_off + 17] = tseq[23:16];
            f.data[l4_pay_off + 18] = tseq[15:8];
            f.data[l4_pay_off + 19] = tseq[7:0];
            // tx timestamp (8 bytes) left zero in skeleton
            off = off + 32;
        end
        f.len = PW_FRAME_LEN_W'(off);
        return f;
    endfunction

    function automatic pw_frame_t make_arp(input int port_i);
        pw_frame_t f;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];
        for (int i = 0; i < 6; i++)  f.data[i]      = 8'hff;
        for (int i = 0; i < 6; i++)  f.data[6 + i]  = 8'h02;
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

    // -------------- main --------------
    initial begin
        for (int p = 0; p < PORTS; p++) begin
            rx_frame[p]   = pw_frame_zero();
            rx_valid[p]   = 1'b0;
            tx_ready[p]   = 1'b1;
            gen_en[p]     = 1'b0;
            gen_gap[p]    = 16'd0;
            gen_smac[p]   = 48'h02_a5_02_00_00_01;
            gen_dmac[p]   = 48'h02_a5_02_00_00_02;
            gen_vlan_en[p]= 1'b0;
            gen_vlan_id[p]= 12'd100;
            gen_sip[p]    = 32'hC000_0201;
            gen_dip[p]    = 32'hC000_0202;
            gen_usp[p]    = 16'd49152;
            gen_udp[p]    = 16'd50001;
        end
        cls_table = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------- scenario 1: drop ----------------
        scenario = "drop";
        inject(0, make_frame(0, 1'b0, 1'b0, 32'd0, 64'd0));
        @(posedge clk);
        check_eq("port0 drop", port_drops[0], 1);
        check_eq("punt none ", punt_valid ? 1 : 0, 0);

        // ---------------- scenario 2: punt ----------------
        scenario = "punt";
        cls_table[0].enable             = 1'b1;
        cls_table[0].action             = PW_ACT_PUNT_TO_HOST;
        cls_table[0].priority_          = 8'd10;
        cls_table[0].mask.match_ethertype = 1'b1;
        cls_table[0].key.ethertype      = 16'h0806;
        cls_table[0].logical_if_id      = 32'd1000;

        @(posedge clk);
        rx_frame[0] = make_arp(0);
        rx_valid[0] = 1'b1;
        @(posedge clk);
        check_eq("punt valid",     punt_valid ? 1 : 0, 1);
        check_eq("punt ethertype", {punt_frame.data[12], punt_frame.data[13]}, 16'h0806);
        rx_valid[0] = 1'b0;

        // ---------------- scenario 3: test_rx loopback ----------------
        scenario = "loopback";
        cls_table[1].enable             = 1'b1;
        cls_table[1].action             = PW_ACT_TEST_RX;
        cls_table[1].priority_          = 8'd5;
        cls_table[1].local_flow_id      = 32'd0;
        cls_table[1].mask.match_udp_dst = 1'b1;
        cls_table[1].mask.match_is_test = 1'b1;
        cls_table[1].key.udp_dst        = 16'd50001;

        gen_en[0]  = 1'b1;
        gen_gap[0] = 16'd4;

        // External loopback: tx[0] -> rx[1] cycle by cycle.
        for (int n = 0; n < 200; n++) begin
            @(posedge clk);
            rx_frame[1] = tx_frame[0];
            rx_valid[1] = tx_valid[0];
        end

        gen_en[0]   = 1'b0;
        rx_valid[1] = 1'b0;
        rx_frame[1] = pw_frame_zero();
        @(posedge clk);
        @(posedge clk);
        check_eq("loopback rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        check_eq("loopback lost ", flow_lost[0], 0);
        check_eq("loopback ooo  ", flow_ooo[0], 0);

        // ---------------- scenario 4: intentional loss ----------------
        scenario = "loss";
        cls_table[2] = cls_table[1];
        cls_table[2].local_flow_id      = 32'd1;
        cls_table[2].mask.match_flow_id = 1'b1;
        cls_table[2].key.test_flow_id   = 32'd9;
        cls_table[1].enable             = 1'b0;
        @(posedge clk);

        for (int s = 0; s < 5; s++)
            inject(1, make_frame(1, 1'b0, 1'b1, 32'd9, 64'(s)));
        @(posedge clk);
        check_eq("pre-gap rx",   flow_rx[1],   5);
        check_eq("pre-gap lost", flow_lost[1], 0);

        // jump from sequence 4 -> 10: 5 missing frames
        for (int s = 10; s < 13; s++)
            inject(1, make_frame(1, 1'b0, 1'b1, 32'd9, 64'(s)));
        @(posedge clk);
        check_eq("post-gap rx",   flow_rx[1],   8);
        check_eq("post-gap lost", flow_lost[1], 5);

        // ---------------- scenario 5: duplicate ----------------
        scenario = "dup";
        inject(1, make_frame(1, 1'b0, 1'b1, 32'd9, 64'd12));
        @(posedge clk);
        check_eq("dup count", flow_dup[1], 1);

        if (errors == 0) begin
            $display("ALL DATA PLANE SCENARIOS PASS");
            $finish;
        end else begin
            $display("FAILED with %0d error(s)", errors);
            $fatal;
        end
    end


    initial begin
        #200000;
        $display("WATCHDOG TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
