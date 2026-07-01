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
    parameter int          NUM_HIST_BINS   = 16,
    parameter int          NUM_CMP         = 12,   // field-classifier field comparators
    parameter int          NUM_UDF         = 2,    // field-classifier UDF comparators
    parameter int          NUM_RULE        = 32,   // field-classifier combine rules
    parameter int          SLICE_WIN       = 48,   // UDF match window depth
    parameter int          HASH_DEPTH      = 128    // hash exact-table buckets
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
    input  wire              s_axis_rx_tuser  [NUM_PORTS],
    // RX ingress wire-timestamp per port (board top samples it in the MAC RX
    // clock domain). Routed to the data plane's RX checker as the true RX time.
    input  wire [63:0]       s_axis_rx_wire_ts [NUM_PORTS],

    // Link-health status levels (async MAC/PCS), synchronized in the data plane.
    input  wire              link_up_i        [NUM_PORTS],
    input  wire              block_lock_i     [NUM_PORTS],

    // Per-port MAC TX (64-bit AXIS from data plane to MAC)
    output wire [63:0]       m_axis_tx_tdata  [NUM_PORTS],
    output wire [7:0]        m_axis_tx_tkeep  [NUM_PORTS],
    output wire              m_axis_tx_tvalid [NUM_PORTS],
    input  wire              m_axis_tx_tready [NUM_PORTS],
    output wire              m_axis_tx_tlast  [NUM_PORTS],
    // "generator test frame" marker for the egress stamper (NOT MAC tx-error)
    output wire              m_axis_tx_tuser  [NUM_PORTS],

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
    output wire [31:0]       icap_i_o,

    // Data-plane soft-reset pulse (CSR DP_RESET, 1 clk). Exposed so the board
    // top can also flush the MAC-TX CDC + ts_insert (their tx_clk domain is
    // outside this core's reset), making an egress wedge recoverable without a
    // full bitstream reload. Safe to leave unconnected.
    output wire              dp_soft_rst_o,

    // J5 GPIO for cross-card time-sync (pw_gpio_sync). The board top owns the
    // bidirectional pads (IOBUF) and presents the split in/out/tri here.
    input  wire [5:0]        gpio_i,
    output wire [5:0]        gpio_o,
    output wire [5:0]        gpio_t,

    // Per-SFP I2C management (SW bit-bang, open-drain). The board top owns the
    // IOBUFs; here we present the split in/out/tri, one bit per line:
    //   [0] SFP0 SCL  [1] SFP0 SDA  [2] SFP1 SCL  [3] SFP1 SDA.
    // Output is always 0 (open-drain drives only low); _t releases the line
    // (hi-Z -> external pull-up = 1) except when the CSR asserts drive-low.
    input  wire [3:0]        sfp_i2c_i,
    output wire [3:0]        sfp_i2c_o,
    output wire [3:0]        sfp_i2c_t,

    // Aggregate data-plane health for the front-panel R/G LED (dp_clk domain;
    // the board top synchronises + drives the LED). status_err = sticky error
    // since the last stats-clear (loss / FCS / drop); status_activity = traffic
    // recent (green blink).
    output wire              status_err_o,
    output wire              status_activity_o,

    // On-chip SYSMON telemetry (raw DRP ADC codes, measurement in [15:4]),
    // produced by pw_sysmon + SYSMONE4 in the board top. Same clk domain.
    input  wire [15:0]       sysmon_temp_i,
    input  wire [15:0]       sysmon_vccint_i,
    input  wire [15:0]       sysmon_vccaux_i
);

    // --- Data-plane <-> CSR_full wiring -------------------------

    // Per-port and per-flow counters from the data plane back into
    // the CSR for snapshot exposure.
    // GPIO cross-card time-sync wiring (CSR <-> pw_gpio_sync).
    logic [31:0] gpio_sync_ctrl_w;
    logic [63:0] gpio_sync_ts_w;
    logic [31:0] gpio_sync_seq_w;
    logic [5:0]  gpio_sync_gpin_w;
    // Per-flow cross-card latency correction (CSR window -> data-plane table).
    logic                          lat_corr_wr_en_w;
    logic [$clog2(NUM_FLOWS)-1:0]  lat_corr_wr_slot_w;
    logic [63:0]                   lat_corr_wr_data_w;

    // Per-SFP I2C bit-bang (CSR <-> board IOBUFs). The CSR drives "drive-low"
    // enables; open-drain means the pad output is always 0 and _t releases the
    // line unless a drive-low is asserted. The async pad inputs are 2FF-synced
    // into this (CSR) clock before the CSR reads them back.
    logic [3:0] sfp_i2c_drive_low_w;
    (* ASYNC_REG = "true" *) logic [3:0] sfp_i2c_sync0, sfp_i2c_sync1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sfp_i2c_sync0 <= 4'hF; sfp_i2c_sync1 <= 4'hF; end
        else        begin sfp_i2c_sync0 <= sfp_i2c_i; sfp_i2c_sync1 <= sfp_i2c_sync0; end
    end
    assign sfp_i2c_o = 4'b0000;                 // open-drain: only ever drive low
    assign sfp_i2c_t = ~sfp_i2c_drive_low_w;    // release (hi-Z) unless driving low

    logic [31:0] port_drops_w  [NUM_PORTS];
    logic [47:0] rx_frames_w   [NUM_PORTS];
    logic [47:0] rx_bytes_w    [NUM_PORTS];
    logic [47:0] tx_frames_w   [NUM_PORTS];
    logic [47:0] tx_bytes_w    [NUM_PORTS];
    logic [47:0] rx_fcs_err_w  [NUM_PORTS];
    logic [31:0] link_up_cnt_w     [NUM_PORTS];
    logic [31:0] link_down_cnt_w   [NUM_PORTS];
    logic [31:0] block_lock_loss_w [NUM_PORTS];
    // Per-flow stats: BRAM-backed in the data plane, read one flow at a time.
    // The snapshot (in csr_full) drives flow_rd_addr_w; the merged record comes
    // back on these scalar nets 2 cycles later.
    logic [$clog2(NUM_FLOWS)-1:0] flow_rd_addr_w;
    logic [63:0] flow_rx_w;
    logic [63:0] flow_lost_w;
    logic [63:0] flow_dup_w;
    logic [63:0] flow_ooo_w;
    logic [63:0] flow_last_seq_w;
    logic [63:0] flow_min_lat_w;
    logic [63:0] flow_max_lat_w;
    logic [63:0] flow_sum_lat_w;
    logic [63:0] flow_samples_w;
    logic [31:0] flow_jit_min_w;
    logic [31:0] flow_jit_max_w;
    logic [63:0] flow_jit_sum_w;
    logic [47:0] flow_tx_w;

    // Live histogram read port (CSR <-> data-plane BRAM).
    logic [15:0] hist_rd_addr_w;
    logic [63:0] hist_rd_data_w;

    // Punt path: data plane punt AXIS -> pw_punt_rx_window; CSR read/pop.
    logic [63:0] punt_td_w;  logic [7:0] punt_tk_w;
    logic        punt_tv_w,  punt_tr_w,  punt_tl_w;
    logic [99:0] punt_tu_w;   // {rx_ts[63:0], ingress[3:0], lif[31:0]}
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
        .NUM_HIST_BINS   (NUM_HIST_BINS),
        .NCMP            (NUM_CMP),
        .NUDF            (NUM_UDF),
        .NRULE           (NUM_RULE),
        .HASH_DEPTH      (HASH_DEPTH)
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
        // Live LED/health readback (same clk domain, no CDC) + SYSMON telemetry.
        .status_err_i        (status_err_o),
        .status_activity_i   (status_activity_o),
        .sysmon_temp_i       (sysmon_temp_i),
        .sysmon_vccint_i     (sysmon_vccint_i),
        .sysmon_vccaux_i     (sysmon_vccaux_i),
        .gpio_sync_ctrl_o    (gpio_sync_ctrl_w),
        .gpio_sync_ts_i      (gpio_sync_ts_w),
        .gpio_sync_seq_i     (gpio_sync_seq_w),
        .gpio_sync_gpio_in_i (gpio_sync_gpin_w),
        .sfp_i2c_drive_low_o (sfp_i2c_drive_low_w),
        .sfp_i2c_in_i        (sfp_i2c_sync1),
        .lat_corr_wr_en_o    (lat_corr_wr_en_w),
        .lat_corr_wr_slot_o  (lat_corr_wr_slot_w),
        .lat_corr_wr_data_o  (lat_corr_wr_data_w),
        .port_drops_i        (port_drops_w),
        .rx_fcs_err_i        (rx_fcs_err_w),
        .link_up_cnt_i       (link_up_cnt_w),
        .link_down_cnt_i     (link_down_cnt_w),
        .block_lock_loss_i   (block_lock_loss_w),
        .rx_frames_i         (rx_frames_w),
        .rx_bytes_i          (rx_bytes_w),
        .tx_frames_i         (tx_frames_w),
        .tx_bytes_i          (tx_bytes_w),
        .flow_rd_addr_o      (flow_rd_addr_w),
        .flow_rx_i           (flow_rx_w),
        .flow_lost_i         (flow_lost_w),
        .flow_dup_i          (flow_dup_w),
        .flow_ooo_i          (flow_ooo_w),
        .flow_last_seq_i     (flow_last_seq_w),
        .flow_min_lat_i      (flow_min_lat_w),
        .flow_max_lat_i      (flow_max_lat_w),
        .flow_sum_lat_i      (flow_sum_lat_w),
        .flow_samples_i      (flow_samples_w),
        .flow_jit_min_i      (flow_jit_min_w),
        .flow_jit_max_i      (flow_jit_max_w),
        .flow_jit_sum_i      (flow_jit_sum_w),
        .flow_tx_i           (flow_tx_w),
        .hist_rd_addr_o      (hist_rd_addr_w),
        .hist_rd_data_i      (hist_rd_data_w),
        .flow_wr_en_o        (flow_wr_en_w),
        .flow_wr_addr_o      (flow_wr_addr_w),
        .flow_wr_data_o      (flow_wr_data_w),
        .map_wr_en_o         (map_wr_en_w),
        .map_wr_addr_o       (map_wr_addr_w),
        .map_wr_valid_o      (map_wr_valid_w),
        .map_wr_lfid_o       (map_wr_lfid_w),
        .cmp_wr_en_o         (cmp_wr_en_w),
        .cmp_wr_idx_o        (cmp_wr_idx_w),
        .cmp_wr_src_o        (cmp_wr_src_w),
        .cmp_wr_mask_o       (cmp_wr_mask_w),
        .cmp_wr_value_o      (cmp_wr_value_w),
        .udf_wr_en_o         (udf_wr_en_w),
        .udf_wr_idx_o        (udf_wr_idx_w),
        .udf_wr_offset_o     (udf_wr_offset_w),
        .udf_wr_mask_o       (udf_wr_mask_w),
        .udf_wr_value_o      (udf_wr_value_w),
        .rule_wr_en_o        (rule_wr_en_w),
        .rule_wr_idx_o       (rule_wr_idx_w),
        .rule_wr_care_o      (rule_wr_care_w),
        .rule_wr_action_o    (rule_wr_action_w),
        .rule_wr_egress_o    (rule_wr_egress_w),
        .rule_wr_lfid_o      (rule_wr_lfid_w),
        .rule_wr_lif_o       (rule_wr_lif_w),
        .rule_wr_prio_o      (rule_wr_prio_w),
        .rule_wr_enable_o    (rule_wr_enable_w),
        .hash_seed_o         (hash_seed_w),
        .hash_mask_o         (hash_mask_w),
        .hash_wr_en_o        (hash_wr_en_w),
        .hash_wr_index_o     (hash_wr_index_w),
        .hash_wr_valid_o     (hash_wr_valid_w),
        .hash_wr_key_o       (hash_wr_key_w),
        .hash_wr_lfid_o      (hash_wr_lfid_w),
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
    logic              flow_wr_en_w;
    logic [15:0]       flow_wr_addr_w;
    logic [31:0]       flow_wr_data_w;
    logic                          map_wr_en_w;
    logic [7:0]                    map_wr_addr_w;   // MAP_DEPTH=256
    logic                          map_wr_valid_w;
    logic [$clog2(NUM_FLOWS)-1:0]  map_wr_lfid_w;
    // Generic slice-classifier programming (csr_full -> data plane).
    logic                          cmp_wr_en_w;
    logic [$clog2(NUM_CMP)-1:0]    cmp_wr_idx_w;
    logic [4:0]                    cmp_wr_src_w;
    logic [31:0]                   cmp_wr_mask_w;
    logic [31:0]                   cmp_wr_value_w;
    logic                          udf_wr_en_w;
    logic [$clog2(NUM_UDF)-1:0]    udf_wr_idx_w;
    logic [15:0]                   udf_wr_offset_w;
    logic [31:0]                   udf_wr_mask_w;
    logic [31:0]                   udf_wr_value_w;
    logic                          rule_wr_en_w;
    logic [$clog2(NUM_RULE)-1:0]   rule_wr_idx_w;
    logic [NUM_CMP+NUM_UDF-1:0]    rule_wr_care_w;
    logic [2:0]                    rule_wr_action_w;
    logic [3:0]                    rule_wr_egress_w;
    logic [31:0]                   rule_wr_lfid_w;
    logic [31:0]                   rule_wr_lif_w;
    logic [7:0]                    rule_wr_prio_w;
    logic                          rule_wr_enable_w;
    logic [31:0]                   hash_seed_w;
    logic [351:0]                  hash_mask_w;
    logic                          hash_wr_en_w;
    logic [$clog2(HASH_DEPTH)-1:0] hash_wr_index_w;
    logic                          hash_wr_valid_w;
    logic [351:0]                  hash_wr_key_w;
    logic [$clog2(NUM_FLOWS)-1:0]  hash_wr_lfid_w;
    logic         stats_clear_w;
    logic         dp_soft_rst_w;
    assign dp_soft_rst_o = dp_soft_rst_w;

    pw_data_plane_axis #(
        .PW_PORTS      (NUM_PORTS),
        .PW_NUM_FLOWS  (NUM_FLOWS),
        .PW_NUM_BUCKETS(NUM_HIST_BINS),
        .NCMP          (NUM_CMP),
        .NUDF          (NUM_UDF),
        .NRULE         (NUM_RULE),
        .SLICE_WIN     (SLICE_WIN),
        .HASH_DEPTH    (HASH_DEPTH)
    ) u_dp (
        .clk               (clk),
        .rst_n             (rst_n),
        .timestamp_i       (timestamp_i),
        .lat_corr_wr_en_i  (lat_corr_wr_en_w),
        .lat_corr_wr_slot_i(lat_corr_wr_slot_w),
        .lat_corr_wr_data_i(lat_corr_wr_data_w),
        .stats_clear_i     (stats_clear_w),
        .dp_soft_rst_i     (dp_soft_rst_w),
        .s_axis_rx_tdata   (s_axis_rx_tdata),
        .s_axis_rx_tkeep   (s_axis_rx_tkeep),
        .s_axis_rx_tvalid  (s_axis_rx_tvalid),
        .s_axis_rx_tready  (s_axis_rx_tready),
        .s_axis_rx_tlast   (s_axis_rx_tlast),
        .s_axis_rx_tuser   (s_axis_rx_tuser),
        .s_axis_rx_wire_ts (s_axis_rx_wire_ts),
        .link_up_i         (link_up_i),
        .block_lock_i      (block_lock_i),
        .m_axis_tx_tdata   (m_axis_tx_tdata),
        .m_axis_tx_tkeep   (m_axis_tx_tkeep),
        .m_axis_tx_tvalid  (m_axis_tx_tvalid),
        .m_axis_tx_tready  (m_axis_tx_tready),
        .m_axis_tx_tlast   (m_axis_tx_tlast),
        .m_axis_tx_tuser   (m_axis_tx_tuser),
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
        .flow_wr_en_i      (flow_wr_en_w),
        .flow_wr_addr_i    (flow_wr_addr_w),
        .flow_wr_data_i    (flow_wr_data_w),
        // TEST_RX flow-id map programming (from the CSR map window via csr_full).
        .map_wr_en_i       (map_wr_en_w),
        .map_wr_addr_i     (map_wr_addr_w),
        .map_wr_valid_i    (map_wr_valid_w),
        .map_wr_lfid_i     (map_wr_lfid_w),
        // Generic slice-classifier programming (from the CSR slice/rule windows).
        .cmp_wr_en_i       (cmp_wr_en_w),
        .cmp_wr_idx_i      (cmp_wr_idx_w),
        .cmp_wr_src_i      (cmp_wr_src_w),
        .cmp_wr_mask_i     (cmp_wr_mask_w),
        .cmp_wr_value_i    (cmp_wr_value_w),
        .udf_wr_en_i       (udf_wr_en_w),
        .udf_wr_idx_i      (udf_wr_idx_w),
        .udf_wr_offset_i   (udf_wr_offset_w),
        .udf_wr_mask_i     (udf_wr_mask_w),
        .udf_wr_value_i    (udf_wr_value_w),
        .rule_wr_en_i      (rule_wr_en_w),
        .rule_wr_idx_i     (rule_wr_idx_w),
        .rule_wr_care_i    (rule_wr_care_w),
        .rule_wr_action_i  (rule_wr_action_w),
        .rule_wr_egress_i  (rule_wr_egress_w),
        .rule_wr_lfid_i    (rule_wr_lfid_w),
        .rule_wr_lif_i     (rule_wr_lif_w),
        .rule_wr_prio_i    (rule_wr_prio_w),
        .rule_wr_enable_i  (rule_wr_enable_w),
        .hash_seed_i       (hash_seed_w),
        .hash_mask_i       (hash_mask_w),
        .hash_wr_en_i      (hash_wr_en_w),
        .hash_wr_index_i   (hash_wr_index_w),
        .hash_wr_valid_i   (hash_wr_valid_w),
        .hash_wr_key_i     (hash_wr_key_w),
        .hash_wr_lfid_i    (hash_wr_lfid_w),
        .flow_rd_addr_i    (flow_rd_addr_w),
        .flow_rx           (flow_rx_w),
        .flow_lost         (flow_lost_w),
        .flow_dup          (flow_dup_w),
        .flow_ooo          (flow_ooo_w),
        .flow_last_seq     (flow_last_seq_w),
        .flow_min_lat      (flow_min_lat_w),
        .flow_max_lat      (flow_max_lat_w),
        .flow_sum_lat      (flow_sum_lat_w),
        .flow_samples      (flow_samples_w),
        .flow_jit_min      (flow_jit_min_w),
        .flow_jit_max      (flow_jit_max_w),
        .flow_jit_sum      (flow_jit_sum_w),
        .flow_tx           (flow_tx_w),
        .hist_rd_addr_i    (hist_rd_addr_w),
        .hist_rd_data_o    (hist_rd_data_w),
        .port_drops_o      (port_drops_w),
        .rx_frames_o       (rx_frames_w),
        .rx_bytes_o        (rx_bytes_w),
        .tx_frames_o       (tx_frames_w),
        .tx_bytes_o        (tx_bytes_w),
        .rx_fcs_error_o    (rx_fcs_err_w),
        .link_up_cnt_o     (link_up_cnt_w),
        .link_down_cnt_o   (link_down_cnt_w),
        .block_lock_loss_o (block_lock_loss_w),
        .err_sticky_o      (status_err_o),
        .activity_o        (status_activity_o)
    );

    // --- J5 GPIO cross-card time-sync ---------------------------------------
    // Same dp_clk domain as timestamp_i; latches the free-running counter at a
    // shared sync edge (master originates, slaves listen + optionally repeat).
    pw_gpio_sync #(.NGPIO(6)) u_gpio_sync (
        .clk         (clk),
        .rst_n       (rst_n),
        .timestamp_i (timestamp_i),
        .gpio_i      (gpio_i),
        .gpio_o      (gpio_o),
        .gpio_t      (gpio_t),
        .ctrl_i      (gpio_sync_ctrl_w),
        .sync_ts_o   (gpio_sync_ts_w),
        .sync_seq_o  (gpio_sync_seq_w),
        .gpio_in_o   (gpio_sync_gpin_w)
    );

endmodule

`default_nettype wire
