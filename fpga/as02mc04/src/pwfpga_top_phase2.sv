// AS02MC04 Phase 2 top-level.
//
// Phase 1 (PCIe Gen3 endpoint + BAR0 CSR + heartbeat) plus the dual
// SFP+ 10GBASE-R subsystem (pw_sfp_10g around the Taxi MAC/PCS/GTY).
//
// First Phase 2 milestone: both SFP+ ports achieve 10GBASE-R block lock
// over a DAC between SFP0 and SFP1. TX is held idle (the PCS still emits
// /I/ idles, which is enough for the link partner to lock), and per-port
// link status is surfaced on the user LEDs (as in the Taxi example):
//   led[0] = port0 rx_status (link up),  led[2] = port1 rx_status
//   led[1] = PCIe link up,               led_hb = 1 Hz heartbeat
// RX frame counters / TX template / CSR status come in a later step.

`default_nettype none

module pwfpga_top_phase2 (
    // 100 MHz LVDS housekeeping clock (E18 / D18)
    input  wire        clk_100mhz_p,
    input  wire        clk_100mhz_n,

    // PCIe Gen3 x8
    input  wire        pcie_refclk_p,    // T7
    input  wire        pcie_refclk_n,    // T6
    input  wire        pcie_reset_n,     // A9 (PERST#)
    input  wire [7:0]  pcie_rx_p,
    input  wire [7:0]  pcie_rx_n,
    output wire [7:0]  pcie_tx_p,
    output wire [7:0]  pcie_tx_n,

    // SFP+ MGT reference clock (156.25 MHz, K7 / K6)
    input  wire        sfp_mgt_refclk_p,
    input  wire        sfp_mgt_refclk_n,

    // SFP+ serial lanes (port 0 = GTYE4 X0Y15, port 1 = X0Y14)
    input  wire        sfp_rx_p [2],
    input  wire        sfp_rx_n [2],
    output wire        sfp_tx_p [2],
    output wire        sfp_tx_n [2],

    // Status LEDs
    output wire        led_hb,           // B9 - 1 Hz heartbeat
    output wire [3:0]  led,              // B11 / C11 / A10 / B10
    output wire        sfp_led [2]       // SFP cage link LEDs (DS3 B12 / DS2 C12)
);

    import pw_pkg::*;

    // --- PCIe + AXI-Lite (identical to Phase 1) -----------------------------
    wire        axi_aclk;
    wire        axi_aresetn;
    wire        pcie_link_up;

    wire [11:0] m_axi_awaddr;  wire m_axi_awvalid, m_axi_awready;
    wire [31:0] m_axi_wdata;   wire [3:0] m_axi_wstrb; wire m_axi_wvalid, m_axi_wready;
    wire [1:0]  m_axi_bresp;   wire m_axi_bvalid, m_axi_bready;
    wire [11:0] m_axi_araddr;  wire m_axi_arvalid, m_axi_arready;
    wire [31:0] m_axi_rdata;   wire [1:0] m_axi_rresp; wire m_axi_rvalid, m_axi_rready;

    pcie_axi_lite_bridge #(.AXIL_ADDR_W(12)) u_pcie (
        .pcie_refclk_p (pcie_refclk_p), .pcie_refclk_n (pcie_refclk_n),
        .pcie_perst_n  (pcie_reset_n),
        .pcie_rx_p (pcie_rx_p), .pcie_rx_n (pcie_rx_n),
        .pcie_tx_p (pcie_tx_p), .pcie_tx_n (pcie_tx_n),
        .axi_aclk (axi_aclk), .axi_aresetn (axi_aresetn),
        .m_axi_awaddr (m_axi_awaddr), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata (m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp (m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr (m_axi_araddr), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata (m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .link_up (pcie_link_up)
    );

    // --- Housekeeping clock + reset (100 MHz LVDS domain) -------------------
    wire clk_100mhz;
    wire rst_n_100;
    clock_reset u_clkrst (
        .sys_clk_p (clk_100mhz_p), .sys_clk_n (clk_100mhz_n),
        .sys_rst_n (pcie_reset_n),
        .clk_100mhz (clk_100mhz), .rst_n_100 (rst_n_100),
        .pcie_user_clk (axi_aclk), .pcie_user_resetn (axi_aresetn),
        .clk_axi (), .rst_n_axi ()
    );

    // --- Timestamp + CSR (Phase 1 identity window) --------------------------
    wire [63:0] timestamp;
    pw_timestamp u_ts (.clk (axi_aclk), .rst_n (axi_aresetn), .ts_o (timestamp));

    pw_csr_min #(
        .CAPABILITIES    (PW_PHASE1_CAPABILITIES),
        .NUM_PORTS       (PW_NUM_LOCAL_PORTS),
        .NUM_FLOWS       (0), .NUM_LOGICAL_IFS (0),
        .NUM_CLASSIFIER  (0), .NUM_HIST_BINS   (0)
    ) u_csr (
        .s_axi_aclk (axi_aclk), .s_axi_aresetn (axi_aresetn),
        .s_axi_awaddr (m_axi_awaddr), .s_axi_awvalid (m_axi_awvalid), .s_axi_awready (m_axi_awready),
        .s_axi_wdata (m_axi_wdata), .s_axi_wstrb (m_axi_wstrb), .s_axi_wvalid (m_axi_wvalid), .s_axi_wready (m_axi_wready),
        .s_axi_bresp (m_axi_bresp), .s_axi_bvalid (m_axi_bvalid), .s_axi_bready (m_axi_bready),
        .s_axi_araddr (m_axi_araddr), .s_axi_arvalid (m_axi_arvalid), .s_axi_arready (m_axi_arready),
        .s_axi_rdata (m_axi_rdata), .s_axi_rresp (m_axi_rresp), .s_axi_rvalid (m_axi_rvalid), .s_axi_rready (m_axi_rready),
        .global_control_o (), .error_status_set_i (32'h0), .timestamp_i (timestamp)
    );

    // --- 125 MHz GT free-running / control clock ----------------------------
    // The Taxi GTY helper is generated with FREERUN_FREQUENCY=125, so the
    // transceiver control / reset clock must be 125 MHz. Derive it from the
    // always-on 100 MHz housekeeping clock with an MMCM (VCO 1250 MHz / 10).
    wire clk_125mhz;
    wire mmcm_fb, mmcm_locked, clk_125mhz_unbuf, mmcm_fb_unbuf;
    MMCME4_BASE #(
        .CLKIN1_PERIOD     (10.000),   // 100 MHz
        .CLKFBOUT_MULT_F   (12.500),   // VCO = 1250 MHz
        .DIVCLK_DIVIDE     (1),
        .CLKOUT0_DIVIDE_F  (10.000)    // 125 MHz
    ) u_mmcm_125 (
        .CLKIN1   (clk_100mhz),
        .CLKFBIN  (mmcm_fb),
        .CLKFBOUT (mmcm_fb_unbuf),
        .CLKOUT0  (clk_125mhz_unbuf),
        .CLKOUT0B (), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (!rst_n_100)
    );
    BUFG u_bufg_125    (.I(clk_125mhz_unbuf), .O(clk_125mhz));
    BUFG u_bufg_125_fb (.I(mmcm_fb_unbuf),    .O(mmcm_fb));

    wire ctrl_rst = !rst_n_100 || !mmcm_locked;

    // --- SFP+ 10GBASE-R subsystem -------------------------------------------
    wire        sfp_tx_clk [2];
    wire        sfp_tx_rst [2];
    wire        sfp_rx_clk [2];
    wire        sfp_rx_rst [2];
    wire        sfp_block_lock [2];
    wire        sfp_rx_status [2];
    wire        sfp_gtpowergood;

    // Flat TX AXIS held idle (PCS emits idles -> link partner can lock).
    wire [63:0] sfp_tx_tdata [2];
    wire [7:0]  sfp_tx_tkeep [2];
    wire        sfp_tx_tvalid [2];
    wire        sfp_tx_tready [2];
    wire        sfp_tx_tlast [2];
    wire        sfp_tx_tuser [2];
    // Flat RX AXIS (consumed inside the wrapper for now).
    wire [63:0] sfp_rx_tdata [2];
    wire [7:0]  sfp_rx_tkeep [2];
    wire        sfp_rx_tvalid [2];
    wire        sfp_rx_tlast [2];
    wire        sfp_rx_tuser [2];

    for (genvar p = 0; p < 2; p++) begin : g_sfp_tx_idle
        assign sfp_tx_tdata[p]  = '0;
        assign sfp_tx_tkeep[p]  = '0;
        assign sfp_tx_tvalid[p] = 1'b0;
        assign sfp_tx_tlast[p]  = 1'b0;
        assign sfp_tx_tuser[p]  = 1'b0;
    end

    pw_sfp_10g #(.FAMILY("kintexuplus"), .PORTS(2), .DATA_W(64)) u_sfp (
        .ctrl_clk (clk_125mhz),
        .ctrl_rst (ctrl_rst),
        .sfp_mgt_refclk_p (sfp_mgt_refclk_p),
        .sfp_mgt_refclk_n (sfp_mgt_refclk_n),
        .sfp_tx_p (sfp_tx_p), .sfp_tx_n (sfp_tx_n),
        .sfp_rx_p (sfp_rx_p), .sfp_rx_n (sfp_rx_n),
        .tx_clk (sfp_tx_clk), .tx_rst (sfp_tx_rst),
        .rx_clk (sfp_rx_clk), .rx_rst (sfp_rx_rst),
        .tx_tdata (sfp_tx_tdata), .tx_tkeep (sfp_tx_tkeep), .tx_tvalid (sfp_tx_tvalid),
        .tx_tready (sfp_tx_tready), .tx_tlast (sfp_tx_tlast), .tx_tuser (sfp_tx_tuser),
        .rx_tdata (sfp_rx_tdata), .rx_tkeep (sfp_rx_tkeep), .rx_tvalid (sfp_rx_tvalid),
        .rx_tlast (sfp_rx_tlast), .rx_tuser (sfp_rx_tuser),
        .rx_block_lock (sfp_block_lock),
        .rx_status (sfp_rx_status),
        .gtpowergood (sfp_gtpowergood)
    );

    // --- LEDs ---------------------------------------------------------------
    pw_heartbeat #(.CLK_HZ(100_000_000), .RATE_HZ(1)) u_hb (
        .clk (clk_100mhz), .rst_n (rst_n_100), .led_o (led_hb)
    );

    // SFP cage link LEDs (DS3 / DS2), active-low: lit = 10GBASE-R link up.
    assign sfp_led[0] = !sfp_rx_status[0];
    assign sfp_led[1] = !sfp_rx_status[1];

    // User LED bank (active-low). led[1] = PCIe link up; others off.
    assign led = {1'b1, 1'b1, ~pcie_link_up, 1'b1};

endmodule

`default_nettype wire
