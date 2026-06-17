// Testbench for pw_data_plane_axis (64-bit AXIS streaming data plane,
// core test path). Drives per-port AXIS RX, loops the egress flow
// generator back into an ingress port at the AXIS level, and checks
// the TEST_RX checker counters plus the DROP path.
//
// Scenarios:
//   1. loopback   gen[0] -> rx[1] (AXIS wire-through), rx>0, lost==0,
//                 ooo==0, samples==rx, histogram populated
//   2. loss       inject seq 0..4 then 10..12 on a flow -> lost==5
//   3. dup        re-inject the last seq -> dup==1
//   4. ooo        seq 0,1,2,3,5,4 -> rx==6, lost==1, ooo==1
//   5. rate       token-bucket frame count lands in a window, lost==0
//   6. drop       non-matching frame -> port_drops ticks

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_data_plane_axis;

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

    // --- AXIS RX (driven from injector regs, port 1 may loop back) ---
    logic [63:0] rx_tdata  [PORTS];
    logic [7:0]  rx_tkeep  [PORTS];
    logic        rx_tvalid [PORTS];
    logic        rx_tready [PORTS];
    logic        rx_tlast  [PORTS];

    // injector registers (per port)
    logic [63:0] inj_tdata  [PORTS];
    logic [7:0]  inj_tkeep  [PORTS];
    logic        inj_tvalid [PORTS];
    logic        inj_tlast  [PORTS];

    // --- AXIS TX ---
    logic [63:0] tx_tdata  [PORTS];
    logic [7:0]  tx_tkeep  [PORTS];
    logic        tx_tvalid [PORTS];
    logic        tx_tready [PORTS];
    logic        tx_tlast  [PORTS];

    // punt (tied off in DUT)
    logic [35:0] punt_tuser;   // {ingress[3:0], logical_if_id[31:0]}
    logic [35:0] pn_user_last; // latched punt tuser of the last punted frame

    // slow-path TX inject source (host -> egress)
    logic [63:0] txinj_tdata = 0; logic [7:0] txinj_tkeep = 0;
    logic        txinj_tvalid = 0, txinj_tlast = 0; wire txinj_tready;
    logic [3:0]  txinj_egress = 0;
    logic [63:0] punt_tdata;
    logic [7:0]  punt_tkeep;
    logic        punt_tvalid;
    logic        punt_tready = 1'b1;
    logic        punt_tlast;

    logic stats_clear = 1'b0;   // pulse to soft-reset the checkers
    logic dp_soft_rst = 1'b0;   // pulse to reset the wedge-prone datapath
    // hist_rd_addr / hist_rd_data declared below near the DUT counters

    // loopback: when set, port-1 ingress is fed from port-0 egress.
    logic lb_en;

    logic bidir_en;   // when set, port-0 ingress is fed from port-1 egress

    always_comb begin
        // port 0: bidirectional loopback override (tx[1]) or its injector
        if (bidir_en) begin
            rx_tdata[0]  = tx_tdata[1];
            rx_tkeep[0]  = tx_tkeep[1];
            rx_tvalid[0] = tx_tvalid[1];
            rx_tlast[0]  = tx_tlast[1];
        end else begin
            rx_tdata[0]  = inj_tdata[0];
            rx_tkeep[0]  = inj_tkeep[0];
            rx_tvalid[0] = inj_tvalid[0];
            rx_tlast[0]  = inj_tlast[0];
        end
        // port 1: loopback override or injector
        if (lb_en) begin
            rx_tdata[1]  = tx_tdata[0];
            rx_tkeep[1]  = tx_tkeep[0];
            rx_tvalid[1] = tx_tvalid[0];
            rx_tlast[1]  = tx_tlast[0];
        end else begin
            rx_tdata[1]  = inj_tdata[1];
            rx_tkeep[1]  = inj_tkeep[1];
            rx_tvalid[1] = inj_tvalid[1];
            rx_tlast[1]  = inj_tlast[1];
        end
    end

    // flow gen control: full flow table. Slot 0 drives egress 0 (flow_id 1),
    // slot 1 drives egress 1 (flow_id 2); .valid toggles each generator.
    pw_flow_row_t flow_rows [FLOWS];

    logic [63:0] flow_rx        [FLOWS];
    logic [63:0] flow_lost      [FLOWS];
    logic [63:0] flow_dup       [FLOWS];
    logic [63:0] flow_ooo       [FLOWS];
    logic [63:0] flow_last_seq  [FLOWS];
    logic [63:0] flow_min_lat   [FLOWS];
    logic [63:0] flow_max_lat   [FLOWS];
    logic [63:0] flow_sum_lat   [FLOWS];
    logic [63:0] flow_samples   [FLOWS];
    logic [15:0] hist_rd_addr = 16'h0;
    logic [63:0] hist_rd_data;
    logic [31:0] port_drops     [PORTS];

    pw_data_plane_axis #(
        .PW_PORTS         (PORTS),
        .PW_NUM_FLOWS     (FLOWS),
        .PW_NUM_BUCKETS   (BUCKETS),
        .HDR_BYTES        (100),
        .FRAME_LEN_PAYLOAD(32)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .timestamp_i      (ts),
        .stats_clear_i    (stats_clear),
        .dp_soft_rst_i    (dp_soft_rst),
        .cls_table_i      (cls_table),
        .s_axis_rx_tdata  (rx_tdata),
        .s_axis_rx_tkeep  (rx_tkeep),
        .s_axis_rx_tvalid (rx_tvalid),
        .s_axis_rx_tready (rx_tready),
        .s_axis_rx_tlast  (rx_tlast),
        .m_axis_tx_tdata  (tx_tdata),
        .m_axis_tx_tkeep  (tx_tkeep),
        .m_axis_tx_tvalid (tx_tvalid),
        .m_axis_tx_tready (tx_tready),
        .m_axis_tx_tlast  (tx_tlast),
        .m_axis_punt_tdata (punt_tdata),
        .m_axis_punt_tkeep (punt_tkeep),
        .m_axis_punt_tvalid(punt_tvalid),
        .m_axis_punt_tready(punt_tready),
        .m_axis_punt_tlast (punt_tlast),
        .m_axis_punt_tuser (punt_tuser),
        .s_axis_inj_tdata  (txinj_tdata),
        .s_axis_inj_tkeep  (txinj_tkeep),
        .s_axis_inj_tvalid (txinj_tvalid),
        .s_axis_inj_tready (txinj_tready),
        .s_axis_inj_tlast  (txinj_tlast),
        .s_axis_inj_egress (txinj_egress),
        .flow_rows_i      (flow_rows),
        .flow_rx          (flow_rx),
        .flow_lost        (flow_lost),
        .flow_dup         (flow_dup),
        .flow_ooo         (flow_ooo),
        .flow_last_seq    (flow_last_seq),
        .flow_min_lat     (flow_min_lat),
        .flow_max_lat     (flow_max_lat),
        .flow_sum_lat     (flow_sum_lat),
        .flow_samples     (flow_samples),
        .hist_rd_addr_i   (hist_rd_addr),
        .hist_rd_data_o   (hist_rd_data),
        .port_drops_o     (port_drops)
    );

    // --- egress / punt collectors (reassemble forwarded & punted frames)
    logic [63:0] tx1_data [$]; logic [7:0] tx1_keep [$]; logic tx1_last [$];
    logic [63:0] pn_data  [$]; logic [7:0] pn_keep  [$]; logic pn_last  [$];

    always_ff @(posedge clk) begin
        if (rst_n && tx_tvalid[1] && tx_tready[1]) begin
            tx1_data.push_back(tx_tdata[1]);
            tx1_keep.push_back(tx_tkeep[1]);
            tx1_last.push_back(tx_tlast[1]);
        end
        if (rst_n && punt_tvalid && punt_tready) begin
            pn_data.push_back(punt_tdata);
            pn_keep.push_back(punt_tkeep);
            pn_last.push_back(punt_tlast);
            pn_user_last <= punt_tuser;   // {ingress[3:0], logical_if_id[31:0]} of the punted frame
        end
    end

    // Count bytes accumulated in a keep queue (popcount of tkeep beats).
    function automatic int qbytes(input logic [7:0] kq []);
        int n; n = 0;
        foreach (kq[i]) for (int k = 0; k < 8; k++) if (kq[i][k]) n++;
        return n;
    endfunction

    int     errors = 0;
    string  scenario = "init";

    task automatic check_eq(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d expected=%0d", scenario, what, got, exp);
            errors++;
        end else begin
            $display("[ ok %s] %s: %0d", scenario, what, got);
        end
    endtask

    // ----- frame builder: Ethernet [/VLAN] / IPv4 / UDP / 32B test hdr
    logic [7:0] fb [0:127];
    int         fb_len;

    task automatic build_test_udp(input bit with_vlan,
                                  input logic [31:0] tflow,
                                  input logic [63:0] tseq);
        int off, pay;
        for (int i = 0; i < 128; i++) fb[i] = 8'h00;
        // dst/src MAC
        fb[0]=8'h02; fb[1]=8'ha5; fb[2]=8'h02; fb[3]=8'h00; fb[4]=8'h00; fb[5]=8'h02;
        fb[6]=8'h02; fb[7]=8'ha5; fb[8]=8'h02; fb[9]=8'h00; fb[10]=8'h00; fb[11]=8'h01;
        off = 12;
        if (with_vlan) begin
            fb[off+0]=8'h81; fb[off+1]=8'h00; fb[off+2]=8'h00; fb[off+3]=8'h64;
            off += 4;
        end
        fb[off+0]=8'h08; fb[off+1]=8'h00; off += 2;        // ethertype IPv4
        // IPv4 hdr (20B) 192.0.2.1 -> 192.0.2.2, proto UDP
        fb[off+0]=8'h45; fb[off+1]=8'h00; fb[off+2]=8'h00; fb[off+3]=8'h3c;
        fb[off+4]=8'h00; fb[off+5]=8'h00; fb[off+6]=8'h40; fb[off+7]=8'h00;
        fb[off+8]=8'h40; fb[off+9]=8'h11; fb[off+10]=8'h00; fb[off+11]=8'h00;
        fb[off+12]=8'hc0; fb[off+13]=8'h00; fb[off+14]=8'h02; fb[off+15]=8'h01;
        fb[off+16]=8'hc0; fb[off+17]=8'h00; fb[off+18]=8'h02; fb[off+19]=8'h02;
        off += 20;
        // UDP src=49152 dst=50001
        fb[off+0]=8'hc0; fb[off+1]=8'h00; fb[off+2]=8'hc3; fb[off+3]=8'h51;
        fb[off+4]=8'h00; fb[off+5]=8'h28; fb[off+6]=8'h00; fb[off+7]=8'h00;
        off += 8;
        // 32-byte PacketWyrm test header
        pay = off;
        fb[pay+0]=8'hA5; fb[pay+1]=8'h02; fb[pay+2]=8'h7E; fb[pay+3]=8'h57;
        fb[pay+4]=8'h00; fb[pay+5]=8'h01; fb[pay+6]=8'h00; fb[pay+7]=8'h00;
        fb[pay+8]=tflow[31:24]; fb[pay+9]=tflow[23:16];
        fb[pay+10]=tflow[15:8];  fb[pay+11]=tflow[7:0];
        for (int i = 0; i < 8; i++) fb[pay+12+i] = tseq[(7-i)*8 +: 8];
        // tx timestamp (8B) left zero
        off += 32;
        fb_len = off;
    endtask

    // Plain IPv4/UDP frame to `dport`, no test header.
    task automatic build_plain_udp(input logic [15:0] dport);
        int off;
        for (int i = 0; i < 128; i++) fb[i] = 8'h00;
        fb[0]=8'h02; fb[1]=8'ha5; fb[2]=8'h02; fb[3]=8'h00; fb[4]=8'h00; fb[5]=8'h02;
        fb[6]=8'h02; fb[7]=8'ha5; fb[8]=8'h02; fb[9]=8'h00; fb[10]=8'h00; fb[11]=8'h01;
        fb[12]=8'h08; fb[13]=8'h00; off = 14;
        fb[off+0]=8'h45; fb[off+9]=8'h11;
        fb[off+12]=8'hc0; fb[off+13]=8'h00; fb[off+14]=8'h02; fb[off+15]=8'h01;
        fb[off+16]=8'hc0; fb[off+17]=8'h00; fb[off+18]=8'h02; fb[off+19]=8'h02;
        off += 20;
        fb[off+0]=8'hc0; fb[off+1]=8'h00;                  // udp src 49152
        fb[off+2]=dport[15:8]; fb[off+3]=dport[7:0];       // udp dst
        off += 8;
        fb_len = off;
    endtask

    // Stream the current fb[0..fb_len) into `port` as 64-bit beats.
    task automatic inject(input int port);
        int off;
        off = 0;
        while (off < fb_len) begin
            @(negedge clk);
            inj_tvalid[port] = 1'b1;
            inj_tdata[port]  = '0;
            inj_tkeep[port]  = '0;
            for (int k = 0; k < 8; k++) begin
                if (off + k < fb_len) begin
                    inj_tdata[port][k*8 +: 8] = fb[off + k];
                    inj_tkeep[port][k]        = 1'b1;
                end
            end
            inj_tlast[port] = (off + 8 >= fb_len);
            @(posedge clk);
            off += 8;
        end
        @(negedge clk);
        inj_tvalid[port] = 1'b0;
        inj_tlast[port]  = 1'b0;
    endtask

    task automatic inject_test(input int port, input logic [31:0] tflow,
                               input logic [63:0] tseq);
        build_test_udp(1'b0, tflow, tseq);
        inject(port);
    endtask

    // -------------- main --------------
    initial begin
        lb_en = 1'b0;
        bidir_en = 1'b0;
        for (int p = 0; p < PORTS; p++) begin
            inj_tdata[p]  = '0; inj_tkeep[p] = '0;
            inj_tvalid[p] = 1'b0; inj_tlast[p] = 1'b0;
            tx_tready[p]  = 1'b1;
        end
        // Flow table: slot 0 -> egress 0 (flow_id 1), slot 1 -> egress 1
        // (flow_id 2). .valid toggles each generator; other slots idle.
        for (int s = 0; s < FLOWS; s++) flow_rows[s] = '0;
        for (int s = 0; s < 2; s++) begin
            flow_rows[s].egress    = 4'(s);
            flow_rows[s].flow_id   = 32'(s + 1);
            flow_rows[s].tokens_fp = 32'h00040000;   // 4.0 bytes/cycle, Q16.16
            flow_rows[s].burst     = 16'd256;
            flow_rows[s].src_mac   = 48'h02_a5_02_00_00_01;
            flow_rows[s].dst_mac   = 48'h02_a5_02_00_00_02;
            flow_rows[s].vlan_en   = 1'b0;
            flow_rows[s].vlan_id   = 12'd100;
            flow_rows[s].src_ipv4  = 32'hC000_0201;
            flow_rows[s].dst_ipv4  = 32'hC000_0202;
            flow_rows[s].udp_sp    = 16'd49152;
            flow_rows[s].udp_dp    = 16'd50001;
        end
        cls_table = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------- scenario 1: loopback ----------------
        scenario = "loopback";
        // gen[0] carries GLOBAL_FLOW_ID = 1; match it into checker flow 0.
        cls_table[1].enable             = 1'b1;
        cls_table[1].action             = PW_ACT_TEST_RX;
        cls_table[1].priority_          = 8'd5;
        cls_table[1].local_flow_id      = 32'd0;
        cls_table[1].mask.match_udp_dst = 1'b1;
        cls_table[1].mask.match_is_test = 1'b1;
        cls_table[1].mask.match_flow_id = 1'b1;
        cls_table[1].key.udp_dst        = 16'd50001;
        cls_table[1].key.test_flow_id   = 32'd1;

        lb_en     = 1'b1;
        flow_rows[0].valid = 1'b1;
        repeat (400) @(posedge clk);
        flow_rows[0].valid = 1'b0;
        repeat (24) @(posedge clk);   // drain the last looped frame (keep lb_en) so
        lb_en     = 1'b0;             // dropping lb_en never cuts a partial frame
        repeat (4) @(posedge clk);

        check_eq("loopback rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        check_eq("loopback lost ", flow_lost[0], 0);
        check_eq("loopback ooo  ", flow_ooo[0], 0);
        check_eq("loopback samples == rx", flow_samples[0], flow_rx[0]);
        check_eq("loopback min <= max",
                 (flow_min_lat[0] <= flow_max_lat[0]) ? 1 : 0, 1);
        begin
            int nonzero;
            logic [63:0] hb;
            nonzero = 0;
            // Read flow 0's buckets live via the BRAM read port (flat
            // address = flow*BUCKETS + bucket; registered, 1-cycle).
            for (int j = 0; j < BUCKETS; j++) begin
                hist_rd_addr = 16'(j);
                @(posedge clk);
                @(posedge clk);
                hb = hist_rd_data;
                if (hb > 0) nonzero++;
            end
            check_eq("loopback histogram has buckets", (nonzero > 0) ? 1 : 0, 1);
        end

        // ---------------- scenario 2: loss ----------------
        scenario = "loss";
        cls_table[2].enable             = 1'b1;
        cls_table[2].action             = PW_ACT_TEST_RX;
        cls_table[2].priority_          = 8'd5;
        cls_table[2].local_flow_id      = 32'd1;
        cls_table[2].mask.match_udp_dst = 1'b1;
        cls_table[2].mask.match_is_test = 1'b1;
        cls_table[2].mask.match_flow_id = 1'b1;
        cls_table[2].key.udp_dst        = 16'd50001;
        cls_table[2].key.test_flow_id   = 32'd9;
        @(posedge clk);

        for (int s = 0; s < 5; s++) inject_test(1, 32'd9, 64'(s));
        repeat (8) @(posedge clk);
        check_eq("pre-gap rx",   flow_rx[1],   5);
        check_eq("pre-gap lost", flow_lost[1], 0);

        // jump 4 -> 10: 5 missing
        for (int s = 10; s < 13; s++) inject_test(1, 32'd9, 64'(s));
        repeat (8) @(posedge clk);
        check_eq("post-gap rx",   flow_rx[1],   8);
        check_eq("post-gap lost", flow_lost[1], 5);

        // ---------------- scenario 3: dup ----------------
        scenario = "dup";
        inject_test(1, 32'd9, 64'd12);
        repeat (8) @(posedge clk);
        check_eq("dup count", flow_dup[1], 1);

        // ---------------- scenario 4: out-of-order ----------------
        scenario = "ooo";
        cls_table[3].enable             = 1'b1;
        cls_table[3].action             = PW_ACT_TEST_RX;
        cls_table[3].priority_          = 8'd5;
        cls_table[3].local_flow_id      = 32'd3;
        cls_table[3].mask.match_udp_dst = 1'b1;
        cls_table[3].mask.match_is_test = 1'b1;
        cls_table[3].mask.match_flow_id = 1'b1;
        cls_table[3].key.udp_dst        = 16'd50001;
        cls_table[3].key.test_flow_id   = 32'd30;
        @(posedge clk);

        for (int s = 0; s < 4; s++) inject_test(1, 32'd30, 64'(s));
        inject_test(1, 32'd30, 64'd5);  // jump ahead
        inject_test(1, 32'd30, 64'd4);  // come back
        repeat (8) @(posedge clk);
        check_eq("ooo rx ",  flow_rx[3],   6);
        check_eq("ooo lost", flow_lost[3], 1);
        check_eq("ooo ooo ", flow_ooo[3],  1);
        check_eq("ooo dup ", flow_dup[3],  0);

        // ---------------- scenario 5: token-bucket rate ----------------
        scenario = "rate";
        cls_table[1].enable             = 1'b0;   // free up gen[0]'s flow_id=1
        cls_table[4].enable             = 1'b1;
        cls_table[4].action             = PW_ACT_TEST_RX;
        cls_table[4].priority_          = 8'd5;
        cls_table[4].local_flow_id      = 32'd4;
        cls_table[4].mask.match_udp_dst = 1'b1;
        cls_table[4].mask.match_is_test = 1'b1;
        cls_table[4].mask.match_flow_id = 1'b1;
        cls_table[4].key.udp_dst        = 16'd50001;
        cls_table[4].key.test_flow_id   = 32'd1;   // gen[0]
        flow_rows[0].tokens_fp = 32'h00040000;  // 4.0 B/cyc
        flow_rows[0].burst     = 16'd256;
        @(posedge clk);

        lb_en     = 1'b1;
        flow_rows[0].valid = 1'b1;
        repeat (200) @(posedge clk);
        flow_rows[0].valid = 1'b0;
        repeat (24) @(posedge clk);   // drain the last looped frame (keep lb_en) so
        lb_en     = 1'b0;             // dropping lb_en never cuts a partial frame
        repeat (4) @(posedge clk);
        // 74-byte frames, ~4 B/cyc over 200 cyc -> ~10 frames; window [4,16]
        check_eq("rate rx >= 4",  (flow_rx[4] >= 4)  ? 1 : 0, 1);
        check_eq("rate rx <= 16", (flow_rx[4] <= 16) ? 1 : 0, 1);
        check_eq("rate lost==0",  flow_lost[4], 0);

        // ---------------- scenario 6: drop ----------------
        scenario = "drop";
        begin
            logic [31:0] pre_drops;
            pre_drops = port_drops[0];
            build_plain_udp(16'd80);   // matches no rule -> default DROP
            inject(0);
            repeat (8) @(posedge clk);
            check_eq("port0 drop ticked", port_drops[0], pre_drops + 1);
        end

        // ---------------- scenario 7: FORWARD_PORT (port0 -> egress1) ----
        scenario = "forward";
        tx1_data.delete(); tx1_keep.delete(); tx1_last.delete();
        pn_data.delete();  pn_keep.delete();  pn_last.delete();
        cls_table[5].enable                  = 1'b1;
        cls_table[5].action                  = PW_ACT_FORWARD_PORT;
        cls_table[5].priority_               = 8'd8;
        cls_table[5].egress_port             = 4'd1;
        cls_table[5].mask.match_ingress_port = 1'b1;
        cls_table[5].mask.match_udp_dst      = 1'b1;
        cls_table[5].key.ingress_port        = 4'd0;
        cls_table[5].key.udp_dst             = 16'd60000;
        @(posedge clk);

        build_plain_udp(16'd60000);
        inject(0);
        repeat (16) @(posedge clk);
        check_eq("forward tx1 bytes", qbytes(tx1_keep), 42);
        check_eq("forward tx1 saw last",
                 (tx1_last.size() > 0 && tx1_last[tx1_last.size()-1]) ? 1 : 0, 1);
        if (tx1_data.size() > 0)
            check_eq("forward dst-mac byte0", tx1_data[0][7:0], 8'h02);
        check_eq("forward not punted", pn_keep.size(), 0);

        // ---------------- scenario 8: PUNT_TO_HOST -----------------------
        scenario = "punt";
        tx1_data.delete(); tx1_keep.delete(); tx1_last.delete();
        pn_data.delete();  pn_keep.delete();  pn_last.delete();
        cls_table[6].enable             = 1'b1;
        cls_table[6].action             = PW_ACT_PUNT_TO_HOST;
        cls_table[6].priority_          = 8'd8;
        cls_table[6].logical_if_id      = 32'h0000_1234;   // carried out on punt tuser
        cls_table[6].mask               = '0;
        cls_table[6].mask.match_udp_dst = 1'b1;
        cls_table[6].key.udp_dst        = 16'd179;
        @(posedge clk);

        build_plain_udp(16'd179);
        inject(0);
        repeat (16) @(posedge clk);
        check_eq("punt bytes", qbytes(pn_keep), 42);
        check_eq("punt saw last",
                 (pn_last.size() > 0 && pn_last[pn_last.size()-1]) ? 1 : 0, 1);
        check_eq("punt not forwarded", qbytes(tx1_keep), 0);
        // metadata: ingress port 0, logical_if_id 0x1234
        check_eq("punt tuser lif",     pn_user_last[31:0], 32'h0000_1234);
        check_eq("punt tuser ingress", pn_user_last[35:32], 0);

        // ---------------- scenario 9: MIRROR_TO_HOST -> punt -------------
        scenario = "mirror";
        tx1_data.delete(); tx1_keep.delete(); tx1_last.delete();
        pn_data.delete();  pn_keep.delete();  pn_last.delete();
        cls_table[6].action      = PW_ACT_MIRROR_TO_HOST;
        cls_table[6].key.udp_dst = 16'd180;
        @(posedge clk);

        build_plain_udp(16'd180);
        inject(0);
        repeat (16) @(posedge clk);
        check_eq("mirror bytes", qbytes(pn_keep), 42);
        check_eq("mirror saw last",
                 (pn_last.size() > 0 && pn_last[pn_last.size()-1]) ? 1 : 0, 1);

        // ---------------- scenario 10: bidirectional dual-flow ----------
        // gen[0] -> rx[1] (flow_id 1 -> local 0) AND gen[1] -> rx[0]
        // (flow_id 2 -> local 1) at once. With per-port checkers neither
        // direction starves: both must count with lost==0. (The old single
        // arbiter starved the lower-index port here.)
        scenario = "bidir";
        cls_table = '0;
        cls_table[1].enable             = 1'b1;
        cls_table[1].action             = PW_ACT_TEST_RX;
        cls_table[1].priority_          = 8'd5;
        cls_table[1].local_flow_id      = 32'd0;
        cls_table[1].mask.match_udp_dst = 1'b1;
        cls_table[1].mask.match_is_test = 1'b1;
        cls_table[1].mask.match_flow_id = 1'b1;
        cls_table[1].key.udp_dst        = 16'd50001;
        cls_table[1].key.test_flow_id   = 32'd1;     // gen[0]
        cls_table[2].enable             = 1'b1;
        cls_table[2].action             = PW_ACT_TEST_RX;
        cls_table[2].priority_          = 8'd5;
        cls_table[2].local_flow_id      = 32'd1;
        cls_table[2].mask.match_udp_dst = 1'b1;
        cls_table[2].mask.match_is_test = 1'b1;
        cls_table[2].mask.match_flow_id = 1'b1;
        cls_table[2].key.udp_dst        = 16'd50001;
        cls_table[2].key.test_flow_id   = 32'd2;     // gen[1]
        @(posedge clk);

        // Warm up, sample counters, run a measurement window, sample again.
        // With per-port checkers the steady-state loss is ZERO on BOTH
        // directions (the old single arbiter starved flow1 to ~2%, with
        // lost growing every cycle). A small constant startup gap (pipeline
        // + loopback fill) is expected and excluded by the delta.
        begin
            longint rx0_a, rx1_a, lost0_a, lost1_a;
            flow_rows[0].valid = 1'b1; flow_rows[1].valid = 1'b1;
            lb_en = 1'b1; bidir_en = 1'b1;
            repeat (800) @(posedge clk);            // warm up
            rx0_a = flow_rx[0]; rx1_a = flow_rx[1];
            lost0_a = flow_lost[0]; lost1_a = flow_lost[1];
            repeat (2000) @(posedge clk);           // measurement window
            $display("[bidir] flow0 rx %0d->%0d lost %0d->%0d | flow1 rx %0d->%0d lost %0d->%0d",
                     rx0_a, flow_rx[0], lost0_a, flow_lost[0],
                     rx1_a, flow_rx[1], lost1_a, flow_lost[1]);
            flow_rows[0].valid = 1'b0; flow_rows[1].valid = 1'b0;
            lb_en = 1'b0; bidir_en = 1'b0;
            repeat (8) @(posedge clk);

            // Both directions keep receiving through the window...
            check_eq("bidir flow0 rx grew",  (flow_rx[0] > rx0_a) ? 1 : 0, 1);
            check_eq("bidir flow1 rx grew",  (flow_rx[1] > rx1_a) ? 1 : 0, 1);
            // ...with NO ongoing loss on either (steady-state loss == 0).
            check_eq("bidir flow0 no new loss", flow_lost[0] - lost0_a, 0);
            check_eq("bidir flow1 no new loss", flow_lost[1] - lost1_a, 0);
        end

        // ---------------- scenario 11: soft counter clear ----------------
        // The bidir run left flow0/flow1 counters non-zero. A stats_clear
        // pulse must zero all per-flow counters (re-baseline), as `test arm`
        // does on hardware.
        scenario = "clear";
        check_eq("pre-clear flow0 rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        stats_clear = 1'b1;
        @(posedge clk);
        stats_clear = 1'b0;
        repeat (4) @(posedge clk);
        check_eq("clear flow0 rx==0",      flow_rx[0],      0);
        check_eq("clear flow0 lost==0",    flow_lost[0],    0);
        check_eq("clear flow0 samples==0", flow_samples[0], 0);
        check_eq("clear flow1 rx==0",      flow_rx[1],      0);

        // ---------------- scenario 12: data-plane soft reset ----------------
        // Pulse dp_soft_rst mid-traffic and confirm the datapath recovers:
        // the generator / SAF / arbiters reset, then traffic resumes from the
        // intact flow config (no hang). flow0 loopback (cls_table[1]) is still
        // configured from scenario 1.
        scenario = "soft_rst";
        lb_en              = 1'b1;
        flow_rows[0].valid = 1'b1;
        repeat (200) @(posedge clk);
        begin
            longint rx_before;
            rx_before = flow_rx[0];
            check_eq("soft_rst pre rx > 0", (rx_before > 0) ? 1 : 0, 1);
            // Soft-reset the datapath while traffic is flowing.
            dp_soft_rst = 1'b1;
            @(posedge clk);
            dp_soft_rst = 1'b0;
            repeat (16) @(posedge clk);   // ride out the 8-cycle internal reset
            // The gen restarts its sequence at 0; re-baseline the checker so the
            // sequence discontinuity isn't counted as loss, then measure.
            stats_clear = 1'b1;
            @(posedge clk);
            stats_clear = 1'b0;
            repeat (300) @(posedge clk);
            check_eq("soft_rst traffic resumed", (flow_rx[0] > 0) ? 1 : 0, 1);
            check_eq("soft_rst no loss after",   flow_lost[0], 0);
        end
        flow_rows[0].valid = 1'b0;
        repeat (24) @(posedge clk);
        lb_en = 1'b0;

        // ---------------- scenario 12: slow-path TX inject --------------
        // Drive the inject AXIS source targeting egress 1 (no flows, no
        // loopback -> egress 1 idle, so inject wins the arbiter). Verify
        // the injected frame appears on m_axis_tx[1].
        scenario = "inject";
        for (int i = 0; i < FLOWS; i++) flow_rows[i].valid = 1'b0;
        tx1_data.delete(); tx1_keep.delete(); tx1_last.delete();
        repeat (8) @(posedge clk);
        txinj_egress = 4'd1;
        // beat 0
        @(negedge clk);
        txinj_tdata = 64'hA1A2A3A4A5A6A7A8; txinj_tkeep = 8'hFF; txinj_tlast = 1'b0; txinj_tvalid = 1'b1;
        do @(posedge clk); while (!txinj_tready);
        // beat 1 (last, 4 valid bytes)
        @(negedge clk);
        txinj_tdata = 64'h00000000B1B2B3B4; txinj_tkeep = 8'h0F; txinj_tlast = 1'b1;
        do @(posedge clk); while (!txinj_tready);
        @(negedge clk); txinj_tvalid = 1'b0; txinj_tlast = 1'b0;
        repeat (8) @(posedge clk);
        check_eq("inject beats on tx1",  tx1_data.size(), 2);
        if (tx1_data.size() >= 2) begin
            check_eq("inject tx1 beat0",  tx1_data[0], 64'hA1A2A3A4A5A6A7A8);
            check_eq("inject tx1 beat1",  tx1_data[1][31:0], 32'hB1B2B3B4);
            check_eq("inject tx1 last@1", tx1_last[1], 1);
            check_eq("inject tx1 keep@1", tx1_keep[1], 8'h0F);
        end

        if (errors == 0) begin
            $display("ALL DATA PLANE AXIS SCENARIOS PASS");
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
