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

    localparam int PORTS   = 2;
    localparam int FLOWS   = 8;
    localparam int BUCKETS = 16;

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
        .gen_enable_i    (gen_en),
        .gen_tokens_fp_i (gen_tok_fp),
        .gen_burst_i     (gen_burst),
        .gen_src_mac_i   (gen_smac),
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

    // --- sticky monitor for short-pulse outputs (FORWARD_PORT etc.)
    logic [PORTS-1:0] tx_seen;
    pw_frame_t        tx_seen_frame [PORTS];
    logic             tx_seen_clear;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_seen <= '0;
            for (int p = 0; p < PORTS; p++) tx_seen_frame[p] <= '0;
        end else if (tx_seen_clear) begin
            tx_seen <= '0;
            for (int p = 0; p < PORTS; p++) tx_seen_frame[p] <= '0;
        end else begin
            for (int p = 0; p < PORTS; p++) begin
                if (tx_valid[p]) begin
                    tx_seen[p]       <= 1'b1;
                    tx_seen_frame[p] <= tx_frame[p];
                end
            end
        end
    end

    task automatic reset_tx_seen();
        tx_seen_clear = 1'b1;
        @(posedge clk);
        tx_seen_clear = 1'b0;
    endtask

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

    // QinQ-tagged TEST_RX frame (802.1ad outer + 802.1Q inner).
    function automatic pw_frame_t make_qinq(input int port_i,
                                            input logic [11:0] outer_vid,
                                            input logic [11:0] inner_vid,
                                            input logic [31:0] tflow,
                                            input logic [63:0] tseq);
        pw_frame_t f;
        int        off, l4_pay_off;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];
        // dst/src MAC
        f.data[0]=8'h02; f.data[1]=8'ha5; f.data[2]=8'h02;
        f.data[3]=8'h00; f.data[4]=8'h00; f.data[5]=8'h02;
        f.data[6]=8'h02; f.data[7]=8'ha5; f.data[8]=8'h02;
        f.data[9]=8'h00; f.data[10]=8'h00; f.data[11]=8'h01;
        // outer S-VLAN, ethertype 0x88a8
        f.data[12]=8'h88; f.data[13]=8'ha8;
        f.data[14]={4'h0, outer_vid[11:8]}; f.data[15]=outer_vid[7:0];
        // inner C-VLAN, ethertype 0x8100
        f.data[16]=8'h81; f.data[17]=8'h00;
        f.data[18]={4'h0, inner_vid[11:8]}; f.data[19]=inner_vid[7:0];
        off = 20;
        // IPv4 ethertype
        f.data[off+0]=8'h08; f.data[off+1]=8'h00; off += 2;
        // IPv4 header
        f.data[off+0]=8'h45; f.data[off+1]=8'h00;
        f.data[off+2]=8'h00; f.data[off+3]=8'h3c;
        f.data[off+4]=8'h00; f.data[off+5]=8'h00;
        f.data[off+6]=8'h40; f.data[off+7]=8'h00;
        f.data[off+8]=8'h40; f.data[off+9]=8'h11;
        f.data[off+10]=8'h00; f.data[off+11]=8'h00;
        f.data[off+12]=8'hc0; f.data[off+13]=8'h00;
        f.data[off+14]=8'h02; f.data[off+15]=8'h01;
        f.data[off+16]=8'hc0; f.data[off+17]=8'h00;
        f.data[off+18]=8'h02; f.data[off+19]=8'h02;
        off += 20;
        // UDP
        f.data[off+0]=8'hc0; f.data[off+1]=8'h00;
        f.data[off+2]=8'hc3; f.data[off+3]=8'h51;
        f.data[off+4]=8'h00; f.data[off+5]=8'h28;
        f.data[off+6]=8'h00; f.data[off+7]=8'h00;
        off += 8;
        // test header
        l4_pay_off = off;
        f.data[l4_pay_off+0]=8'hA5; f.data[l4_pay_off+1]=8'h02;
        f.data[l4_pay_off+2]=8'h7E; f.data[l4_pay_off+3]=8'h57;
        f.data[l4_pay_off+4]=8'h00; f.data[l4_pay_off+5]=8'h01;
        f.data[l4_pay_off+6]=8'h00; f.data[l4_pay_off+7]=8'h00;
        f.data[l4_pay_off+8] =tflow[31:24];
        f.data[l4_pay_off+9] =tflow[23:16];
        f.data[l4_pay_off+10]=tflow[15:8];
        f.data[l4_pay_off+11]=tflow[7:0];
        for (int i = 0; i < 8; i++)
            f.data[l4_pay_off+12+i] = tseq[(7-i)*8 +: 8];
        off += 32;
        f.len = PW_FRAME_LEN_W'(off);
        return f;
    endfunction

    // TCP frame to a configurable dst port (no test header).
    function automatic pw_frame_t make_tcp(input int port_i,
                                           input logic [15:0] dst_port);
        pw_frame_t f;
        int        off;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];
        f.data[0]=8'h02; f.data[1]=8'ha5; f.data[2]=8'h02;
        f.data[3]=8'h00; f.data[4]=8'h00; f.data[5]=8'h02;
        f.data[6]=8'h02; f.data[7]=8'ha5; f.data[8]=8'h02;
        f.data[9]=8'h00; f.data[10]=8'h00; f.data[11]=8'h01;
        f.data[12]=8'h08; f.data[13]=8'h00;
        off = 14;
        // IPv4 hdr, proto = 6 (TCP)
        f.data[off+0]=8'h45;
        f.data[off+9]=8'h06;
        f.data[off+12]=8'hc0; f.data[off+13]=8'h00;
        f.data[off+14]=8'h02; f.data[off+15]=8'h01;
        f.data[off+16]=8'hc0; f.data[off+17]=8'h00;
        f.data[off+18]=8'h02; f.data[off+19]=8'h02;
        off += 20;
        // TCP src=12345 dst=dst_port; rest 0
        f.data[off+0]=8'h30; f.data[off+1]=8'h39;
        f.data[off+2]=dst_port[15:8]; f.data[off+3]=dst_port[7:0];
        off += 20;
        f.len = PW_FRAME_LEN_W'(off);
        return f;
    endfunction

    // ICMP / OSPF / generic-IP frame: proto-only, no L4 port.
    function automatic pw_frame_t make_ipproto(input int port_i,
                                               input logic [7:0] proto);
        pw_frame_t f;
        int        off;
        f = pw_frame_zero();
        f.ingress_port = port_i[3:0];
        f.data[0]=8'h02; f.data[1]=8'ha5; f.data[2]=8'h02;
        f.data[3]=8'h00; f.data[4]=8'h00; f.data[5]=8'h02;
        f.data[6]=8'h02; f.data[7]=8'ha5; f.data[8]=8'h02;
        f.data[9]=8'h00; f.data[10]=8'h00; f.data[11]=8'h01;
        f.data[12]=8'h08; f.data[13]=8'h00;
        off = 14;
        f.data[off+0]=8'h45;
        f.data[off+9]=proto;
        f.data[off+12]=8'hc0; f.data[off+13]=8'h00;
        f.data[off+14]=8'h02; f.data[off+15]=8'h01;
        f.data[off+16]=8'hc0; f.data[off+17]=8'h00;
        f.data[off+18]=8'h02; f.data[off+19]=8'h02;
        off += 20;
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
            /* 0x40000 = 4.0 bytes/cycle in Q16.16, with cap 256B
             * burst -> emits ~1 frame every 25 cycles at our
             * 100-byte frame size. */
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
        cls_table     = '0;
        tx_seen_clear = 1'b0;

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

        gen_en[0]    = 1'b1;
        /* token-bucket rate set by the per-port defaults */

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
        check_eq("loopback samples == rx", flow_samples[0], flow_rx[0]);
        check_eq("loopback min <= max",
                 (flow_min_lat[0] <= flow_max_lat[0]) ? 1 : 0, 1);
        // At least one histogram bucket must be non-zero now.
        begin
            int nonzero;
            nonzero = 0;
            for (int j = 0; j < BUCKETS; j++)
                if (flow_hist[j] > 0) nonzero++;
            check_eq("loopback histogram has buckets",
                     (nonzero > 0) ? 1 : 0, 1);
        end

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

        // ---------------- scenario 6: VLAN-tagged TEST_RX ----------------
        // Match a VLAN-tagged test flow distinct from the previous slots.
        // Exercises the parser's 802.1Q path and the classifier's
        // match_vlan_id mask bit.
        scenario = "vlan";
        cls_table[2].enable             = 1'b0;           // disable flow_id=9 rule
        cls_table[3].enable             = 1'b1;
        cls_table[3].action             = PW_ACT_TEST_RX;
        cls_table[3].priority_          = 8'd5;
        cls_table[3].local_flow_id      = 32'd2;
        cls_table[3].mask.match_vlan_id = 1'b1;
        cls_table[3].mask.match_udp_dst = 1'b1;
        cls_table[3].mask.match_is_test = 1'b1;
        cls_table[3].mask.match_flow_id = 1'b1;
        cls_table[3].key.vlan_id        = 12'd100;
        cls_table[3].key.udp_dst        = 16'd50001;
        cls_table[3].key.test_flow_id   = 32'd20;
        @(posedge clk);

        for (int s = 0; s < 4; s++)
            inject(1, make_frame(1, 1'b1, 1'b1, 32'd20, 64'(s)));
        @(posedge clk);
        check_eq("vlan rx",   flow_rx[2],   4);
        check_eq("vlan lost", flow_lost[2], 0);

        // Untagged frame with the same flow_id must NOT match (mask
        // requires VLAN); it falls to DROP via the catch-all path.
        inject(1, make_frame(1, 1'b0, 1'b1, 32'd20, 64'd99));
        @(posedge clk);
        check_eq("vlan rx (no extra)", flow_rx[2], 4);

        // ---------------- scenario 7: FORWARD_PORT ----------------
        scenario = "forward";
        reset_tx_seen();

        cls_table[4].enable               = 1'b1;
        cls_table[4].action               = PW_ACT_FORWARD_PORT;
        cls_table[4].priority_            = 8'd8;
        cls_table[4].egress_port          = 4'd1;
        cls_table[4].mask.match_ingress_port = 1'b1;
        cls_table[4].mask.match_udp_dst   = 1'b1;
        cls_table[4].key.ingress_port     = 4'd0;
        cls_table[4].key.udp_dst          = 16'd60000;
        @(posedge clk);

        // Build a test frame on port 0 with udp_dst=60000.
        begin
            pw_frame_t fwd;
            fwd = make_frame(0, 1'b0, 1'b0, 32'd0, 64'd0);
            fwd.data[36] = 16'd60000 >> 8;     // UDP dst high byte
            fwd.data[37] = 16'd60000 & 8'hFF;  // UDP dst low byte
            inject(0, fwd);
        end
        @(posedge clk);
        @(posedge clk);
        check_eq("forward tx[1] seen", tx_seen[1] ? 1 : 0, 1);
        if (tx_seen[1]) begin
            check_eq("forward dst MAC byte0", tx_seen_frame[1].data[0], 8'h02);
            check_eq("forward ethertype",
                     {tx_seen_frame[1].data[12], tx_seen_frame[1].data[13]},
                     16'h0800);
        end
        check_eq("forward tx[0] not seen", tx_seen[0] ? 1 : 0, 0);

        // ---------------- scenario 8: out-of-order ----------------
        // Same checker logic but with explicit OOO injection. Seq
        // sequence: 0,1,2,3,5,4 -> rx=6, lost=1 (gap 5>expected=4),
        // ooo=1 (4 arriving after expected=6).
        scenario = "ooo";
        cls_table[5].enable             = 1'b1;
        cls_table[5].action             = PW_ACT_TEST_RX;
        cls_table[5].priority_          = 8'd5;
        cls_table[5].local_flow_id      = 32'd3;
        cls_table[5].mask.match_udp_dst = 1'b1;
        cls_table[5].mask.match_is_test = 1'b1;
        cls_table[5].mask.match_flow_id = 1'b1;
        cls_table[5].key.udp_dst        = 16'd50001;
        cls_table[5].key.test_flow_id   = 32'd30;
        @(posedge clk);

        for (int s = 0; s < 4; s++)
            inject(1, make_frame(1, 1'b0, 1'b1, 32'd30, 64'(s)));
        // jump to seq 5 then back to seq 4
        inject(1, make_frame(1, 1'b0, 1'b1, 32'd30, 64'd5));
        inject(1, make_frame(1, 1'b0, 1'b1, 32'd30, 64'd4));
        @(posedge clk);
        check_eq("ooo rx ",  flow_rx[3],   6);
        check_eq("ooo lost", flow_lost[3], 1);
        check_eq("ooo ooo ", flow_ooo[3],  1);
        check_eq("ooo dup ", flow_dup[3],  0);

        // ---------------- scenario 9: token-bucket rate ----------------
        // Pick a rate that should emit 8-12 frames over 200 cycles
        // at the skeleton's ~106-byte frame size. Verify the count
        // is within that window after a fixed run.
        scenario = "rate";
        // disable previous TEST_RX rules so they don't fire
        cls_table[3].enable = 1'b0;
        cls_table[5].enable = 1'b0;
        // a fresh TEST_RX rule on local_flow_id=4 catching flow_id=1
        // (matches flow_gen[0] which uses GLOBAL_FLOW_ID=32'd1+gp=1)
        cls_table[6].enable             = 1'b1;
        cls_table[6].action             = PW_ACT_TEST_RX;
        cls_table[6].priority_          = 8'd5;
        cls_table[6].local_flow_id      = 32'd4;
        cls_table[6].mask.match_udp_dst = 1'b1;
        cls_table[6].mask.match_is_test = 1'b1;
        cls_table[6].mask.match_flow_id = 1'b1;
        cls_table[6].key.udp_dst        = 16'd50001;
        cls_table[6].key.test_flow_id   = 32'd1;

        // 4.0 bytes/cycle, cap 256 -> at 106-byte frames over 200
        // cycles, expect ~ (4 * 200) / 106 = ~7.5 frames (round to
        // window [4, 12] for skeleton tolerance).
        gen_tok_fp[0] = 32'h00040000;
        gen_burst[0]  = 16'd256;
        gen_en[0]     = 1'b1;
        @(posedge clk);

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

        check_eq("rate rx >= 4",  (flow_rx[4] >= 4)  ? 1 : 0, 1);
        check_eq("rate rx <= 12", (flow_rx[4] <= 12) ? 1 : 0, 1);
        check_eq("rate lost==0",  flow_lost[4], 0);

        // ---------------- scenario 10: QinQ TEST_RX ----------------
        scenario = "qinq";
        cls_table[6].enable = 1'b0;
        cls_table[7].enable             = 1'b1;
        cls_table[7].action             = PW_ACT_TEST_RX;
        cls_table[7].priority_          = 8'd5;
        cls_table[7].local_flow_id      = 32'd5;
        cls_table[7].mask.match_vlan_id       = 1'b1;
        cls_table[7].mask.match_inner_vlan_id = 1'b1;
        cls_table[7].mask.match_is_test       = 1'b1;
        cls_table[7].mask.match_flow_id       = 1'b1;
        cls_table[7].key.vlan_id              = 12'd200;  // outer S-VLAN
        cls_table[7].key.inner_vlan_id        = 12'd300;  // inner C-VLAN
        cls_table[7].key.test_flow_id         = 32'd50;
        @(posedge clk);

        for (int s = 0; s < 3; s++)
            inject(0, make_qinq(0, 12'd200, 12'd300, 32'd50, 64'(s)));
        @(posedge clk);
        check_eq("qinq rx",   flow_rx[5],   3);
        check_eq("qinq lost", flow_lost[5], 0);

        // Inner VLAN mismatch -> rejected (falls to default DROP)
        inject(0, make_qinq(0, 12'd200, 12'd999, 32'd50, 64'd99));
        @(posedge clk);
        check_eq("qinq inner-vlan miss", flow_rx[5], 3);

        // ---------------- scenario 11: TCP/179 (BGP) PUNT ----------------
        // punt_valid is combinational off rx_kv (which is the parser's
        // registered key_valid_o). It is high during the 1-cycle
        // window that begins ONE cycle after rx_valid_i went high;
        // by the time inject()'s second posedge returns, rx_kv has
        // already dropped back to 0. We therefore drive rx_valid
        // manually and check while it is still asserted, like
        // scenario 2.
        scenario = "bgp";
        reset_tx_seen();
        cls_table[0].enable               = 1'b1;
        cls_table[0].action               = PW_ACT_PUNT_TO_HOST;
        cls_table[0].priority_            = 8'd10;
        cls_table[0].mask.match_ethertype = 1'b0;
        cls_table[0].mask.match_is_tcp    = 1'b1;
        cls_table[0].mask.match_l4_dst    = 1'b1;
        cls_table[0].key.l4_dst           = 16'd179;
        @(posedge clk);

        rx_frame[0] = make_tcp(0, 16'd179);
        rx_valid[0] = 1'b1;
        @(posedge clk);                  // parser registers
        @(posedge clk);                  // combinational propagation
        check_eq("bgp punt seen", punt_valid ? 1 : 0, 1);
        rx_valid[0] = 1'b0;
        rx_frame[0] = pw_frame_zero();

        // Force the punt to drop, then send a non-BGP TCP frame.
        @(posedge clk);
        @(posedge clk);
        rx_frame[0] = make_tcp(0, 16'd80);
        rx_valid[0] = 1'b1;
        @(posedge clk);
        @(posedge clk);
        check_eq("non-bgp not punted", punt_valid ? 1 : 0, 0);
        rx_valid[0] = 1'b0;
        rx_frame[0] = pw_frame_zero();

        // ---------------- scenario 12: OSPF PUNT ----------------
        scenario = "ospf";
        cls_table[0].enable = 1'b0;
        cls_table[1].enable             = 1'b1;
        cls_table[1].action             = PW_ACT_PUNT_TO_HOST;
        cls_table[1].priority_          = 8'd10;
        cls_table[1].mask = '0;
        cls_table[1].mask.match_is_ospf = 1'b1;
        @(posedge clk);
        @(posedge clk);

        rx_frame[0] = make_ipproto(0, 8'd89);
        rx_valid[0] = 1'b1;
        @(posedge clk);
        @(posedge clk);
        check_eq("ospf punt seen", punt_valid ? 1 : 0, 1);
        rx_valid[0] = 1'b0;
        rx_frame[0] = pw_frame_zero();

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
