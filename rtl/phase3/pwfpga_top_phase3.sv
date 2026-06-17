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
// / stats / histogram windows) and pw_data_plane_axis, the 64-bit
// AXIS streaming data plane. The MAC's 64-bit AXIS RX/TX wire
// straight into the data plane -- no wide-frame serializer /
// deserializer (the wide pw_frame_t bus did not route on silicon).

`default_nettype none

import pw_classifier_pkg::*;
import pw_axis_pkg::*;

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

    // (The PUNT_TO_HOST / MIRROR_TO_HOST path is consumed internally by
    // pw_punt_rx_window and read back over the CSR BAR -- no top-level
    // punt AXIS port any more.)

    // Free-running 64-bit timestamp (driven by pw_timestamp on the
    // board top; the sim drives this from a tb counter).
    input  wire [63:0]       timestamp_i,

    // In-system SPI flash master -- board top wires these to STARTUPE3.
    output wire              spi_sck_o,
    output wire              spi_cs_n_o,
    output wire              spi_mosi_o,
    input  wire              spi_miso_i,

    // In-band reconfig -- board top wires these to ICAPE3.
    output wire              icap_csib_o,
    output wire              icap_rdwrb_o,
    output wire [31:0]       icap_i_o
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

    // Live histogram read port (CSR <-> data-plane BRAM).
    logic [15:0] hist_rd_addr_w;
    logic [63:0] hist_rd_data_w;

    // Punt path: data plane punt AXIS -> pw_punt_rx_window; CSR read/pop.
    logic [63:0] punt_td_w;  logic [7:0] punt_tk_w;
    logic        punt_tv_w,  punt_tr_w,  punt_tl_w;
    logic [35:0] punt_tu_w;
    logic        punt_rd_en_w; logic [15:0] punt_rd_addr_w; logic [31:0] punt_rd_data_w;
    logic        punt_pop_w;

    // Slow-path TX inject: pw_csr_full (inject window) -> data plane egress.
    logic [63:0] inj_td_w;  logic [7:0] inj_tk_w;
    logic        inj_tv_w,  inj_tr_w,  inj_tl_w;
    logic [3:0]  inj_eg_w;

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
        .hist_rd_addr_o      (hist_rd_addr_w),
        .hist_rd_data_i      (hist_rd_data_w),
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
        .gen_udp_dp_o        (gen_udp_dp),
        .flow_rows_o         (flow_rows_w),
        .stats_clear_o       (stats_clear_w),
        .dp_soft_rst_o       (dp_soft_rst_w),
        .spi_sck_o           (spi_sck_o),
        .spi_cs_n_o          (spi_cs_n_o),
        .spi_mosi_o          (spi_mosi_o),
        .spi_miso_i          (spi_miso_i),
        .icap_reboot_o       (icap_reboot_w),
        .punt_rd_en_o        (punt_rd_en_w),
        .punt_rd_addr_o      (punt_rd_addr_w),
        .punt_rd_data_i      (punt_rd_data_w),
        .punt_pop_o          (punt_pop_w),
        .inj_m_tdata         (inj_td_w),
        .inj_m_tkeep         (inj_tk_w),
        .inj_m_tvalid        (inj_tv_w),
        .inj_m_tready        (inj_tr_w),
        .inj_m_tlast         (inj_tl_w),
        .inj_egress_o        (inj_eg_w)
    );

    // Punt / slow-path RX window: sinks the data plane punt AXIS, host
    // drains it over the CSR BAR (PWFPGA_WIN_PUNT_RX).
    pw_punt_rx_window #(
        .ADDR_W    (16),
        .BUF_BEATS (256)            // 2 KB max punt frame
    ) u_punt (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_tdata       (punt_td_w),
        .s_tkeep       (punt_tk_w),
        .s_tvalid      (punt_tv_w),
        .s_tready      (punt_tr_w),
        .s_tlast       (punt_tl_w),
        .s_tuser       (punt_tu_w),
        .rd_en_i       (punt_rd_en_w),
        .rd_addr_i     (punt_rd_addr_w),
        .rd_data_o     (punt_rd_data_w),
        .pop_i         (punt_pop_w),
        .frame_valid_o ()
    );

    // In-band reconfiguration: CSR magic -> ICAP IPROG -> reload from flash.
    logic icap_reboot_w;
    pw_icap_reboot #(.WBSTAR(32'h0000_0000)) u_icap (
        .clk        (clk),
        .rst_n      (rst_n),
        .reboot_i   (icap_reboot_w),
        .icap_csib  (icap_csib_o),
        .icap_rdwrb (icap_rdwrb_o),
        .icap_i     (icap_i_o),
        .icap_busy_o()
    );

    // --- Streaming data plane (MAC AXIS straight through) -------
    // The multi-flow generators take the full decoded flow table from the
    // CSR; each egress port's generator emits the rows targeting it.
    pw_flow_row_t flow_rows_w [NUM_FLOWS];
    logic         stats_clear_w;
    logic         dp_soft_rst_w;

    pw_data_plane_axis #(
        .PW_PORTS      (NUM_PORTS),
        .PW_NUM_FLOWS  (NUM_FLOWS),
        .PW_NUM_BUCKETS(NUM_HIST_BINS)
    ) u_dp (
        .clk               (clk),
        .rst_n             (rst_n),
        .timestamp_i       (timestamp_i),
        .stats_clear_i     (stats_clear_w),
        .dp_soft_rst_i     (dp_soft_rst_w),
        .cls_table_i       (cls_table),
        .s_axis_rx_tdata   (s_axis_rx_tdata),
        .s_axis_rx_tkeep   (s_axis_rx_tkeep),
        .s_axis_rx_tvalid  (s_axis_rx_tvalid),
        .s_axis_rx_tready  (s_axis_rx_tready),
        .s_axis_rx_tlast   (s_axis_rx_tlast),
        .m_axis_tx_tdata   (m_axis_tx_tdata),
        .m_axis_tx_tkeep   (m_axis_tx_tkeep),
        .m_axis_tx_tvalid  (m_axis_tx_tvalid),
        .m_axis_tx_tready  (m_axis_tx_tready),
        .m_axis_tx_tlast   (m_axis_tx_tlast),
        .m_axis_punt_tdata (punt_td_w),
        .m_axis_punt_tkeep (punt_tk_w),
        .m_axis_punt_tvalid(punt_tv_w),
        .m_axis_punt_tready(punt_tr_w),
        .m_axis_punt_tlast (punt_tl_w),
        .m_axis_punt_tuser (punt_tu_w),
        .s_axis_inj_tdata  (inj_td_w),
        .s_axis_inj_tkeep  (inj_tk_w),
        .s_axis_inj_tvalid (inj_tv_w),
        .s_axis_inj_tready (inj_tr_w),
        .s_axis_inj_tlast  (inj_tl_w),
        .s_axis_inj_egress (inj_eg_w),
        .flow_rows_i       (flow_rows_w),
        .flow_rx           (flow_rx_w),
        .flow_lost         (flow_lost_w),
        .flow_dup          (flow_dup_w),
        .flow_ooo          (flow_ooo_w),
        .flow_last_seq     (flow_last_seq_w),
        .flow_min_lat      (flow_min_lat_w),
        .flow_max_lat      (flow_max_lat_w),
        .flow_sum_lat      (flow_sum_lat_w),
        .flow_samples      (flow_samples_w),
        .hist_rd_addr_i    (hist_rd_addr_w),
        .hist_rd_data_o    (hist_rd_data_w),
        .port_drops_o      (port_drops_w)
    );

endmodule

`default_nettype wire
