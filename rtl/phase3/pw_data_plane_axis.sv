// PacketWyrm Phase 3 data plane -- 64-bit AXIS streaming version.
//
// Production data path that replaces the wide-bus pw_data_plane (which
// synthesised but would not route off the ~12288-bit pw_frame_t bus).
// Orchestrates the streaming building blocks:
//
//   * per ingress port: pw_parser_axis (snoops the RX stream, emits a
//                       registered pw_match_key_t one cycle after EOF)
//                       + pw_classifier (combinational lookup)
//   * one pw_test_rx_checker fed by the TEST_RX classification events
//   * per egress port:  pw_flow_gen_axis driving the TX AXIS master
//   * per-port DROP counters
//
// SCOPE (this commit -- core test path):
//   TEST_RX (the HW-validated gen -> loopback -> checker path) and DROP
//   are fully implemented. FORWARD_PORT / PUNT_TO_HOST / MIRROR_TO_HOST
//   need store-and-forward (the classification decision lands a cycle
//   after tlast, so the frame must be buffered to be re-emitted); that
//   per-port frame FIFO + descriptor drain lands in the next commit.
//   Until then the punt AXIS master is tied off and the TX path carries
//   the flow generator only. Frames classified FORWARD/PUNT/MIRROR are
//   snooped by the checker path but not re-emitted, and are NOT counted
//   as DROPs (only PW_ACT_DROP increments port_drops_o, matching the
//   wide-bus plane's semantics).

`default_nettype none

import pw_classifier_pkg::*;

module pw_data_plane_axis #(
    parameter int PW_PORTS          = 2,
    parameter int PW_NUM_FLOWS      = 16,
    parameter int PW_NUM_BUCKETS    = 16,
    parameter int HDR_BYTES         = 100,  // parser header-capture depth
    parameter int FRAME_LEN_PAYLOAD = 32    // flow_gen L4 payload bytes
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [63:0]            timestamp_i,

    input  pw_classifier_table_t  cls_table_i,

    // Per-port AXIS RX (MAC -> data plane ingress). The checker path
    // only snoops, so it never backpressures: s_axis_rx_tready == 1.
    input  wire [63:0]            s_axis_rx_tdata  [PW_PORTS],
    input  wire [7:0]             s_axis_rx_tkeep  [PW_PORTS],
    input  wire                   s_axis_rx_tvalid [PW_PORTS],
    output logic                  s_axis_rx_tready [PW_PORTS],
    input  wire                   s_axis_rx_tlast  [PW_PORTS],

    // Per-port AXIS TX (data plane egress -> MAC). Currently driven by
    // the per-port flow generator only (see SCOPE note).
    output logic [63:0]           m_axis_tx_tdata  [PW_PORTS],
    output logic [7:0]            m_axis_tx_tkeep  [PW_PORTS],
    output logic                  m_axis_tx_tvalid [PW_PORTS],
    input  wire                   m_axis_tx_tready [PW_PORTS],
    output logic                  m_axis_tx_tlast  [PW_PORTS],

    // Punt path (PUNT_TO_HOST / MIRROR_TO_HOST). Tied off in this
    // core-path orchestrator; the store-and-forward drain feeds it next.
    output logic [63:0]           m_axis_punt_tdata,
    output logic [7:0]            m_axis_punt_tkeep,
    output logic                  m_axis_punt_tvalid,
    input  wire                   m_axis_punt_tready,
    output logic                  m_axis_punt_tlast,

    // Flow gen control (one generator per egress port, flow 1+port)
    input  wire                   gen_enable_i   [PW_PORTS],
    input  wire [31:0]            gen_tokens_fp_i[PW_PORTS],
    input  wire [15:0]            gen_burst_i    [PW_PORTS],
    input  wire [47:0]            gen_src_mac_i  [PW_PORTS],
    input  wire [47:0]            gen_dst_mac_i  [PW_PORTS],
    input  wire                   gen_vlan_en_i  [PW_PORTS],
    input  wire [11:0]            gen_vlan_id_i  [PW_PORTS],
    input  wire [31:0]            gen_src_ip_i   [PW_PORTS],
    input  wire [31:0]            gen_dst_ip_i   [PW_PORTS],
    input  wire [15:0]            gen_udp_sp_i   [PW_PORTS],
    input  wire [15:0]            gen_udp_dp_i   [PW_PORTS],

    // Per-flow checker counters (over all flows on the card)
    output logic [63:0]           flow_rx        [PW_NUM_FLOWS],
    output logic [63:0]           flow_lost      [PW_NUM_FLOWS],
    output logic [63:0]           flow_dup       [PW_NUM_FLOWS],
    output logic [63:0]           flow_ooo       [PW_NUM_FLOWS],
    output logic [63:0]           flow_last_seq  [PW_NUM_FLOWS],
    output logic [63:0]           flow_min_lat   [PW_NUM_FLOWS],
    output logic [63:0]           flow_max_lat   [PW_NUM_FLOWS],
    output logic [63:0]           flow_sum_lat   [PW_NUM_FLOWS],
    output logic [63:0]           flow_samples   [PW_NUM_FLOWS],
    output logic [63:0]           flow_hist      [PW_NUM_FLOWS * PW_NUM_BUCKETS],

    // Per-port simple drop counters
    output logic [31:0]           port_drops_o   [PW_PORTS]
);

    // ------------------------------------------------------------
    // Per-port RX: streaming parser -> classifier
    // ------------------------------------------------------------
    // Keep the per-port key / result / key_valid in *packed* arrays so
    // the simulator's continuous-assign / unpacked-array-element bug
    // (the same one the wide-bus plane dodged) never bites.
    pw_match_key_t    [PW_PORTS-1:0] rx_key;
    logic             [PW_PORTS-1:0] rx_kv;
    pw_class_result_t [PW_PORTS-1:0] rx_res;

    genvar gp;
    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_rx
            // Checker path snoops only -- always ready.
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
                .key_valid_o    (rx_kv[gp])
            );

            pw_classifier u_cls (
                .clk         (clk),
                .rst_n       (rst_n),
                .table_i     (cls_table_i),
                .key_i       (rx_key[gp]),
                .key_valid_i (rx_kv[gp]),
                .result_o    (rx_res[gp])
            );
        end
    endgenerate

    // ------------------------------------------------------------
    // RX checker: one logical block, sees TEST_RX events from any port
    // ------------------------------------------------------------
    // One classification event forwarded per cycle. With two ports the
    // testbench drives them alternately or one at a time, which proves
    // the path; production RTL adds a small ingress arbiter here.
    pw_match_key_t    chk_key;
    pw_class_result_t chk_res;
    logic             chk_ev;

    always_comb begin
        chk_key = '0;
        chk_res = '0;
        chk_ev  = 1'b0;
        for (int p = 0; p < PW_PORTS; p++) begin
            if (rx_kv[p] && rx_res[p].hit &&
                rx_res[p].action == PW_ACT_TEST_RX) begin
                chk_key = rx_key[p];
                chk_res = rx_res[p];
                chk_ev  = 1'b1;
            end
        end
    end

    pw_test_rx_checker #(
        .NUM_FLOWS  (PW_NUM_FLOWS),
        .NUM_BUCKETS(PW_NUM_BUCKETS)
    ) u_checker (
        .clk             (clk),
        .rst_n           (rst_n),
        .timestamp_i     (timestamp_i),
        .key_i           (chk_key),
        .result_i        (chk_res),
        .event_valid_i   (chk_ev),
        .rx_frames_o     (flow_rx),
        .lost_o          (flow_lost),
        .duplicate_o     (flow_dup),
        .out_of_order_o  (flow_ooo),
        .last_seq_o      (flow_last_seq),
        .min_latency_o   (flow_min_lat),
        .max_latency_o   (flow_max_lat),
        .sum_latency_o   (flow_sum_lat),
        .sample_count_o  (flow_samples),
        .hist_o          (flow_hist)
    );

    // ------------------------------------------------------------
    // Per-port DROP counter
    // ------------------------------------------------------------
    // A key_valid event whose action is DROP (including the default for
    // no match) increments. FORWARD/PUNT/MIRROR are NOT counted here --
    // they will be routed by the store-and-forward stage (next commit).
    logic [31:0] port_drops [PW_PORTS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < PW_PORTS; p++) port_drops[p] <= '0;
        end else begin
            for (int p = 0; p < PW_PORTS; p++) begin
                if (rx_kv[p] && rx_res[p].action == PW_ACT_DROP)
                    port_drops[p] <= port_drops[p] + 32'd1;
            end
        end
    end

    always_comb begin
        for (int p = 0; p < PW_PORTS; p++)
            port_drops_o[p] = port_drops[p];
    end

    // ------------------------------------------------------------
    // Per-egress flow generators -> TX AXIS
    // ------------------------------------------------------------
    // The TX path carries the flow generator only for now. When the
    // store-and-forward stage lands, a tiny arbiter goes here:
    // forwarded frames take priority, the generator fills idle slots.
    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_tx
            pw_flow_gen_axis #(
                .GLOBAL_FLOW_ID   (32'd1 + gp),
                .FRAME_LEN_PAYLOAD(FRAME_LEN_PAYLOAD)
            ) u_gen (
                .clk                  (clk),
                .rst_n                (rst_n),
                .enable_i             (gen_enable_i[gp]),
                .tokens_per_tick_fp_i (gen_tokens_fp_i[gp]),
                .burst_bytes_i        (gen_burst_i[gp]),
                .egress_port_i        (4'(gp)),
                .src_mac_i            (gen_src_mac_i[gp]),
                .dst_mac_i            (gen_dst_mac_i[gp]),
                .vlan_enable_i        (gen_vlan_en_i[gp]),
                .vlan_id_i            (gen_vlan_id_i[gp]),
                .src_ipv4_i           (gen_src_ip_i[gp]),
                .dst_ipv4_i           (gen_dst_ip_i[gp]),
                .udp_src_port_i       (gen_udp_sp_i[gp]),
                .udp_dst_port_i       (gen_udp_dp_i[gp]),
                .timestamp_i          (timestamp_i),
                .m_tdata              (m_axis_tx_tdata[gp]),
                .m_tkeep              (m_axis_tx_tkeep[gp]),
                .m_tvalid             (m_axis_tx_tvalid[gp]),
                .m_tready             (m_axis_tx_tready[gp]),
                .m_tlast              (m_axis_tx_tlast[gp])
            );
        end
    endgenerate

    // ------------------------------------------------------------
    // Punt AXIS master: tied off until the store-and-forward drain
    // (next commit) re-emits PUNT_TO_HOST / MIRROR_TO_HOST frames.
    // ------------------------------------------------------------
    assign m_axis_punt_tdata  = '0;
    assign m_axis_punt_tkeep  = '0;
    assign m_axis_punt_tvalid = 1'b0;
    assign m_axis_punt_tlast  = 1'b0;
    wire _unused_punt = &{1'b0, m_axis_punt_tready, 1'b0};

endmodule

`default_nettype wire
