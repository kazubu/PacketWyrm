// PacketWyrm Phase 3 data plane -- 64-bit AXIS streaming version.
//
// Production data path that replaces the wide-bus pw_data_plane (which
// synthesised but would not route off the ~12288-bit pw_frame_t bus).
// Orchestrates the streaming building blocks:
//
//   * per ingress port: pw_parser_axis (snoops the RX stream, emits a
//                       registered pw_match_key_t one cycle after EOF)
//                       + pw_field_classifier (field+UDF comparator engine)
//                       + pw_frame_saf (store-and-forward buffer for
//                       FORWARD/PUNT/MIRROR -- the decision lands a
//                       cycle after tlast, so the frame must be buffered)
//   * one pw_test_rx_checker fed by the TEST_RX classification events
//   * per egress port:  pw_flow_gen_axis + a forward/gen TX arbiter
//   * a punt arbiter draining PUNT/MIRROR frames to the punt AXIS master
//   * per-port DROP counters
//
// Action handling:
//   TEST_RX           checker counts; frame consumed (SAF rolls it back)
//   DROP / no match   dropped; port_drops_o ticks; SAF rolls it back
//   FORWARD_PORT      SAF buffers, drains to TX[egress_port] (forward
//                     takes priority over the generator on that port)
//   PUNT_TO_HOST      SAF buffers, drains to the punt AXIS master
//   MIRROR_TO_HOST    treated as PUNT (copy to host), matching the
//                     wide-bus plane's behaviour
//
// Forwarding is store-and-forward with whole-frame drop on buffer
// overflow (pw_frame_saf). Head-of-line: one drain port per ingress, so
// a congested egress blocks later frames behind it -- acceptable for a
// test appliance (no VOQ), documented rather than engineered around.

`default_nettype none

import pw_classifier_pkg::*;
import pw_axis_pkg::*;

module pw_data_plane_axis #(
    parameter int PW_PORTS          = 2,
    parameter int PW_NUM_FLOWS      = 16,
    parameter int PW_NUM_BUCKETS    = 16,
    parameter int HDR_BYTES         = 128,  // parser header-capture depth. Was 160;
                                            // reduced to 128 to relieve parser LUT
                                            // (variable-offset byte muxes scale with
                                            // it) so the IPv6-classifier+modifier
                                            // work fits + meets dp_clk timing. RX
                                            // test-header classification now spans
                                            // <=128 B: non-encap (74) + single-encap
                                            // v4/v6 (<=~118); the deepest v6-in-v6
                                            // encap test header (>128) is not
                                            // RX-classified (TX generation is
                                            // unaffected).
    parameter int FRAME_LEN_PAYLOAD = 32,   // flow_gen L4 payload bytes
    parameter int MAP_DEPTH         = 256,   // TEST_RX flow-id map index range
    parameter int NCMP              = 12,    // field comparators (canonical-field sourced)
    parameter int NUDF              = 2,     // UDF slice comparators (raw window)
    parameter int NRULE             = 32,    // classifier combine rules
    parameter int SLICE_WIN         = 48,    // UDF match window depth
    parameter int HASH_DEPTH        = 128,   // hash exact-table buckets (header-keyed)
    parameter int SAF_DEPTH_BEATS   = 512,   // per-ingress forward buffer (x8 bytes)
    parameter int FLOW_ADDR_W       = 16,    // CSR address width for the flow window
    parameter logic [15:0] FLOW_WIN_BASE      = 16'h6000,   // matches pw_csr_full
    parameter logic [15:0] FLOW_COMMIT_OFFSET = 16'h3FFC
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [63:0]            timestamp_i,

    // Soft clear pulse (from a CSR write): re-baselines all flow checkers.
    input  wire                   stats_clear_i,

    // Data-plane soft reset pulse (from a CSR write): resets the
    // wedge-prone datapath state -- the per-port store-and-forward FIFOs,
    // the multi-flow generators, and the egress/punt arbiters -- so
    // software can recover a wedged data plane (e.g. a flow table
    // reprogrammed mid-transmission) WITHOUT a JTAG reconfig. The
    // configuration (classifier table, flow rows) lives in the CSR domain
    // and is not disturbed, so the data plane restarts from the intact
    // program. Checker counters / histogram are left alone (use
    // stats_clear_i for those).
    input  wire                   dp_soft_rst_i,


    // Per-port AXIS RX (MAC -> data plane ingress). The parser snoops
    // and the SAF drops on overflow, so RX is never backpressured here.
    input  wire [63:0]            s_axis_rx_tdata  [PW_PORTS],
    input  wire [7:0]             s_axis_rx_tkeep  [PW_PORTS],
    input  wire                   s_axis_rx_tvalid [PW_PORTS],
    output logic                  s_axis_rx_tready [PW_PORTS],
    input  wire                   s_axis_rx_tlast  [PW_PORTS],
    // MAC RX tuser asserted on tlast = errored frame (FCS/runt); counted
    // per port as rx_fcs_error. Tie low if the MAC doesn't surface it.
    input  wire                   s_axis_rx_tuser  [PW_PORTS],

    // Per-port AXIS TX (data plane egress -> MAC). Forwarded frames take
    // priority; the per-port flow generator fills idle slots.
    output logic [63:0]           m_axis_tx_tdata  [PW_PORTS],
    output logic [7:0]            m_axis_tx_tkeep  [PW_PORTS],
    output logic                  m_axis_tx_tvalid [PW_PORTS],
    input  wire                   m_axis_tx_tready [PW_PORTS],
    output logic                  m_axis_tx_tlast  [PW_PORTS],
    // tuser = "this egress frame is a generator test frame" (the selected
    // source is the flow generator). Rides the MAC-TX CDC to pw_ts_insert,
    // which uses it (SOF-latched) to gate egress timestamping + the IPv6 UDP
    // checksum fixup -- so forwarded / injected frames are never rewritten.
    // NOTE: this is NOT the MAC's tx-error tuser; pw_ts_insert consumes it.
    output logic                  m_axis_tx_tuser  [PW_PORTS],

    // Punt path (PUNT_TO_HOST / MIRROR_TO_HOST) as a 64-bit AXIS master.
    output logic [63:0]           m_axis_punt_tdata,
    output logic [7:0]            m_axis_punt_tkeep,
    output logic                  m_axis_punt_tvalid,
    input  wire                   m_axis_punt_tready,
    output logic                  m_axis_punt_tlast,
    output logic [99:0]           m_axis_punt_tuser,   // {rx_ts[63:0], ingress[3:0], logical_if_id[31:0]} of head frame

    // Slow-path TX inject (host -> FPGA): one AXIS source mixed into the
    // egress arbiter for the host-selected egress port (priority below
    // forwarded frames, above the generator).
    input  wire [63:0]            s_axis_inj_tdata,
    input  wire [7:0]             s_axis_inj_tkeep,
    input  wire                   s_axis_inj_tvalid,
    output logic                  s_axis_inj_tready,
    input  wire                   s_axis_inj_tlast,
    input  wire [3:0]             s_axis_inj_egress,

    // Flow gen control: the flow table is BRAM-backed here (pw_flow_table_bram),
    // fed by the CSR write strobe (decoded in pw_csr_full, routed through the
    // top). Each egress generator schedules from the compact per-slot array and
    // reads its picked row's wide content from the table BRAM.
    input  wire                   flow_wr_en_i,
    input  wire [FLOW_ADDR_W-1:0] flow_wr_addr_i,
    input  wire [31:0]            flow_wr_data_i,

    // TEST_RX flow-id map programming (pw_flowid_map): a frame's test_flow_id
    // directly indexes the checker slot, replacing per-flow classifier rules so
    // the classifier stays small. Programmed before traffic, like the tables.
    input  wire                              map_wr_en_i,
    input  wire [$clog2(MAP_DEPTH)-1:0]      map_wr_addr_i,
    input  wire                              map_wr_valid_i,
    input  wire [$clog2(PW_NUM_FLOWS)-1:0]   map_wr_lfid_i,

    // Unified field+UDF classifier programming (pw_field_classifier). Replaces
    // the legacy pw_classifier table: comparators source the parser's canonical
    // fields (field comparators) or a raw inner-frame window (UDF comparators);
    // rules combine the comparator bits into {action,egress,lfid,lif}. Same
    // program is broadcast to every port's classifier.
    input  wire                              cmp_wr_en_i,
    input  wire [$clog2(NCMP)-1:0]           cmp_wr_idx_i,
    input  wire [4:0]                        cmp_wr_src_i,
    input  wire [31:0]                       cmp_wr_mask_i,
    input  wire [31:0]                       cmp_wr_value_i,
    input  wire                              udf_wr_en_i,
    input  wire [$clog2(NUDF)-1:0]           udf_wr_idx_i,
    input  wire [15:0]                       udf_wr_offset_i,
    input  wire [31:0]                       udf_wr_mask_i,
    input  wire [31:0]                       udf_wr_value_i,
    input  wire                              rule_wr_en_i,
    input  wire [$clog2(NRULE)-1:0]          rule_wr_idx_i,
    input  wire [NCMP+NUDF-1:0]              rule_wr_care_i,
    input  wire [2:0]                        rule_wr_action_i,
    input  wire [3:0]                        rule_wr_egress_i,
    input  wire [31:0]                       rule_wr_lfid_i,
    input  wire [31:0]                       rule_wr_lif_i,
    input  wire [7:0]                        rule_wr_prio_i,
    input  wire                              rule_wr_enable_i,

    // Hash exact-table programming (pw_hash_classifier): header-keyed TEST_RX
    // flows, scaling payload-agnostic classification to NUM_FLOWS. SW computes
    // the bucket with the same hash (seed) and writes {valid, key, lfid}.
    input  wire [31:0]                       hash_seed_i,
    input  wire [351:0]                      hash_mask_i,   // global key mask (11 words)
    input  wire                              hash_wr_en_i,
    input  wire [$clog2(HASH_DEPTH)-1:0]     hash_wr_index_i,
    input  wire                              hash_wr_valid_i,
    input  wire [351:0]                      hash_wr_key_i,
    input  wire [$clog2(PW_NUM_FLOWS)-1:0]   hash_wr_lfid_i,

    // Per-flow checker counters: BRAM-backed (pw_test_rx_checker_bram), read
    // one flow at a time. Drive flow_rd_addr_i; the merged (across ports)
    // record is valid 2 cycles later. pw_stats_snapshot walks 0..NUM_FLOWS-1.
    input  wire [$clog2(PW_NUM_FLOWS)-1:0] flow_rd_addr_i,
    output logic [63:0]           flow_rx,
    output logic [63:0]           flow_lost,
    output logic [63:0]           flow_dup,
    output logic [63:0]           flow_ooo,
    output logic [63:0]           flow_last_seq,
    output logic [63:0]           flow_min_lat,
    output logic [63:0]           flow_max_lat,
    output logic [63:0]           flow_sum_lat,
    output logic [63:0]           flow_samples,
    output logic [31:0]           flow_jit_min,
    output logic [31:0]           flow_jit_max,
    output logic [63:0]           flow_jit_sum,
    output logic [47:0]           flow_tx,        // emitted frames (tx-rx loss)

    // Live latency-histogram read port (BRAM-backed pw_lat_histogram):
    // flat address (flow*PW_NUM_BUCKETS + bucket) in, 64-bit count out
    // (registered, 1-cycle latency).
    input  wire [15:0]            hist_rd_addr_i,
    output logic [63:0]           hist_rd_data_o,

    // Per-port simple drop counters
    output logic [31:0]           port_drops_o   [PW_PORTS],

    // Per-port total RX/TX frame + byte counters (48-bit internal, zero-extended
    // to the 64-bit snapshot fields). Count ALL frames/bytes at the port edge
    // (not just test traffic). Cleared by stats_clear_i (re-baseline).
    output logic [47:0]           rx_frames_o    [PW_PORTS],
    output logic [47:0]           rx_bytes_o     [PW_PORTS],
    output logic [47:0]           tx_frames_o    [PW_PORTS],
    output logic [47:0]           tx_bytes_o     [PW_PORTS],
    output logic [47:0]           rx_fcs_error_o [PW_PORTS],

    // Link health. link_up_i / block_lock_i are the (async) MAC/PCS status
    // levels; synchronized into clk here, then edge-counted: link up/down
    // transitions and block-lock losses. Counts feed the port stats block.
    input  wire                   link_up_i        [PW_PORTS],
    input  wire                   block_lock_i     [PW_PORTS],
    output logic [31:0]           link_up_cnt_o    [PW_PORTS],
    output logic [31:0]           link_down_cnt_o  [PW_PORTS],
    output logic [31:0]           block_lock_loss_o[PW_PORTS]
);

    // Source-select index space for the TX arbiter: 0..PW_PORTS-1 select
    // ingress SAFs, PW_PORTS selects the local flow generator, PW_PORTS+1
    // selects the host inject source -- so the index space is PW_PORTS+2 wide.
    localparam int SELW  = $clog2(PW_PORTS + 2);
    localparam int RW    = 5;            // route tag: {is_punt, egress[3:0]}
    localparam int MW    = 100;          // punt metadata: {rx_ts[63:0], ingress[3:0], logical_if_id[31:0]}

    // ------------------------------------------------------------
    // Data-plane soft reset: stretch the 1-cycle CSR pulse to a few
    // cycles and AND it (active-low) into rst_n for the wedge-prone
    // datapath state. Registered counter -> dp_rst_n is glitch-free.
    // ------------------------------------------------------------
    logic [3:0] srst_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)             srst_cnt <= 4'd0;
        else if (dp_soft_rst_i) srst_cnt <= 4'd8;
        else if (srst_cnt != 0) srst_cnt <= srst_cnt - 4'd1;
    end
    wire dp_rst_n = rst_n & (srst_cnt == 4'd0);

    // ------------------------------------------------------------
    // Per-port RX: streaming parser -> classifier -> SAF
    // ------------------------------------------------------------
    // Per-port key / result / key_valid in *packed* arrays so the
    // simulator's continuous-assign / unpacked-array-element bug never
    // bites (the same one the wide-bus plane dodged).
    pw_match_key_t    [PW_PORTS-1:0] rx_key;
    logic             [PW_PORTS-1:0] rx_kv;
    pw_class_result_t [PW_PORTS-1:0] rx_fc;    // unified field+UDF classifier result
    // Parser header byte-window + inner base per port (feed the UDF comparators).
    logic [HDR_BYTES-1:0][7:0]       rx_win  [PW_PORTS];
    logic [15:0]                     rx_base [PW_PORTS];
    // Effective result = classifier, overridden by the TEST_RX flow-id map for
    // test frames (the map gives TEST_RX + the mapped checker slot directly).
    // All downstream consumers (checker / SAF / drop) use rx_eff, not rx_fc.
    pw_class_result_t [PW_PORTS-1:0] rx_eff;

    // The effective classifier result (rx_eff) now lands THREE cycles after
    // rx_kv/rx_key: the hash classifier is latency 3 (a masked-key register
    // stage off the dp_clk-critical hash path), and the field + map results are
    // delayed to match. Delay the key + key_valid that feed the checker arbiter,
    // the SAF decision, and the drop counter by three cycles to realign.
    logic             [PW_PORTS-1:0] rx_kv_d1, rx_kv_d2, rx_kv_d;
    pw_match_key_t    [PW_PORTS-1:0] rx_key_d1, rx_key_d2, rx_key_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_kv_d1  <= '0; rx_kv_d2  <= '0; rx_kv_d  <= '0;
            rx_key_d1 <= '0; rx_key_d2 <= '0; rx_key_d <= '0;
        end else begin
            rx_kv_d1  <= rx_kv;     rx_kv_d2  <= rx_kv_d1;   rx_kv_d  <= rx_kv_d2;
            rx_key_d1 <= rx_key;    rx_key_d2 <= rx_key_d1;  rx_key_d <= rx_key_d2;
        end
    end

    // SAF drain side (one per ingress port).
    logic [63:0]      saf_td [PW_PORTS];
    logic [7:0]       saf_tk [PW_PORTS];
    logic             saf_tv [PW_PORTS];
    logic             saf_tl [PW_PORTS];
    logic [RW-1:0]    saf_rt [PW_PORTS];
    logic [MW-1:0]    saf_md [PW_PORTS];   // per-frame punt metadata {ingress[3:0], lif[31:0]}
    logic             saf_tr [PW_PORTS];   // tready into the SAF (from arbiters)
    logic             saf_overflow [PW_PORTS];  // forward-buffer-full drop pulse

    genvar gp;
    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_rx
            // Parser snoops and SAF drops on overflow -> always ready.
            assign s_axis_rx_tready[gp] = 1'b1;

            pw_parser_axis #(.HDR_BYTES(HDR_BYTES)) u_parser (
                .clk            (clk),
                .rst_n          (rst_n),
                .s_tdata        (s_axis_rx_tdata[gp]),
                .s_tkeep        (s_axis_rx_tkeep[gp]),
                .s_tvalid       (s_axis_rx_tvalid[gp]),
                .s_tready       (),                 // parser holds ready=1 internally
                .s_tlast        (s_axis_rx_tlast[gp]),
                .ingress_port_i (4'(gp)),
                .key_o          (rx_key[gp]),
                .key_valid_o    (rx_kv[gp]),
                .window_o       (rx_win[gp]),
                .base_o         (rx_base[gp])
            );

            // Unified field+UDF classifier (replaces pw_classifier + the interim
            // pw_slice_classifier). Comparators source the parser's canonical
            // fields (mux-free) or the raw inner-frame window (UDF); rules combine
            // them. Latency 2 from key_valid. window/base are parser outputs
            // already aligned with key_valid_o (UDF uses the low SLICE_WIN bytes).
            pw_field_classifier #(.HDR_BYTES(HDR_BYTES), .SLICE_WIN(SLICE_WIN),
                                  .NCMP(NCMP), .NUDF(NUDF), .NRULE(NRULE)) u_fclass (
                .clk(clk), .rst_n(rst_n),
                .key_i(rx_key[gp]), .window_i(rx_win[gp][SLICE_WIN-1:0]),
                .base_i(rx_base[gp]), .key_valid_i(rx_kv[gp]),
                .cmp_wr_en(cmp_wr_en_i), .cmp_wr_idx(cmp_wr_idx_i), .cmp_wr_src(cmp_wr_src_i),
                .cmp_wr_mask(cmp_wr_mask_i), .cmp_wr_value(cmp_wr_value_i),
                .udf_wr_en(udf_wr_en_i), .udf_wr_idx(udf_wr_idx_i), .udf_wr_offset(udf_wr_offset_i),
                .udf_wr_mask(udf_wr_mask_i), .udf_wr_value(udf_wr_value_i),
                .rule_wr_en(rule_wr_en_i), .rule_wr_idx(rule_wr_idx_i),
                .rule_wr_care(rule_wr_care_i), .rule_wr_action(rule_wr_action_i),
                .rule_wr_egress(rule_wr_egress_i), .rule_wr_lfid(rule_wr_lfid_i),
                .rule_wr_lif(rule_wr_lif_i), .rule_wr_prio(rule_wr_prio_i),
                .rule_wr_enable(rule_wr_enable_i),
                .result_o(rx_fc[gp])
            );

            // Hash exact classifier: header-keyed TEST_RX, high count (-> checker
            // slot). Latency 3 from key_valid (masked-key register stage); the
            // map and field results are realigned to +3 to match (see below).
            logic                            hcv;
            logic [$clog2(PW_NUM_FLOWS)-1:0] hcl;
            pw_hash_classifier #(.NUM_FLOWS(PW_NUM_FLOWS), .DEPTH(HASH_DEPTH)) u_hclass (
                .clk(clk), .rst_n(rst_n),
                .key_i(rx_key[gp]), .key_valid_i(rx_kv[gp]), .seed_i(hash_seed_i),
                .mask_i(hash_mask_i),
                .wr_en(hash_wr_en_i), .wr_index(hash_wr_index_i), .wr_valid(hash_wr_valid_i),
                .wr_key(hash_wr_key_i), .wr_lfid(hash_wr_lfid_i),
                .valid_o(hcv), .local_flow_id_o(hcl)
            );

            // TEST_RX flow-id map: a frame's test_flow_id directly indexes the
            // checker slot (no per-flow comparator). Latencies are all measured
            // from rx_kv (the cycle the key is presented): the map is +1, the
            // field classifier +2, the hash classifier +3. Realign the map (+2)
            // and field (+1) results so all three land at +3 -- matching the
            // hash -- at the precedence mux below.
            logic                            mv1, mv2, mv3;
            logic [$clog2(PW_NUM_FLOWS)-1:0] ml1, ml2, ml3;
            pw_flowid_map #(.NUM_FLOWS(PW_NUM_FLOWS), .MAP_DEPTH(MAP_DEPTH)) u_fmap (
                .clk(clk), .rst_n(rst_n),
                .wr_en(map_wr_en_i), .wr_addr(map_wr_addr_i),
                .wr_valid(map_wr_valid_i), .wr_lfid(map_wr_lfid_i),
                .flowid_i(rx_key[gp].test_flow_id), .is_test_i(rx_key[gp].is_test),
                .lookup_en_i(rx_kv[gp]), .valid_o(mv1), .local_flow_id_o(ml1)
            );
            // Field classifier is latency 2; delay it one cycle to align with the
            // now-latency-3 hash classifier (+ the +3 map below).
            pw_class_result_t fc_d;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin mv2 <= 1'b0; ml2 <= '0; mv3 <= 1'b0; ml3 <= '0; fc_d <= '0; end
                else begin
                    mv2 <= mv1;  ml2 <= ml1;     // map: +2
                    mv3 <= mv2;  ml3 <= ml2;     // map: +3 (aligned with hash)
                    fc_d <= rx_fc[gp];           // field: +3
                end
            end
            // Effective result (all aligned at +3). Precedence:
            //   flow-id map (structured test)
            //     > hash exact classifier (header-keyed high-count TEST_RX)
            //       > field+UDF classifier (fc_d: punt, forward, drop, few-rule).
            always_comb begin
                rx_eff[gp] = fc_d;
                if (hcv) begin
                    rx_eff[gp].hit           = 1'b1;
                    rx_eff[gp].action        = PW_ACT_TEST_RX;
                    rx_eff[gp].local_flow_id = 32'(hcl);
                    rx_eff[gp].egress_port   = '0;
                    rx_eff[gp].logical_if_id = '0;
                    rx_eff[gp].entry_index   = '0;
                end
                if (mv3) begin
                    rx_eff[gp].hit           = 1'b1;
                    rx_eff[gp].action        = PW_ACT_TEST_RX;
                    rx_eff[gp].local_flow_id = 32'(ml3);
                    rx_eff[gp].egress_port   = '0;
                    rx_eff[gp].logical_if_id = '0;
                    rx_eff[gp].entry_index   = '0;
                end
            end

            // Decision for the frame that just ended (pulsed on key_valid,
            // exactly one cycle after the frame's tlast -- the SAF's
            // timing contract). FORWARD to an in-range port, or PUNT /
            // MIRROR, is kept; everything else (TEST_RX, DROP, no match,
            // FORWARD to a bogus port) is rolled back.
            wire act_fwd  = (rx_eff[gp].action == PW_ACT_FORWARD_PORT) &&
                            (int'(rx_eff[gp].egress_port) < PW_PORTS);
            wire act_punt = (rx_eff[gp].action == PW_ACT_PUNT_TO_HOST) ||
                            (rx_eff[gp].action == PW_ACT_MIRROR_TO_HOST);

            // RX wire timestamp (servo-facing): latch the free-running counter at
            // the frame's first beat (SOF), snapshot it at EOF into frame_ts.
            // frame_ts holds this frame's SOF time until the next frame's EOF
            // (>> the classifier decision latency), so it is still valid when the
            // SAF decision lands -- carried in the punt metadata to the host.
            logic        in_frame;
            logic [63:0] sof_ts, frame_ts;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin in_frame <= 1'b0; sof_ts <= '0; frame_ts <= '0; end
                else if (s_axis_rx_tvalid[gp]) begin
                    if (!in_frame) sof_ts <= timestamp_i;
                    in_frame <= !s_axis_rx_tlast[gp];
                    if (s_axis_rx_tlast[gp])
                        frame_ts <= in_frame ? sof_ts : timestamp_i;  // single-beat -> this beat
                end
            end

            pw_frame_saf #(
                .DEPTH_BEATS(SAF_DEPTH_BEATS),
                .DESC_DEPTH (16),
                .ROUTE_W    (RW),
                .META_W     (MW)
            ) u_saf (
                .clk             (clk),
                .rst_n           (dp_rst_n),   // soft-reset clears wedged FIFO
                .s_tdata         (s_axis_rx_tdata[gp]),
                .s_tkeep         (s_axis_rx_tkeep[gp]),
                .s_tvalid        (s_axis_rx_tvalid[gp]),
                .s_tlast         (s_axis_rx_tlast[gp]),
                .dec_valid_i     (rx_kv_d[gp]),
                .dec_keep_i      (rx_kv_d[gp] && rx_eff[gp].hit && (act_fwd || act_punt)),
                .dec_route_i     (act_punt ? {1'b1, 4'd0}
                                           : {1'b0, rx_eff[gp].egress_port}),
                .dec_meta_i      ({frame_ts, 4'(gp), rx_eff[gp].logical_if_id}),
                .overflow_drop_o (saf_overflow[gp]),  // forward-buffer-full drop
                .m_tdata         (saf_td[gp]),
                .m_tkeep         (saf_tk[gp]),
                .m_tvalid        (saf_tv[gp]),
                .m_tready        (saf_tr[gp]),
                .m_tlast         (saf_tl[gp]),
                .m_route         (saf_rt[gp]),
                .m_meta          (saf_md[gp])
            );
        end
    endgenerate

    // ------------------------------------------------------------
    // RX checkers: one per ingress port (no arbiter)
    // ------------------------------------------------------------
    // Each ingress port has its own checker, fed directly by that port's
    // TEST_RX events, so simultaneous line-rate TEST_RX on every port is
    // handled without an arbiter dropping events (the old single checker
    // starved the lower-priority port). Each flow's RX is on exactly one
    // port, so the per-flow counters are merged across ports below: sum
    // for additive counters / last_seq, min/max for latency. Inactive
    // ports contribute identity values (0, or 0xFFFF.. for min), so the
    // merge yields the active port's value.
    // Per-port BRAM checkers. Each holds all NUM_FLOWS records; the flow's RX
    // arrives on exactly one port, so the other port's record for that flow is
    // blank (identity for the merge). We drive the same flow_rd_addr_i to every
    // port and merge the read records (registered) below.
    logic [63:0] prx   [PW_PORTS], plost [PW_PORTS], pdup  [PW_PORTS], pooo [PW_PORTS];
    logic [63:0] plseq [PW_PORTS], pminl [PW_PORTS], pmaxl [PW_PORTS];
    logic [63:0] psuml [PW_PORTS], psamp [PW_PORTS], pjsum [PW_PORTS];
    logic [63:0] pjmin [PW_PORTS], pjmax [PW_PORTS];

    // Per-port registered histogram events into the BRAM histogram.
    logic        hev_v  [PW_PORTS];
    logic [15:0] hev_fl [PW_PORTS];
    logic [15:0] hev_bk [PW_PORTS];

    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_chk
            wire chk_ev = rx_kv_d[gp] && rx_eff[gp].hit &&
                          (rx_eff[gp].action == PW_ACT_TEST_RX);
            pw_test_rx_checker_bram #(
                .NUM_FLOWS       (PW_NUM_FLOWS),
                .NUM_BUCKETS     (PW_NUM_BUCKETS)
            ) u_checker (
                .clk             (clk),
                .rst_n           (rst_n),
                .clear_i         (stats_clear_i),
                .timestamp_i     (timestamp_i),
                .key_i           (rx_key_d[gp]),
                .result_i        (rx_eff[gp]),
                .event_valid_i   (chk_ev),
                .hist_ev_o       (hev_v[gp]),
                .hist_flow_o     (hev_fl[gp]),
                .hist_bucket_o   (hev_bk[gp]),
                .rd_addr_i       (flow_rd_addr_i),
                .rd_en_i         (1'b1),
                .rd_valid_o      (),
                .rd_rx_frames_o  (prx[gp]),
                .rd_lost_o       (plost[gp]),
                .rd_duplicate_o  (pdup[gp]),
                .rd_out_of_order_o(pooo[gp]),
                .rd_last_seq_o   (plseq[gp]),
                .rd_min_latency_o(pminl[gp]),
                .rd_max_latency_o(pmaxl[gp]),
                .rd_sum_latency_o(psuml[gp]),
                .rd_sample_count_o(psamp[gp]),
                .rd_jitter_min_o (pjmin[gp]),
                .rd_jitter_max_o (pjmax[gp]),
                .rd_jitter_sum_o (pjsum[gp])
            );
        end
    endgenerate

    // Shared BRAM latency histogram, fed by every port's checker events.
    pw_lat_histogram #(
        .NUM_FLOWS  (PW_NUM_FLOWS),
        .NUM_BUCKETS(PW_NUM_BUCKETS),
        .N_EV       (PW_PORTS),
        .RD_ADDR_W  (16)
    ) u_hist (
        .clk         (clk),
        .rst_n       (rst_n),
        .clear_i     (stats_clear_i),
        .ev_valid_i  (hev_v),
        .ev_flow_i   (hev_fl),
        .ev_bucket_i (hev_bk),
        .rd_addr_i   (hist_rd_addr_i),
        .rd_data_o   (hist_rd_data_o)
    );

    // Merge the per-port read records (one flow per cycle) into the registered
    // scalar outputs. The per-port checker read is 1 cycle after flow_rd_addr_i;
    // this register adds 1 more, so flow_* is valid 2 cycles after the address.
    // flow_tx (generator TX count) is sampled at flow_rd_addr_i delayed 1 cycle
    // so it lands in the same register, aligned with the checker fields.
    logic [$clog2(PW_NUM_FLOWS)-1:0] flow_rd_addr_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flow_rd_addr_d1 <= '0;
            flow_rx <= '0; flow_lost <= '0; flow_dup <= '0; flow_ooo <= '0;
            flow_last_seq <= '0; flow_sum_lat <= '0; flow_samples <= '0;
            flow_min_lat <= '0; flow_max_lat <= '0;
            flow_jit_min <= '0; flow_jit_max <= '0; flow_jit_sum <= '0;
            flow_tx <= '0;
        end else begin
            logic [63:0] rx, lost, dup, ooo, lseq, sum, samp, jsum, mn, mx;
            logic [31:0] jmn, jmx;
            logic [47:0] txacc;
            rx='0; lost='0; dup='0; ooo='0; lseq='0; sum='0; samp='0; jsum='0;
            mn={64{1'b1}}; mx='0; jmn={32{1'b1}}; jmx='0; txacc='0;
            for (int p = 0; p < PW_PORTS; p++) begin
                rx   += prx[p];   lost += plost[p]; dup += pdup[p]; ooo += pooo[p];
                sum  += psuml[p]; samp += psamp[p]; jsum += pjsum[p];
                lseq |= plseq[p];                        // one active port per flow
                if (pminl[p] < mn) mn = pminl[p];
                if (pmaxl[p] > mx) mx = pmaxl[p];
                if (pjmin[p][31:0] < jmn) jmn = pjmin[p][31:0];
                if (pjmax[p][31:0] > jmx) jmx = pjmax[p][31:0];
                txacc += gen_tx_count[p][flow_rd_addr_d1];
            end
            flow_rd_addr_d1 <= flow_rd_addr_i;
            flow_rx <= rx; flow_lost <= lost; flow_dup <= dup; flow_ooo <= ooo;
            flow_last_seq <= lseq; flow_sum_lat <= sum; flow_samples <= samp;
            flow_min_lat <= mn; flow_max_lat <= mx;
            flow_jit_min <= jmn; flow_jit_max <= jmx; flow_jit_sum <= jsum;
            flow_tx <= txacc;
        end
    end

    // ------------------------------------------------------------
    // Per-port counters: DROP + total RX/TX frames & bytes
    // ------------------------------------------------------------
    // port_drops: a key_valid DROP event (incl. the no-match default) ticks.
    // rx_frames/bytes: every frame/byte arriving on the ingress AXIS (all
    // traffic, not just test). tx_frames/bytes: every frame/byte accepted on
    // the egress AXIS (gen + forwarded + injected). All are re-baselined by
    // stats_clear_i (alongside the flow checkers) so a measurement run starts
    // from zero. Bytes accumulate the per-beat tkeep population count.
    logic [31:0] port_drops [PW_PORTS];
    logic [47:0] rx_frames  [PW_PORTS];
    logic [47:0] rx_bytes   [PW_PORTS];
    logic [47:0] tx_frames  [PW_PORTS];
    logic [47:0] tx_bytes   [PW_PORTS];
    logic [47:0] rx_fcs_err [PW_PORTS];

    function automatic logic [3:0] popk8(input logic [7:0] k);
        logic [3:0] n; n = '0;
        for (int i = 0; i < 8; i++) n += {3'b0, k[i]};
        return n;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || stats_clear_i) begin
            for (int p = 0; p < PW_PORTS; p++) begin
                port_drops[p] <= '0; rx_frames[p] <= '0; rx_bytes[p] <= '0;
                tx_frames[p] <= '0; tx_bytes[p] <= '0; rx_fcs_err[p] <= '0;
            end
        end else begin
            for (int p = 0; p < PW_PORTS; p++) begin
                // total drops: no-match/DROP classifier decisions + SAF
                // forward-buffer-full drops (previously silent).
                if ((rx_kv_d[p] && rx_eff[p].action == PW_ACT_DROP) || saf_overflow[p])
                    port_drops[p] <= port_drops[p]
                        + 32'((rx_kv_d[p] && rx_eff[p].action == PW_ACT_DROP) ? 1 : 0)
                        + 32'(saf_overflow[p] ? 1 : 0);
                // RX edge: ingress AXIS is never backpressured (parser snoops,
                // SAF drops on overflow), so a valid beat is always accepted.
                if (s_axis_rx_tvalid[p]) begin
                    rx_bytes[p] <= rx_bytes[p] + 48'(popk8(s_axis_rx_tkeep[p]));
                    if (s_axis_rx_tlast[p]) begin
                        rx_frames[p] <= rx_frames[p] + 48'd1;
                        // tuser on tlast = errored frame (bad FCS / runt).
                        if (s_axis_rx_tuser[p]) rx_fcs_err[p] <= rx_fcs_err[p] + 48'd1;
                    end
                end
                // TX edge: count accepted egress beats (valid && ready).
                if (m_axis_tx_tvalid[p] && m_axis_tx_tready[p]) begin
                    tx_bytes[p] <= tx_bytes[p] + 48'(popk8(m_axis_tx_tkeep[p]));
                    if (m_axis_tx_tlast[p]) tx_frames[p] <= tx_frames[p] + 48'd1;
                end
            end
        end
    end

    always_comb begin
        for (int p = 0; p < PW_PORTS; p++) begin
            rx_frames_o[p] = rx_frames[p]; rx_bytes_o[p] = rx_bytes[p];
            tx_frames_o[p] = tx_frames[p]; tx_bytes_o[p] = tx_bytes[p];
            rx_fcs_error_o[p] = rx_fcs_err[p];
        end
    end

    always_comb begin
        for (int p = 0; p < PW_PORTS; p++)
            port_drops_o[p] = port_drops[p];
    end

    // ------------------------------------------------------------
    // Link health: synchronize the async MAC/PCS status levels into
    // clk (2-FF), then count link up/down transitions and block-lock
    // losses. Not affected by stats_clear_i (link history is sticky).
    // ------------------------------------------------------------
    logic [PW_PORTS-1:0] lu_sync0, lu_sync1, lu_prev;
    logic [PW_PORTS-1:0] bl_sync0, bl_sync1, bl_prev;
    logic [31:0] link_up_cnt   [PW_PORTS];
    logic [31:0] link_down_cnt [PW_PORTS];
    logic [31:0] bl_loss_cnt   [PW_PORTS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_sync0 <= '0; lu_sync1 <= '0; lu_prev <= '0;
            bl_sync0 <= '0; bl_sync1 <= '0; bl_prev <= '0;
            for (int p = 0; p < PW_PORTS; p++) begin
                link_up_cnt[p]   <= '0;
                link_down_cnt[p] <= '0;
                bl_loss_cnt[p]   <= '0;
            end
        end else begin
            for (int p = 0; p < PW_PORTS; p++) begin
                lu_sync0[p] <= link_up_i[p];     lu_sync1[p] <= lu_sync0[p];
                bl_sync0[p] <= block_lock_i[p];  bl_sync1[p] <= bl_sync0[p];
                lu_prev[p]  <= lu_sync1[p];
                bl_prev[p]  <= bl_sync1[p];
                if ( lu_sync1[p] && !lu_prev[p]) link_up_cnt[p]   <= link_up_cnt[p]   + 32'd1;
                if (!lu_sync1[p] &&  lu_prev[p]) link_down_cnt[p] <= link_down_cnt[p] + 32'd1;
                if (!bl_sync1[p] &&  bl_prev[p]) bl_loss_cnt[p]   <= bl_loss_cnt[p]   + 32'd1;
            end
        end
    end

    always_comb begin
        for (int p = 0; p < PW_PORTS; p++) begin
            link_up_cnt_o[p]     = link_up_cnt[p];
            link_down_cnt_o[p]   = link_down_cnt[p];
            block_lock_loss_o[p] = bl_loss_cnt[p];
        end
    end

    // ------------------------------------------------------------
    // BRAM-backed flow table (one read port per egress generator)
    // ------------------------------------------------------------
    pw_flow_sched_t flow_sched [PW_NUM_FLOWS];
    logic [$clog2(PW_NUM_FLOWS)-1:0] gen_rd_addr [PW_PORTS];
    pw_flow_row_t                    gen_rd_row  [PW_PORTS];
    logic [47:0]                     gen_tx_count [PW_PORTS][PW_NUM_FLOWS];

    pw_flow_table_bram #(
        .ADDR_W           (FLOW_ADDR_W),
        .DEPTH            (PW_NUM_FLOWS),
        .PORTS            (PW_PORTS),
        .FRAME_LEN_PAYLOAD(FRAME_LEN_PAYLOAD),
        .WIN_BASE         (FLOW_WIN_BASE),
        .COMMIT_OFFSET    (FLOW_COMMIT_OFFSET)
    ) u_flow_table (
        .clk            (clk),
        .rst_n          (rst_n),          // table survives the datapath soft-reset
        .wr_en          (flow_wr_en_i),
        .wr_addr         (flow_wr_addr_i),
        .wr_data         (flow_wr_data_i),
        .flow_sched_o   (flow_sched),
        .rd_addr_i      (gen_rd_addr),
        .rd_row_o       (gen_rd_row),
        .commit_pulse_o ()
    );

    // ------------------------------------------------------------
    // Per-egress flow generators
    // ------------------------------------------------------------
    logic [63:0] gen_td [PW_PORTS];
    logic [7:0]  gen_tk [PW_PORTS];
    logic        gen_tv [PW_PORTS];
    logic        gen_tl [PW_PORTS];
    logic        gen_tr [PW_PORTS];   // tready into the generator (from arbiter)

    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_gen
            // One multi-flow generator per egress port: it emits every flow
            // row whose egress == gp, round-robin, each with its own flow_id
            // / sequence / token bucket. Schedules from flow_sched[]; reads the
            // picked row's wide content from the table BRAM via its read port.
            pw_flow_gen_multi #(
                .EGRESS_PORT      (gp),
                .NUM_SLOTS        (PW_NUM_FLOWS),
                .FRAME_LEN_PAYLOAD(FRAME_LEN_PAYLOAD)
            ) u_gen (
                .clk         (clk),
                .rst_n       (dp_rst_n),   // soft-reset clears wedged generator
                .timestamp_i (timestamp_i),
                .flow_sched_i(flow_sched),
                .rd_addr_o   (gen_rd_addr[gp]),
                .rd_row_i    (gen_rd_row[gp]),
                .stats_clear_i(stats_clear_i),
                .tx_count_o  (gen_tx_count[gp]),
                .m_tdata     (gen_td[gp]),
                .m_tkeep     (gen_tk[gp]),
                .m_tvalid    (gen_tv[gp]),
                .m_tready    (gen_tr[gp]),
                .m_tlast     (gen_tl[gp])
            );
        end
    endgenerate

    // (Per-flow TX count is read in the registered checker-merge block above:
    // flow_tx <= sum_p gen_tx_count[p][flow_rd_addr_d1], aligned with the
    // checker fields. Each slot is emitted by exactly one generator, so the
    // others' count for that slot stays 0 and the sum picks out the owner.
    // Slot index == flow row index == tx_local_flow_id.)

    // ------------------------------------------------------------
    // Egress TX arbiters: forwarded frames (from any ingress SAF routed
    // to this port) take priority, the generator fills idle slots.
    // ------------------------------------------------------------
    // Per-egress selection exported for the SAF-ready aggregation below.
    logic [SELW-1:0] egr_src       [PW_PORTS];  // selected source index
    logic            egr_drain_saf [PW_PORTS];  // selected source is a SAF
    logic            egr_drain_inj [PW_PORTS];  // selected source is the injector

    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_tx
            logic [PW_PORTS-1:0] fwd_req;
            logic                any_fwd;
            logic [SELW-1:0]     win_p;
            always_comb begin
                any_fwd = 1'b0;
                win_p   = '0;
                for (int p = 0; p < PW_PORTS; p++) begin
                    fwd_req[p] = saf_tv[p] && !saf_rt[p][4] &&
                                 (saf_rt[p][3:0] == 4'(gp));
                    if (fwd_req[p] && !any_fwd) begin
                        any_fwd = 1'b1;
                        win_p   = SELW'(p);
                    end
                end
            end

            // Source priority: forwarded SAF frame > host inject > generator.
            // Encoding: 0..PW_PORTS-1 = SAF index, PW_PORTS = generator,
            // PW_PORTS+1 = inject.
            wire             inj_here  = s_axis_inj_tvalid && (int'(s_axis_inj_egress) == gp);
            wire             win_inj   = !any_fwd && inj_here;
            wire             win_gen   = !any_fwd && !inj_here && gen_tv[gp];
            wire             win_valid = any_fwd || inj_here || win_gen;
            wire [SELW-1:0]  win       = any_fwd ? win_p
                                       : (inj_here ? SELW'(PW_PORTS + 1)
                                                   : SELW'(PW_PORTS));

            logic            busy;
            logic [SELW-1:0] gsel;
            wire [SELW-1:0]  sel       = busy ? gsel : win;
            wire             sel_valid = busy ? 1'b1 : win_valid;
            wire             sel_gen   = (sel == SELW'(PW_PORTS));
            wire             sel_inj   = (sel == SELW'(PW_PORTS + 1));
            wire [SELW-1:0]  saf_idx   = (sel_gen || sel_inj) ? '0 : sel;

            assign m_axis_tx_tdata[gp]  = sel_inj ? s_axis_inj_tdata
                                        : (sel_gen ? gen_td[gp] : saf_td[saf_idx]);
            assign m_axis_tx_tkeep[gp]  = sel_inj ? s_axis_inj_tkeep
                                        : (sel_gen ? gen_tk[gp] : saf_tk[saf_idx]);
            assign m_axis_tx_tlast[gp]  = sel_inj ? s_axis_inj_tlast
                                        : (sel_gen ? gen_tl[gp] : saf_tl[saf_idx]);
            assign m_axis_tx_tvalid[gp] = sel_valid &&
                                          (sel_inj ? s_axis_inj_tvalid
                                         : (sel_gen ? gen_tv[gp] : saf_tv[saf_idx]));
            // Mark generator (test) frames so the egress stamper can find them
            // before the magic streams (the IPv6 UDP csum field precedes it).
            assign m_axis_tx_tuser[gp]  = sel_gen;

            wire hs   = m_axis_tx_tvalid[gp] && m_axis_tx_tready[gp];
            wire done = hs && m_axis_tx_tlast[gp];

            // Generator gets ready only while it is the selected source.
            assign gen_tr[gp] = sel_valid && sel_gen && m_axis_tx_tready[gp];

            // Export selection for SAF-ready aggregation.
            assign egr_src[gp]       = sel;
            assign egr_drain_saf[gp] = sel_valid && !sel_gen && !sel_inj;
            assign egr_drain_inj[gp] = sel_valid && sel_inj;

            always_ff @(posedge clk or negedge dp_rst_n) begin
                if (!dp_rst_n) begin
                    busy <= 1'b0;
                    gsel <= '0;
                end else if (!busy) begin
                    if (win_valid && !done) begin
                        busy <= 1'b1;
                        gsel <= win;
                    end
                end else if (done) begin
                    busy <= 1'b0;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------
    // Punt arbiter: drains PUNT/MIRROR frames (route.is_punt) to the
    // punt AXIS master, lowest ingress port first.
    // ------------------------------------------------------------
    logic [PW_PORTS-1:0] punt_req;
    logic                any_punt;
    logic [SELW-1:0]     punt_win;
    always_comb begin
        any_punt = 1'b0;
        punt_win = '0;
        for (int p = 0; p < PW_PORTS; p++) begin
            punt_req[p] = saf_tv[p] && saf_rt[p][4];
            if (punt_req[p] && !any_punt) begin
                any_punt = 1'b1;
                punt_win = SELW'(p);
            end
        end
    end

    logic            punt_busy;
    logic [SELW-1:0] punt_gsel;
    wire [SELW-1:0]  punt_sel       = punt_busy ? punt_gsel : punt_win;
    wire             punt_sel_valid = punt_busy ? 1'b1 : any_punt;

    assign m_axis_punt_tdata  = saf_td[punt_sel];
    assign m_axis_punt_tkeep  = saf_tk[punt_sel];
    assign m_axis_punt_tlast  = saf_tl[punt_sel];
    assign m_axis_punt_tuser  = saf_md[punt_sel];
    assign m_axis_punt_tvalid = punt_sel_valid && saf_tv[punt_sel];

    wire punt_hs   = m_axis_punt_tvalid && m_axis_punt_tready;
    wire punt_done = punt_hs && m_axis_punt_tlast;

    always_ff @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            punt_busy <= 1'b0;
            punt_gsel <= '0;
        end else if (!punt_busy) begin
            if (any_punt && !punt_done) begin
                punt_busy <= 1'b1;
                punt_gsel <= punt_win;
            end
        end else if (punt_done) begin
            punt_busy <= 1'b0;
        end
    end

    // ------------------------------------------------------------
    // SAF tready aggregation: a SAF head frame routes to exactly one
    // destination (one egress port OR punt), so at most one consumer
    // grants it -- OR the grants' readies together.
    // ------------------------------------------------------------
    always_comb begin
        for (int p = 0; p < PW_PORTS; p++) begin
            saf_tr[p] = 1'b0;
            for (int e = 0; e < PW_PORTS; e++)
                if (egr_drain_saf[e] && (int'(egr_src[e]) == p))
                    saf_tr[p] = saf_tr[p] | m_axis_tx_tready[e];
            if (punt_sel_valid && (int'(punt_sel) == p))
                saf_tr[p] = saf_tr[p] | m_axis_punt_tready;
        end
    end

    // Inject tready: the single inject source targets exactly one egress, so
    // OR the readiness of whichever egress arbiter currently grants it.
    always_comb begin
        s_axis_inj_tready = 1'b0;
        for (int e = 0; e < PW_PORTS; e++)
            if (egr_drain_inj[e])
                s_axis_inj_tready = s_axis_inj_tready | m_axis_tx_tready[e];
    end

endmodule

`default_nettype wire
