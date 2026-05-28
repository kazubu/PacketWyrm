// PacketWyrm Phase 3 top: data plane + CSR + AXIS endpoints.
//
// Board-agnostic core that the per-board tops wrap with their
// PCIe → AXI-Lite bridge and their 10G MAC IP. Exposes:
//
//   * AXI4-Lite slave  (host BAR programming, 16-bit address)
//   * per-port 64-bit AXIS RX (MAC -> data plane ingress)
//   * per-port 64-bit AXIS TX (data plane egress -> MAC)
//   * 64-bit AXIS for the punt path (PUNT_TO_HOST / MIRROR_TO_HOST)
//
// Inside it instantiates pw_csr_full (identity + classifier / flow
// / stats / histogram windows), pw_data_plane, and a pair of
// AXIS serializer / deserializer per port (Phase 2 stepping stone
// to 64-bit MAC bus).

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pwfpga_top_phase3 #(
    parameter int          ADDR_W          = 16,
    parameter logic [31:0] CAPABILITIES    = 32'h0,
    parameter int          NUM_PORTS       = 2,
    parameter int          NUM_FLOWS       = 8,
    parameter int          NUM_LOGICAL_IFS = 0,
    parameter int          NUM_CLASSIFIER  = 8,
    parameter int          NUM_HIST_BINS   = 16
) (
    input  wire              clk,
    input  wire              rst_n,

    // AXI4-Lite slave (host BAR)
    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,
    input  wire [31:0]       s_axi_wdata,
    input  wire [3:0]        s_axi_wstrb,
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,
    output wire [1:0]        s_axi_bresp,
    output wire              s_axi_bvalid,
    input  wire              s_axi_bready,
    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire              s_axi_arvalid,
    output wire              s_axi_arready,
    output wire [31:0]       s_axi_rdata,
    output wire [1:0]        s_axi_rresp,
    output wire              s_axi_rvalid,
    input  wire              s_axi_rready,

    // Per-port MAC RX (64-bit AXIS from MAC into data plane)
    input  wire [63:0]       s_axis_rx_tdata  [NUM_PORTS],
    input  wire [7:0]        s_axis_rx_tkeep  [NUM_PORTS],
    input  wire              s_axis_rx_tvalid [NUM_PORTS],
    output wire              s_axis_rx_tready [NUM_PORTS],
    input  wire              s_axis_rx_tlast  [NUM_PORTS],

    // Per-port MAC TX (64-bit AXIS from data plane to MAC)
    output wire [63:0]       m_axis_tx_tdata  [NUM_PORTS],
    output wire [7:0]        m_axis_tx_tkeep  [NUM_PORTS],
    output wire              m_axis_tx_tvalid [NUM_PORTS],
    input  wire              m_axis_tx_tready [NUM_PORTS],
    output wire              m_axis_tx_tlast  [NUM_PORTS],

    // Punt path (PUNT_TO_HOST / MIRROR_TO_HOST) as a 64-bit AXIS
    // master. Production routes this into a DMA ring; the sim
    // testbench attaches a deserializer or a sink.
    output wire [63:0]       m_axis_punt_tdata,
    output wire [7:0]        m_axis_punt_tkeep,
    output wire              m_axis_punt_tvalid,
    input  wire              m_axis_punt_tready,
    output wire              m_axis_punt_tlast,

    // Free-running 64-bit timestamp (driven by pw_timestamp on the
    // board top; the sim drives this from a tb counter).
    input  wire [63:0]       timestamp_i
);

    // --- Data-plane <-> CSR_full wiring -------------------------
    pw_classifier_table_t          cls_table;
    logic [NUM_PORTS-1:0]          gen_enable;
    logic [NUM_PORTS-1:0] [31:0]   gen_tokens_fp;
    logic [NUM_PORTS-1:0] [15:0]   gen_burst;
    logic [NUM_PORTS-1:0] [47:0]   gen_src_mac;
    logic [NUM_PORTS-1:0] [47:0]   gen_dst_mac;
    logic [NUM_PORTS-1:0]          gen_vlan_en;
    logic [NUM_PORTS-1:0] [11:0]   gen_vlan_id;
    logic [NUM_PORTS-1:0] [31:0]   gen_src_ip;
    logic [NUM_PORTS-1:0] [31:0]   gen_dst_ip;
    logic [NUM_PORTS-1:0] [15:0]   gen_udp_sp;
    logic [NUM_PORTS-1:0] [15:0]   gen_udp_dp;

    // Per-port and per-flow counters from the data plane back into
    // the CSR for snapshot exposure.
    logic [31:0] port_drops_w  [NUM_PORTS];
    logic [63:0] flow_rx_w        [NUM_FLOWS];
    logic [63:0] flow_lost_w      [NUM_FLOWS];
    logic [63:0] flow_dup_w       [NUM_FLOWS];
    logic [63:0] flow_ooo_w       [NUM_FLOWS];
    logic [63:0] flow_last_seq_w  [NUM_FLOWS];
    logic [63:0] flow_min_lat_w   [NUM_FLOWS];
    logic [63:0] flow_max_lat_w   [NUM_FLOWS];
    logic [63:0] flow_sum_lat_w   [NUM_FLOWS];
    logic [63:0] flow_samples_w   [NUM_FLOWS];
    logic [63:0] flow_hist_w      [NUM_FLOWS * NUM_HIST_BINS];

    pw_csr_full #(
        .ADDR_W          (ADDR_W),
        .CAPABILITIES    (CAPABILITIES),
        .NUM_PORTS       (NUM_PORTS),
        .NUM_FLOWS       (NUM_FLOWS),
        .NUM_LOGICAL_IFS (NUM_LOGICAL_IFS),
        .NUM_CLASSIFIER  (NUM_CLASSIFIER),
        .NUM_HIST_BINS   (NUM_HIST_BINS)
    ) u_csr (
        .s_axi_aclk          (clk),
        .s_axi_aresetn       (rst_n),
        .s_axi_awaddr        (s_axi_awaddr),
        .s_axi_awvalid       (s_axi_awvalid),
        .s_axi_awready       (s_axi_awready),
        .s_axi_wdata         (s_axi_wdata),
        .s_axi_wstrb         (s_axi_wstrb),
        .s_axi_wvalid        (s_axi_wvalid),
        .s_axi_wready        (s_axi_wready),
        .s_axi_bresp         (s_axi_bresp),
        .s_axi_bvalid        (s_axi_bvalid),
        .s_axi_bready        (s_axi_bready),
        .s_axi_araddr        (s_axi_araddr),
        .s_axi_arvalid       (s_axi_arvalid),
        .s_axi_arready       (s_axi_arready),
        .s_axi_rdata         (s_axi_rdata),
        .s_axi_rresp         (s_axi_rresp),
        .s_axi_rvalid        (s_axi_rvalid),
        .s_axi_rready        (s_axi_rready),
        .timestamp_i         (timestamp_i),
        .global_control_o    (),
        .error_status_set_i  (32'h0),
        .port_drops_i        (port_drops_w),
        .flow_rx_i           (flow_rx_w),
        .flow_lost_i         (flow_lost_w),
        .flow_dup_i          (flow_dup_w),
        .flow_ooo_i          (flow_ooo_w),
        .flow_last_seq_i     (flow_last_seq_w),
        .flow_min_lat_i      (flow_min_lat_w),
        .flow_max_lat_i      (flow_max_lat_w),
        .flow_sum_lat_i      (flow_sum_lat_w),
        .flow_samples_i      (flow_samples_w),
        .flow_hist_i         (flow_hist_w),
        .cls_table_o         (cls_table),
        .gen_enable_o        (gen_enable),
        .gen_tokens_fp_o     (gen_tokens_fp),
        .gen_burst_o         (gen_burst),
        .gen_src_mac_o       (gen_src_mac),
        .gen_dst_mac_o       (gen_dst_mac),
        .gen_vlan_en_o       (gen_vlan_en),
        .gen_vlan_id_o       (gen_vlan_id),
        .gen_src_ip_o        (gen_src_ip),
        .gen_dst_ip_o        (gen_dst_ip),
        .gen_udp_sp_o        (gen_udp_sp),
        .gen_udp_dp_o        (gen_udp_dp)
    );

    // --- Per-port AXIS deserializer (MAC RX -> wide rx_frame) ---
    pw_frame_t rx_frame_w [NUM_PORTS];
    logic      rx_valid_w [NUM_PORTS];

    generate
        for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : g_deser
            pw_axis_deserializer u_des (
                .clk            (clk),
                .rst_n          (rst_n),
                .s_tdata        (s_axis_rx_tdata[gp]),
                .s_tkeep        (s_axis_rx_tkeep[gp]),
                .s_tvalid       (s_axis_rx_tvalid[gp]),
                .s_tready       (s_axis_rx_tready[gp]),
                .s_tlast        (s_axis_rx_tlast[gp]),
                .frame_o        (rx_frame_w[gp]),
                .frame_valid_o  (rx_valid_w[gp]),
                .ingress_port_i (4'(gp))
            );
        end
    endgenerate

    // --- Data plane --------------------------------------------
    pw_frame_t      tx_frame_w [NUM_PORTS];
    logic           tx_valid_w [NUM_PORTS];
    logic           tx_ready_w [NUM_PORTS];
    pw_frame_t      punt_frame_w;
    logic           punt_valid_w;

    // Unpack the CSR's per-port packed inputs into the data plane's
    // unpacked-array port shape.
    logic        gen_enable_u   [NUM_PORTS];
    logic [31:0] gen_tokens_u   [NUM_PORTS];
    logic [15:0] gen_burst_u    [NUM_PORTS];
    logic [47:0] gen_src_mac_u  [NUM_PORTS];
    logic [47:0] gen_dst_mac_u  [NUM_PORTS];
    logic        gen_vlan_en_u  [NUM_PORTS];
    logic [11:0] gen_vlan_id_u  [NUM_PORTS];
    logic [31:0] gen_src_ip_u   [NUM_PORTS];
    logic [31:0] gen_dst_ip_u   [NUM_PORTS];
    logic [15:0] gen_udp_sp_u   [NUM_PORTS];
    logic [15:0] gen_udp_dp_u   [NUM_PORTS];

    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            gen_enable_u  [p] = gen_enable[p];
            gen_tokens_u  [p] = gen_tokens_fp[p];
            gen_burst_u   [p] = gen_burst[p];
            gen_src_mac_u [p] = gen_src_mac[p];
            gen_dst_mac_u [p] = gen_dst_mac[p];
            gen_vlan_en_u [p] = gen_vlan_en[p];
            gen_vlan_id_u [p] = gen_vlan_id[p];
            gen_src_ip_u  [p] = gen_src_ip[p];
            gen_dst_ip_u  [p] = gen_dst_ip[p];
            gen_udp_sp_u  [p] = gen_udp_sp[p];
            gen_udp_dp_u  [p] = gen_udp_dp[p];
        end
    end

    pw_data_plane #(
        .PW_PORTS      (NUM_PORTS),
        .PW_NUM_FLOWS  (NUM_FLOWS),
        .PW_NUM_BUCKETS(NUM_HIST_BINS)
    ) u_dp (
        .clk            (clk),
        .rst_n          (rst_n),
        .timestamp_i    (timestamp_i),
        .cls_table_i    (cls_table),
        .rx_frame_i     (rx_frame_w),
        .rx_valid_i     (rx_valid_w),
        .tx_frame_o     (tx_frame_w),
        .tx_valid_o     (tx_valid_w),
        .tx_ready_i     (tx_ready_w),
        .punt_frame_o   (punt_frame_w),
        .punt_valid_o   (punt_valid_w),
        .gen_enable_i   (gen_enable_u),
        .gen_tokens_fp_i(gen_tokens_u),
        .gen_burst_i    (gen_burst_u),
        .gen_src_mac_i  (gen_src_mac_u),
        .gen_dst_mac_i  (gen_dst_mac_u),
        .gen_vlan_en_i  (gen_vlan_en_u),
        .gen_vlan_id_i  (gen_vlan_id_u),
        .gen_src_ip_i   (gen_src_ip_u),
        .gen_dst_ip_i   (gen_dst_ip_u),
        .gen_udp_sp_i   (gen_udp_sp_u),
        .gen_udp_dp_i   (gen_udp_dp_u),
        .flow_rx        (flow_rx_w),
        .flow_lost      (flow_lost_w),
        .flow_dup       (flow_dup_w),
        .flow_ooo       (flow_ooo_w),
        .flow_last_seq  (flow_last_seq_w),
        .flow_min_lat   (flow_min_lat_w),
        .flow_max_lat   (flow_max_lat_w),
        .flow_sum_lat   (flow_sum_lat_w),
        .flow_samples   (flow_samples_w),
        .flow_hist      (flow_hist_w),
        .port_drops_o   (port_drops_w)
    );

    // --- Per-port AXIS serializer (wide tx_frame -> MAC TX) ----
    generate
        for (genvar gp2 = 0; gp2 < NUM_PORTS; gp2++) begin : g_ser
            pw_axis_serializer u_ser (
                .clk            (clk),
                .rst_n          (rst_n),
                .frame_i        (tx_frame_w[gp2]),
                .frame_valid_i  (tx_valid_w[gp2]),
                .frame_ready_o  (tx_ready_w[gp2]),
                .m_tdata        (m_axis_tx_tdata[gp2]),
                .m_tkeep        (m_axis_tx_tkeep[gp2]),
                .m_tvalid       (m_axis_tx_tvalid[gp2]),
                .m_tready       (m_axis_tx_tready[gp2]),
                .m_tlast        (m_axis_tx_tlast[gp2])
            );
        end
    endgenerate

    // --- Punt path: serialize the wide punt frame -------------
    logic punt_ready_w;
    pw_axis_serializer u_ser_punt (
        .clk            (clk),
        .rst_n          (rst_n),
        .frame_i        (punt_frame_w),
        .frame_valid_i  (punt_valid_w),
        .frame_ready_o  (punt_ready_w),
        .m_tdata        (m_axis_punt_tdata),
        .m_tkeep        (m_axis_punt_tkeep),
        .m_tvalid       (m_axis_punt_tvalid),
        .m_tready       (m_axis_punt_tready),
        .m_tlast        (m_axis_punt_tlast)
    );

endmodule

`default_nettype wire
