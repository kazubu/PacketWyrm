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
    logic        tx_tuser  [PORTS];   // generator-test-frame marker

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

    // flow gen control: the flow table is BRAM-backed inside the data plane and
    // programmed via the CSR write strobe + commit (commit_flows below encodes
    // flow_rows[] back to wire bytes and walks them in). Slot 0 -> egress 0
    // (flow_id 1), slot 1 -> egress 1 (flow_id 2); .valid toggles each generator.
    pw_flow_row_t flow_rows [FLOWS];
    logic         flow_wr_en   = 1'b0;
    logic [15:0]  flow_wr_addr = 16'h0;
    logic [31:0]  flow_wr_data = 32'h0;
    // TEST_RX flow-id map programming (additive: default off -> classifier-only).
    logic        map_wr_en    = 1'b0;
    logic [7:0]  map_wr_addr  = 8'h0;     // MAP_DEPTH=256 default
    logic        map_wr_valid = 1'b0;
    logic [$clog2(FLOWS)-1:0] map_wr_lfid = '0;
    // Unified field+UDF classifier programming.
    localparam int NCMP  = 12;
    localparam int NUDF  = 2;
    localparam int NRULE = 32;
    localparam int NTOTAL = NCMP + NUDF;
    logic                      cmp_wr_en     = 1'b0;
    logic [$clog2(NCMP)-1:0]   cmp_wr_idx    = '0;
    logic [4:0]                cmp_wr_src    = '0;
    logic [31:0]               cmp_wr_mask   = '0;
    logic [31:0]               cmp_wr_value  = '0;
    logic                      udf_wr_en     = 1'b0;
    logic [$clog2(NUDF)-1:0]   udf_wr_idx    = '0;
    logic [15:0]               udf_wr_offset = '0;
    logic [31:0]               udf_wr_mask   = '0;
    logic [31:0]               udf_wr_value  = '0;
    logic                      rule_wr_en      = 1'b0;
    logic [$clog2(NRULE)-1:0]  rule_wr_idx     = '0;
    logic [NTOTAL-1:0]         rule_wr_care    = '0;
    logic [2:0]                rule_wr_action  = '0;
    logic [3:0]                rule_wr_egress  = '0;
    logic [31:0]               rule_wr_lfid    = '0;
    logic [31:0]               rule_wr_lif     = '0;
    logic [7:0]                rule_wr_prio    = '0;
    logic                      rule_wr_enable  = 1'b0;
    // Hash exact classifier programming.
    localparam int HASH_DEPTH = 128;
    localparam int HIDX_W = $clog2(HASH_DEPTH);
    logic [31:0]               hash_seed       = 32'h9E3779B1;
    logic [351:0]              hash_mask       = '1;     // exact (key everything)
    logic                      hash_wr_en      = 1'b0;
    logic [HIDX_W-1:0]         hash_wr_index   = '0;
    logic                      hash_wr_valid   = 1'b0;
    logic [351:0]              hash_wr_key     = '0;
    logic [$clog2(FLOWS)-1:0]  hash_wr_lfid    = '0;
    localparam logic [15:0] FBASE   = 16'h6000;          // FLOW_WIN_BASE
    localparam logic [15:0] FCOMMIT = FBASE + 16'h3FFC;

    // tb-side shadow arrays, filled by snap_all() from the BRAM read port.
    logic [63:0] flow_rx        [FLOWS];
    logic [63:0] flow_lost      [FLOWS];
    logic [63:0] flow_dup       [FLOWS];
    logic [63:0] flow_ooo       [FLOWS];
    logic [63:0] flow_last_seq  [FLOWS];
    logic [63:0] flow_min_lat   [FLOWS];
    logic [63:0] flow_max_lat   [FLOWS];
    logic [63:0] flow_sum_lat   [FLOWS];
    logic [63:0] flow_samples   [FLOWS];
    logic [31:0] flow_jit_min   [FLOWS];
    logic [31:0] flow_jit_max   [FLOWS];
    logic [63:0] flow_jit_sum   [FLOWS];
    logic [47:0] flow_tx_d      [FLOWS];
    // scalar dut read port (merged record for flow_rd_addr).
    logic [$clog2(FLOWS)-1:0] flow_rd_addr = '0;
    logic [63:0] dp_rx, dp_lost, dp_dup, dp_ooo, dp_lseq, dp_minl, dp_maxl, dp_suml, dp_samp, dp_jsum;
    logic [31:0] dp_jmin, dp_jmax;
    logic [47:0] dp_tx;
    logic [15:0] hist_rd_addr = 16'h0;
    logic [63:0] hist_rd_data;
    logic [31:0] port_drops     [PORTS];
    logic [31:0] drop_nomatch   [PORTS];
    logic [31:0] drop_saf       [PORTS];
    logic [31:0] last_drop_ctx  [PORTS];
    logic [31:0] last_drop_fid  [PORTS];
    logic [47:0] rxf_d [PORTS], rxb_d [PORTS], txf_d [PORTS], txb_d [PORTS];
    logic        rx_tuser   [PORTS];
    logic        link_up_dp [PORTS];
    logic        block_lock_dp [PORTS];
    logic [47:0] fcs_d  [PORTS];
    logic [31:0] luc_d  [PORTS], ldc_d [PORTS], bllc_d [PORTS];

    // RX ingress wire-timestamp, emulating the board top: latch ts at each
    // frame's SOF beat, present it (constant) across the frame. Same SOF
    // reference the generator stamps tx_timestamp with -> checker latency is
    // wire-to-wire (RX_SOF - TX_SOF).
    logic [63:0] rx_wire_ts  [PORTS];
    logic        rx_wts_inf  [PORTS] = '{default: 1'b0};
    logic [63:0] rx_wts_hld  [PORTS] = '{default: '0};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < PORTS; p++) begin rx_wts_inf[p] <= 1'b0; rx_wts_hld[p] <= '0; end
        end else begin
            for (int p = 0; p < PORTS; p++) if (rx_tvalid[p]) begin
                if (!rx_wts_inf[p]) rx_wts_hld[p] <= ts;
                rx_wts_inf[p] <= !rx_tlast[p];
            end
        end
    end
    always_comb
        for (int p = 0; p < PORTS; p++)
            rx_wire_ts[p] = rx_wts_inf[p] ? rx_wts_hld[p] : ts;

    pw_data_plane_axis #(
        .PW_PORTS         (PORTS),
        .PW_NUM_FLOWS     (FLOWS),
        .PW_NUM_BUCKETS   (BUCKETS),
        .HDR_BYTES        (100),
        .NCMP             (NCMP),
        .NUDF             (NUDF),
        .NRULE            (NRULE),
        .HASH_DEPTH       (HASH_DEPTH),
        .FRAME_LEN_PAYLOAD(32)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .timestamp_i      (ts),
        // per-flow lat correction table left unwritten -> all slots 0 (same-card,
        // unchanged path); the per-flow correction itself is covered in sim by
        // tb_test_rx_checker_bram (nonzero lat_correction_i case).
        .lat_corr_wr_en_i (1'b0),
        .lat_corr_wr_slot_i('0),
        .lat_corr_wr_data_i(64'd0),
        .stats_clear_i    (stats_clear),
        .dp_soft_rst_i    (dp_soft_rst),
        .s_axis_rx_tdata  (rx_tdata),
        .s_axis_rx_tkeep  (rx_tkeep),
        .s_axis_rx_tvalid (rx_tvalid),
        .s_axis_rx_tready (rx_tready),
        .s_axis_rx_tlast  (rx_tlast),
        .s_axis_rx_tuser  (rx_tuser),
        .s_axis_rx_wire_ts(rx_wire_ts),
        .link_up_i        (link_up_dp),
        .block_lock_i     (block_lock_dp),
        .m_axis_tx_tdata  (tx_tdata),
        .m_axis_tx_tkeep  (tx_tkeep),
        .m_axis_tx_tvalid (tx_tvalid),
        .m_axis_tx_tready (tx_tready),
        .m_axis_tx_tlast  (tx_tlast),
        .m_axis_tx_tuser  (tx_tuser),
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
        .flow_wr_en_i     (flow_wr_en),
        .flow_wr_addr_i   (flow_wr_addr),
        .flow_wr_data_i   (flow_wr_data),
        .map_wr_en_i      (map_wr_en),
        .map_wr_addr_i    (map_wr_addr),
        .map_wr_valid_i   (map_wr_valid),
        .map_wr_lfid_i    (map_wr_lfid),
        .cmp_wr_en_i      (cmp_wr_en),
        .cmp_wr_idx_i     (cmp_wr_idx),
        .cmp_wr_src_i     (cmp_wr_src),
        .cmp_wr_mask_i    (cmp_wr_mask),
        .cmp_wr_value_i   (cmp_wr_value),
        .udf_wr_en_i      (udf_wr_en),
        .udf_wr_idx_i     (udf_wr_idx),
        .udf_wr_offset_i  (udf_wr_offset),
        .udf_wr_mask_i    (udf_wr_mask),
        .udf_wr_value_i   (udf_wr_value),
        .rule_wr_en_i     (rule_wr_en),
        .rule_wr_idx_i    (rule_wr_idx),
        .rule_wr_care_i   (rule_wr_care),
        .rule_wr_action_i (rule_wr_action),
        .rule_wr_egress_i (rule_wr_egress),
        .rule_wr_lfid_i   (rule_wr_lfid),
        .rule_wr_lif_i    (rule_wr_lif),
        .rule_wr_prio_i   (rule_wr_prio),
        .rule_wr_enable_i (rule_wr_enable),
        .hash_seed_i      (hash_seed),
        .hash_mask_i      (hash_mask),
        .hash_wr_en_i     (hash_wr_en),
        .hash_wr_index_i  (hash_wr_index),
        .hash_wr_valid_i  (hash_wr_valid),
        .hash_wr_key_i    (hash_wr_key),
        .hash_wr_lfid_i   (hash_wr_lfid),
        .flow_rd_addr_i   (flow_rd_addr),
        .flow_rx          (dp_rx),
        .flow_lost        (dp_lost),
        .flow_dup         (dp_dup),
        .flow_ooo         (dp_ooo),
        .flow_last_seq    (dp_lseq),
        .flow_min_lat     (dp_minl),
        .flow_max_lat     (dp_maxl),
        .flow_sum_lat     (dp_suml),
        .flow_samples     (dp_samp),
        .flow_jit_min     (dp_jmin),
        .flow_jit_max     (dp_jmax),
        .flow_jit_sum     (dp_jsum),
        .flow_tx          (dp_tx),
        .hist_rd_addr_i   (hist_rd_addr),
        .hist_rd_data_o   (hist_rd_data),
        .port_drops_o     (port_drops),
        .drop_nomatch_o   (drop_nomatch),
        .drop_saf_o       (drop_saf),
        .last_drop_ctx_o  (last_drop_ctx),
        .last_drop_fid_o  (last_drop_fid),
        .rx_frames_o      (rxf_d),
        .rx_bytes_o       (rxb_d),
        .tx_frames_o      (txf_d),
        .tx_bytes_o       (txb_d),
        .rx_fcs_error_o   (fcs_d),
        .link_up_cnt_o    (luc_d),
        .link_down_cnt_o  (ldc_d),
        .block_lock_loss_o(bllc_d),
        .err_sticky_o     (),
        .activity_o       ()
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

    // Walk the BRAM read port into the tb-side shadow arrays (mirrors what
    // pw_stats_snapshot does on a trigger). flow_* is valid 2 cycles after
    // flow_rd_addr; wait a little extra for margin.
    task automatic snap_all();
        for (int f = 0; f < FLOWS; f++) begin
            @(posedge clk); flow_rd_addr = f[$clog2(FLOWS)-1:0];
            repeat (3) @(posedge clk);
            flow_rx[f]=dp_rx; flow_lost[f]=dp_lost; flow_dup[f]=dp_dup; flow_ooo[f]=dp_ooo;
            flow_last_seq[f]=dp_lseq; flow_min_lat[f]=dp_minl; flow_max_lat[f]=dp_maxl;
            flow_sum_lat[f]=dp_suml; flow_samples[f]=dp_samp;
            flow_jit_min[f]=dp_jmin; flow_jit_max[f]=dp_jmax; flow_jit_sum[f]=dp_jsum;
            flow_tx_d[f]=dp_tx;
        end
    endtask

    // ----- flow-table programming: encode flow_rows[] to wire bytes and drive
    // the CSR write strobe + commit (the BRAM table walks them in on commit).
    task automatic csr_w(input logic [15:0] a, input logic [31:0] d);
        @(posedge clk); flow_wr_en = 1'b1; flow_wr_addr = a; flow_wr_data = d;
        @(posedge clk); flow_wr_en = 1'b0; flow_wr_addr = 16'h0; flow_wr_data = 32'h0;
    endtask
    task automatic prog_row(input int idx);
        logic [7:0] rb [256];
        logic [15:0] base;
        for (int i = 0; i < 256; i++) rb[i] = 8'h0;
        rb[0]  = flow_rows[idx].valid;          // enable = the on/off toggle
        rb[90] = 8'd1;                           // tx_enable always on (valid = enable & tx_enable)
        rb[1]  = {4'h0, flow_rows[idx].egress};
        rb[2]=flow_rows[idx].flow_id[7:0];   rb[3]=flow_rows[idx].flow_id[15:8];
        rb[4]=flow_rows[idx].flow_id[23:16]; rb[5]=flow_rows[idx].flow_id[31:24];
        rb[14]=flow_rows[idx].dst_mac[47:40]; rb[15]=flow_rows[idx].dst_mac[39:32];
        rb[16]=flow_rows[idx].dst_mac[31:24]; rb[17]=flow_rows[idx].dst_mac[23:16];
        rb[18]=flow_rows[idx].dst_mac[15:8];  rb[19]=flow_rows[idx].dst_mac[7:0];
        rb[20]=flow_rows[idx].src_mac[47:40]; rb[21]=flow_rows[idx].src_mac[39:32];
        rb[22]=flow_rows[idx].src_mac[31:24]; rb[23]=flow_rows[idx].src_mac[23:16];
        rb[24]=flow_rows[idx].src_mac[15:8];  rb[25]=flow_rows[idx].src_mac[7:0];
        rb[26]={7'h0, flow_rows[idx].vlan_en};
        rb[27]=flow_rows[idx].vlan_id[7:0];  rb[28]={4'h0, flow_rows[idx].vlan_id[11:8]};
        rb[30]= flow_rows[idx].is_v6 ? 8'd6 : 8'd4;
        rb[31]=flow_rows[idx].src_ipv4[7:0];  rb[32]=flow_rows[idx].src_ipv4[15:8];
        rb[33]=flow_rows[idx].src_ipv4[23:16];rb[34]=flow_rows[idx].src_ipv4[31:24];
        rb[35]=flow_rows[idx].dst_ipv4[7:0];  rb[36]=flow_rows[idx].dst_ipv4[15:8];
        rb[37]=flow_rows[idx].dst_ipv4[23:16];rb[38]=flow_rows[idx].dst_ipv4[31:24];
        rb[41]=flow_rows[idx].udp_sp[7:0];   rb[42]=flow_rows[idx].udp_sp[15:8];
        rb[43]=flow_rows[idx].udp_dp[7:0];   rb[44]=flow_rows[idx].udp_dp[15:8];
        rb[75]=flow_rows[idx].tokens_fp[7:0];   rb[76]=flow_rows[idx].tokens_fp[15:8];
        rb[77]=flow_rows[idx].tokens_fp[23:16]; rb[78]=flow_rows[idx].tokens_fp[31:24];
        rb[79]=flow_rows[idx].burst[7:0];    rb[80]=flow_rows[idx].burst[15:8];
        base = FBASE + 16'(idx*256);
        for (int w = 0; w < 64; w++)
            csr_w(base + 16'(w*4), {rb[w*4+3], rb[w*4+2], rb[w*4+1], rb[w*4+0]});
    endtask
    // Re-stage slots 0/1 (the only ones this tb uses) and commit; wait for walk.
    task automatic commit_flows();
        prog_row(0); prog_row(1);
        csr_w(FCOMMIT, 32'h1);
        // BRAM-staged flow table: the commit walk reads the staging one 32-bit
        // word per cycle, so it takes FLOWS*ROW_DW (=64) cycles, not FLOWS.
        repeat (FLOWS*64 + 16) @(posedge clk);
    endtask
    // Fast enable/disable: rewrite only word 0 (enable byte, preserving
    // egress/flow_id) + commit. Used where the generation window must end
    // promptly (a full commit_flows() write phase would keep the live table
    // valid for ~128 extra cycles, inflating rate measurements).
    task automatic set_enable(input int idx, input bit en);
        csr_w(FBASE + 16'(idx*256),
              {flow_rows[idx].flow_id[15:8], flow_rows[idx].flow_id[7:0],
               {4'h0, flow_rows[idx].egress}, {7'h0, en}});
        csr_w(FCOMMIT, 32'h1);
        // BRAM-staged flow table: the commit walk reads the staging one 32-bit
        // word per cycle, so it takes FLOWS*ROW_DW (=64) cycles, not FLOWS.
        repeat (FLOWS*64 + 16) @(posedge clk);
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

    // Program a TEST_RX flow-id map entry: test_flow_id `fid` -> checker slot `lf`.
    task automatic prog_map(input int fid, input int lf);
        @(negedge clk);
        map_wr_en = 1'b1; map_wr_addr = fid[7:0];
        map_wr_valid = 1'b1; map_wr_lfid = lf[$clog2(FLOWS)-1:0];
        @(negedge clk); map_wr_en = 1'b0; map_wr_valid = 1'b0;
    endtask

    // Field+UDF classifier programming.
    task automatic prog_cmp(input int idx, input int src,
                            input logic [31:0] mask, input logic [31:0] val);
        @(negedge clk);
        cmp_wr_en=1'b1; cmp_wr_idx=idx[$clog2(NCMP)-1:0]; cmp_wr_src=src[4:0];
        cmp_wr_mask=mask; cmp_wr_value=val;
        @(negedge clk); cmp_wr_en=1'b0;
    endtask
    task automatic prog_udf(input int idx, input int off,
                            input logic [31:0] mask, input logic [31:0] val);
        @(negedge clk);
        udf_wr_en=1'b1; udf_wr_idx=idx[$clog2(NUDF)-1:0]; udf_wr_offset=off[15:0];
        udf_wr_mask=mask; udf_wr_value=val;
        @(negedge clk); udf_wr_en=1'b0;
    endtask
    task automatic prog_rule(input int idx, input logic [NTOTAL-1:0] care,
                             input int act, input int egr, input int lf, input int lif, input int prio);
        @(negedge clk);
        rule_wr_en=1'b1; rule_wr_idx=idx[$clog2(NRULE)-1:0]; rule_wr_care=care;
        rule_wr_action=act[2:0]; rule_wr_egress=egr[3:0];
        rule_wr_lfid=lf; rule_wr_lif=lif; rule_wr_prio=prio[7:0]; rule_wr_enable=1'b1;
        @(negedge clk); rule_wr_en=1'b0;
    endtask
    // Hash exact classifier: compute the bucket with the same hash as the DUT
    // (11 masked words). k is the already-masked 352-bit key.
    function automatic logic [HIDX_W-1:0] hash_idx(input logic [351:0] k);
        logic [31:0] k32, prod; k32 = 0;
        for (int i = 0; i < 11; i++) k32 ^= k[i*32 +: 32];
        prod = k32 * (hash_seed | 32'd1);
        return prod[31 -: HIDX_W];
    endfunction
    task automatic prog_hash(input logic [351:0] k, input int lf);  // k already masked
        @(negedge clk);
        hash_wr_en=1'b1; hash_wr_index=hash_idx(k); hash_wr_valid=1'b1;
        hash_wr_key=k; hash_wr_lfid=lf[$clog2(FLOWS)-1:0];
        @(negedge clk); hash_wr_en=1'b0;
    endtask

    // -------------- main --------------
    initial begin
        lb_en = 1'b0;
        bidir_en = 1'b0;
        for (int p = 0; p < PORTS; p++) begin
            inj_tdata[p]  = '0; inj_tkeep[p] = '0;
            inj_tvalid[p] = 1'b0; inj_tlast[p] = 1'b0;
            tx_tready[p]  = 1'b1;
            rx_tuser[p]   = 1'b0;     // no errored frames in loopback
            link_up_dp[p]    = 1'b1;  // links up, locked
            block_lock_dp[p] = 1'b1;
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
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------- scenario 1: loopback ----------------
        scenario = "loopback";
        // gen[0] carries GLOBAL_FLOW_ID = 1; map it into checker flow 0.
        prog_map(1, 0);

        lb_en     = 1'b1;
        flow_rows[0].valid = 1'b1;
        commit_flows();
        repeat (400) @(posedge clk);
        flow_rows[0].valid = 1'b0;
        commit_flows();
        repeat (24) @(posedge clk);   // drain the last looped frame (keep lb_en) so
        lb_en     = 1'b0;             // dropping lb_en never cuts a partial frame
        repeat (4) @(posedge clk);

        snap_all();
        check_eq("loopback rx > 0", (flow_rx[0] > 0) ? 1 : 0, 1);
        check_eq("loopback lost ", flow_lost[0], 0);
        // per-port counters: gen drives TX[0], loopback feeds RX[1].
        check_eq("port0 tx_frames > 0", (txf_d[0] > 0) ? 1 : 0, 1);
        check_eq("port1 rx_frames > 0", (rxf_d[1] > 0) ? 1 : 0, 1);
        check_eq("port0 tx_bytes > frames", (txb_d[0] > txf_d[0]) ? 1 : 0, 1);
        check_eq("port1 rx_bytes > frames", (rxb_d[1] > rxf_d[1]) ? 1 : 0, 1);
        // per-flow TX counter (gen slot 0) -> true loss = tx - rx >= 0.
        check_eq("flow0 tx_frames > 0",   (flow_tx_d[0] > 0) ? 1 : 0, 1);
        check_eq("flow0 tx >= rx (loss)", (flow_tx_d[0] >= flow_rx[0]) ? 1 : 0, 1);
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
        prog_map(9, 1);
        @(posedge clk);

        for (int s = 0; s < 5; s++) inject_test(1, 32'd9, 64'(s));
        repeat (8) @(posedge clk);
        snap_all();
        check_eq("pre-gap rx",   flow_rx[1],   5);
        check_eq("pre-gap lost", flow_lost[1], 0);

        // jump 4 -> 10: 5 missing
        for (int s = 10; s < 13; s++) inject_test(1, 32'd9, 64'(s));
        repeat (8) @(posedge clk);
        snap_all();
        check_eq("post-gap rx",   flow_rx[1],   8);
        check_eq("post-gap lost", flow_lost[1], 5);

        // ---------------- scenario 3: dup ----------------
        scenario = "dup";
        inject_test(1, 32'd9, 64'd12);
        repeat (8) @(posedge clk);
        snap_all();
        check_eq("dup count", flow_dup[1], 1);

        // ---------------- scenario 4: out-of-order ----------------
        scenario = "ooo";
        prog_map(30, 3);
        @(posedge clk);

        for (int s = 0; s < 4; s++) inject_test(1, 32'd30, 64'(s));
        inject_test(1, 32'd30, 64'd5);  // jump ahead
        inject_test(1, 32'd30, 64'd4);  // come back
        repeat (8) @(posedge clk);
        snap_all();
        check_eq("ooo rx ",  flow_rx[3],   6);
        check_eq("ooo lost", flow_lost[3], 1);
        check_eq("ooo ooo ", flow_ooo[3],  1);
        check_eq("ooo dup ", flow_dup[3],  0);

        // ---------------- scenario 5: token-bucket rate ----------------
        scenario = "rate";
        prog_map(1, 4);                 // re-map gen[0]'s flow_id=1 -> checker slot 4
        flow_rows[0].tokens_fp = 32'h00040000;  // 4.0 B/cyc
        flow_rows[0].burst     = 16'd256;
        commit_flows();
        @(posedge clk);

        lb_en     = 1'b1;
        flow_rows[0].valid = 1'b1;
        set_enable(0, 1'b1);          // fast enable (row already staged above)
        // The BRAM-staged commit walk takes FLOWS*64 cycles, during which the
        // flow is already live and generating, so measure the rate as a DELTA
        // over a fixed window (like the bidir scenario) rather than an absolute
        // count from enable -- the absolute count would include the walk period.
        begin
            longint rx4_a;
            snap_all();
            rx4_a = flow_rx[4];
            repeat (200) @(posedge clk);  // measurement window
            snap_all();
            // 74-byte frames, ~4 B/cyc over 200 cyc -> ~10 frames; window [4,16]
            check_eq("rate rx delta >= 4",  ((flow_rx[4]-rx4_a) >= 4)  ? 1 : 0, 1);
            check_eq("rate rx delta <= 16", ((flow_rx[4]-rx4_a) <= 16) ? 1 : 0, 1);
        end
        flow_rows[0].valid = 1'b0;
        set_enable(0, 1'b0);          // fast disable -> generation stops promptly
        repeat (24) @(posedge clk);   // drain the last looped frame (keep lb_en) so
        lb_en     = 1'b0;             // dropping lb_en never cuts a partial frame
        repeat (4) @(posedge clk);
        snap_all();
        check_eq("rate lost==0",  flow_lost[4], 0);

        // ---------------- scenario 6: drop ----------------
        scenario = "drop";
        begin
            logic [31:0] pre_drops, pre_nomatch, pre_saf;
            pre_drops   = port_drops[0];
            pre_nomatch = drop_nomatch[0];
            pre_saf     = drop_saf[0];
            build_plain_udp(16'd80);   // matches no rule -> default DROP
            inject(0);
            repeat (12) @(posedge clk);   // classifier latency 4 (was 3): wider window
            check_eq("port0 drop ticked", port_drops[0], pre_drops + 1);
            // DROP classification: this is a no-match (not a SAF overflow).
            check_eq("port0 drop_nomatch ticked", drop_nomatch[0], pre_nomatch + 1);
            check_eq("port0 drop_saf unchanged",  drop_saf[0], pre_saf);
            // last-drop context captured the frame: plain IPv4/UDP, not a test
            // frame -> is_test=0 (bit0), is_ipv4=1 (bit1), ethertype 0x0800
            // (bits 23:8), l3_proto 17 (bits 31:24).
            check_eq("last_drop is_test=0", last_drop_ctx[0][0], 1'b0);
            check_eq("last_drop is_ipv4=1", last_drop_ctx[0][1], 1'b1);
            check_eq("last_drop ethertype 0x0800", last_drop_ctx[0][23:8], 16'h0800);
            check_eq("last_drop l3_proto 17 (UDP)", last_drop_ctx[0][31:24], 8'd17);
        end

        // ---------------- scenario 7: FORWARD_PORT (port0 -> egress1) ----
        scenario = "forward";
        tx1_data.delete(); tx1_keep.delete(); tx1_last.delete();
        pn_data.delete();  pn_keep.delete();  pn_last.delete();
        // cmp0 = udp_dst==60000, cmp1 = ingress_port==0; rule0 -> FORWARD egress1.
        prog_cmp(0, 0,  32'h0000_FFFF, 32'd60000);    // src 0 = l4_dst
        prog_cmp(1, 13, 32'h0000_000F, 32'd0);        // src 13 = ingress_port
        prog_rule(0, 14'h003, 4 /*FORWARD*/, 1 /*egr*/, 0, 0, 8);
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
        // cmp2 = udp_dst==179; rule1 -> PUNT, lif 0x1234.
        prog_cmp(2, 0, 32'h0000_FFFF, 32'd179);
        prog_rule(1, 14'h004, 2 /*PUNT*/, 0, 0, 32'h0000_1234, 8);
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
        // re-point cmp2 to udp_dst==180 and rule1 -> MIRROR (still lif 0x1234).
        prog_cmp(2, 0, 32'h0000_FFFF, 32'd180);
        prog_rule(1, 14'h004, 3 /*MIRROR*/, 0, 0, 32'h0000_1234, 8);
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
        prog_map(1, 0);     // gen[0] flow_id 1 -> slot 0
        prog_map(2, 1);     // gen[1] flow_id 2 -> slot 1
        @(posedge clk);

        // Warm up, sample counters, run a measurement window, sample again.
        // With per-port checkers the steady-state loss is ZERO on BOTH
        // directions (the old single arbiter starved flow1 to ~2%, with
        // lost growing every cycle). A small constant startup gap (pipeline
        // + loopback fill) is expected and excluded by the delta.
        begin
            longint rx0_a, rx1_a, lost0_a, lost1_a;
            flow_rows[0].valid = 1'b1; flow_rows[1].valid = 1'b1;
            commit_flows();
            lb_en = 1'b1; bidir_en = 1'b1;
            repeat (800) @(posedge clk);            // warm up
            snap_all();
            rx0_a = flow_rx[0]; rx1_a = flow_rx[1];
            lost0_a = flow_lost[0]; lost1_a = flow_lost[1];
            repeat (2000) @(posedge clk);           // measurement window
            $display("[bidir] flow0 rx %0d->%0d lost %0d->%0d | flow1 rx %0d->%0d lost %0d->%0d",
                     rx0_a, flow_rx[0], lost0_a, flow_lost[0],
                     rx1_a, flow_rx[1], lost1_a, flow_lost[1]);
            flow_rows[0].valid = 1'b0; flow_rows[1].valid = 1'b0;
            commit_flows();
            lb_en = 1'b0; bidir_en = 1'b0;
            repeat (8) @(posedge clk);

            // Both directions keep receiving through the window...
            snap_all();
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
        repeat (FLOWS + 8) @(posedge clk);   // let the checker clear-walk finish
        snap_all();
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
        commit_flows();
        repeat (200) @(posedge clk);
        begin
            longint rx_before;
            snap_all();
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
            snap_all();
            check_eq("soft_rst traffic resumed", (flow_rx[0] > 0) ? 1 : 0, 1);
            check_eq("soft_rst no loss after",   flow_lost[0], 0);
        end
        flow_rows[0].valid = 1'b0;
        commit_flows();
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

        // ---- scenario 13: TEST_RX flow-id map (direct index, no classifier rule) ----
        // flow_id 99 has NO classifier rule -> only the flow-id map can classify
        // it. Program map[99] -> checker slot 6, inject 4 test frames -> counted.
        scenario = "fidmap";
        prog_map(99, 6);
        for (int s = 0; s < 4; s++) inject_test(1, 32'd99, 64'(s));
        repeat (16) @(posedge clk);
        snap_all();
        check_eq("fidmap rx (no cls rule)", flow_rx[6], 4);
        check_eq("fidmap lost",             flow_lost[6], 0);

        // ---- scenario 14: field classifier UDF (header-defined, free payload) ----
        // A PLAIN UDP frame (NO test header / magic / flow_id) is classified into
        // a checker slot purely by its udp_dst via a UDF comparator -- proving
        // header-based, payload-agnostic classification (the flow-id map can't do
        // this, it keys on the test_flow_id in the payload). udp_dst is at
        // inner-base(14) + 22 = abs 36; care bit NCMP+0 selects UDF comparator 0.
        scenario = "slice";
        prog_udf(0, 22, 32'hFFFF_0000, 32'hC357_0000);      // udp_dst == 50007 (0xC357)
        prog_rule(2, (14'h1 << NCMP), 1 /*TEST_RX*/, 0, 5 /*slot*/, 0, 10);
        for (int s = 0; s < 3; s++) begin
            build_plain_udp(16'd50007);
            inject(1);
        end
        repeat (16) @(posedge clk);
        snap_all();
        check_eq("slice rx (header-defined)", flow_rx[5], 3);
        check_eq("slice lost",                flow_lost[5], 0);
        // a non-matching udp_dst must NOT land in slot 5.
        build_plain_udp(16'd40000); inject(1);
        repeat (16) @(posedge clk); snap_all();
        check_eq("slice no false-positive",   flow_rx[5], 3);

        // ---- scenario 15: hash exact classifier (header-keyed, high count) ----
        // A PLAIN UDP frame classified into a slot by an EXACT header-key match
        // via the hash table (payload-agnostic, scales to NUM_FLOWS). The tb
        // computes the bucket with the same hash the DUT uses. build_plain_udp:
        // ipv4_dst=192.0.2.1, udp src=49152, proto=17; key{l3dst,ldst,lsrc,proto}.
        scenario = "hash";
        begin
            // 11 field-aligned words for the plain UDP frame (build_plain_udp:
            // dst 192.0.2.2, src 192.0.2.1, udp src 49152, proto 17, eth 0x0800).
            logic [351:0] hk;
            logic [31:0]  w [11];
            for (int i=0;i<11;i++) w[i]=0;
            w[0]=32'hC000_0202;                       // l3_dst
            w[4]=32'hC000_0201;                       // l3_src
            w[8]={16'd49152, 16'd50123};              // {l4_src, l4_dst}
            w[9]={16'd0, 16'h0800};                   // {vlan, ethertype}
            w[10]=32'd17;                             // proto
            hk={w[10],w[9],w[8],w[7],w[6],w[5],w[4],w[3],w[2],w[1],w[0]};  // mask = all 1s
            prog_hash(hk, 7);                       // -> checker slot 7
            for (int s = 0; s < 4; s++) begin build_plain_udp(16'd50123); inject(1); end
            repeat (16) @(posedge clk); snap_all();
            check_eq("hash rx (exact header key)", flow_rx[7], 4);
            check_eq("hash lost",                  flow_lost[7], 0);
            // a frame with a different dst port -> different key -> not slot 7
            build_plain_udp(16'd50124); inject(1);
            repeat (16) @(posedge clk); snap_all();
            check_eq("hash no false-positive",     flow_rx[7], 4);
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
