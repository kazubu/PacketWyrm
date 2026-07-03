// PacketWyrm Phase 2: dual SFP+ 10GBASE-R subsystem wrapper.
//
// Encapsulates the Taxi 10G/25G MAC + 10GBASE-R PCS + GTYE4 transceiver
// (taxi_eth_mac_25g_us, CNT=2) for the AS02MC04's two SFP+ cages, and
// presents a flat per-port 64-bit AXI-Stream user interface plus link
// status to the rest of PacketWyrm. The flat AXIS matches what
// pw_axis_serializer / pw_axis_deserializer already speak, so the
// Phase 3 data plane attaches without learning Taxi's SV interfaces.
//
// Clocking / reset / GT plumbing mirrors the proven Taxi AS02MC04 10G
// example (src/eth/example/AS02MC04/fpga/rtl/fpga_core.sv). The GT
// reference clock (156.25 MHz, K7/K6) is buffered here; the 125 MHz
// transceiver control clock is supplied by the top-level MMCM.
//
// Taxi is CERN-OHL-S-2.0 (see top-level LICENSE / NOTICE).

`default_nettype none

module pw_sfp_10g #(
    parameter logic SIM    = 1'b0,
    parameter string VENDOR = "XILINX",
    parameter string FAMILY = "kintexuplus",   // KU3P
    parameter int    PORTS  = 2,
    parameter int    DATA_W = 64
) (
    // 125 MHz transceiver control / stat clock (free-running) + reset
    input  wire logic              ctrl_clk,
    input  wire logic              ctrl_rst,

    // SFP+ MGT reference clock (156.25 MHz differential, K7/K6)
    input  wire logic              sfp_mgt_refclk_p,
    input  wire logic              sfp_mgt_refclk_n,

    // SFP+ serial lanes
    output wire logic              sfp_tx_p [PORTS],
    output wire logic              sfp_tx_n [PORTS],
    input  wire logic              sfp_rx_p [PORTS],
    input  wire logic              sfp_rx_n [PORTS],

    // Per-port MAC clock domains (TX/RX run in their own GT-derived clocks)
    output wire logic              tx_clk   [PORTS],
    output wire logic              tx_rst   [PORTS],
    output wire logic              rx_clk   [PORTS],
    output wire logic              rx_rst   [PORTS],

    // Flat TX AXIS (host -> MAC), in each port's tx_clk domain
    input  wire logic [DATA_W-1:0] tx_tdata  [PORTS],
    input  wire logic [DATA_W/8-1:0] tx_tkeep [PORTS],
    input  wire logic              tx_tvalid [PORTS],
    output wire logic              tx_tready [PORTS],
    input  wire logic              tx_tlast  [PORTS],
    input  wire logic              tx_tuser  [PORTS],   // error/abort

    // Flat RX AXIS (MAC -> host), in each port's rx_clk domain
    output wire logic [DATA_W-1:0] rx_tdata  [PORTS],
    output wire logic [DATA_W/8-1:0] rx_tkeep [PORTS],
    output wire logic              rx_tvalid [PORTS],
    output wire logic              rx_tlast  [PORTS],
    output wire logic              rx_tuser  [PORTS],   // error (bad FCS etc.)

    // Per-port link status (in ctrl/rx domain; consumer should sync)
    output wire logic              rx_block_lock [PORTS],
    output wire logic              rx_status     [PORTS],   // PCS link up
    output wire logic              gtpowergood
);

    // --- GT reference clock buffer ------------------------------------------
    wire sfp_mgt_refclk;       // buffered refclk to GT
    wire sfp_mgt_refclk_int;   // ODIV2 to BUFG_GT
    wire sfp_mgt_refclk_bufg;  // fabric copy (unused here, kept for parity)

    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_refclk_ibuf (
        .I     (sfp_mgt_refclk_p),
        .IB    (sfp_mgt_refclk_n),
        .CEB   (1'b0),
        .O     (sfp_mgt_refclk),
        .ODIV2 (sfp_mgt_refclk_int)
    );

    BUFG_GT u_refclk_bufg (
        .CE      (gtpowergood),
        .CEMASK  (1'b0),
        .CLR     (1'b0),
        .CLRMASK (1'b0),
        .DIV     (3'd0),
        .I       (sfp_mgt_refclk_int),
        .O       (sfp_mgt_refclk_bufg)
    );

    // --- subsystem reset ----------------------------------------------------
    wire sfp_rst;
    taxi_sync_reset #(.N(4)) u_sfp_sync_reset (
        .clk (ctrl_clk),
        .rst (ctrl_rst),
        .out (sfp_rst)
    );

    // --- transceiver control APB (no master: fixed 10G config) --------------
    // Width must match the MAC's internal APB (16-bit data, 18-bit addr),
    // as in the Taxi AS02MC04 example.
    taxi_apb_if #(.ADDR_W(18), .DATA_W(16)) gt_apb_ctrl ();
    assign gt_apb_ctrl.psel    = 1'b0;
    assign gt_apb_ctrl.penable = 1'b0;
    assign gt_apb_ctrl.pwrite  = 1'b0;
    assign gt_apb_ctrl.paddr   = '0;
    assign gt_apb_ctrl.pwdata  = '0;
    assign gt_apb_ctrl.pstrb   = '0;
    assign gt_apb_ctrl.pprot   = '0;

    // --- AXIS interfaces to the MAC -----------------------------------------
    taxi_axis_if #(.DATA_W(DATA_W), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_tx     [PORTS] ();
    taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8))                   axis_tx_cpl [PORTS] ();
    taxi_axis_if #(.DATA_W(DATA_W), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_rx     [PORTS] ();
    taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0),
                   .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(8))        axis_stat   ();

    for (genvar p = 0; p < PORTS; p++) begin : g_axis
        // TX: flat -> interface
        assign axis_tx[p].tdata  = tx_tdata[p];
        assign axis_tx[p].tkeep  = tx_tkeep[p];
        assign axis_tx[p].tvalid = tx_tvalid[p];
        assign axis_tx[p].tlast  = tx_tlast[p];
        assign axis_tx[p].tuser  = tx_tuser[p];
        assign axis_tx[p].tid    = '0;
        assign axis_tx[p].tdest  = '0;
        assign axis_tx[p].tstrb  = '0;
        assign tx_tready[p]      = axis_tx[p].tready;
        // TX completion: consume (not used yet)
        assign axis_tx_cpl[p].tready = 1'b1;
        // RX: interface -> flat
        assign rx_tdata[p]       = axis_rx[p].tdata;
        assign rx_tkeep[p]       = axis_rx[p].tkeep;
        assign rx_tvalid[p]      = axis_rx[p].tvalid;
        assign rx_tlast[p]       = axis_rx[p].tlast;
        assign rx_tuser[p]       = axis_rx[p].tuser;
        assign axis_rx[p].tready = 1'b1;  // never backpressure RX in Phase 2
    end
    assign axis_stat.tready = 1'b1;

    // --- Taxi 10G/25G MAC + PCS + GTY ---------------------------------------
    taxi_eth_mac_25g_us #(
        .SIM(SIM), .VENDOR(VENDOR), .FAMILY(FAMILY),
        .CNT(PORTS),
        .GT_TYPE("GTY"),
        .COMBINED_MAC_PCS(1'b1),
        .DATA_W(DATA_W),
        .DIC_EN(1'b1),
        .PTP_TS_EN(1'b0),
        .PRBS31_EN(1'b0),
        .TX_SERDES_PIPELINE(1),
        .RX_SERDES_PIPELINE(1),
        .COUNT_125US(125000/6.4),
        .STAT_EN(1'b0)
    ) u_mac (
        .xcvr_ctrl_clk(ctrl_clk),
        .xcvr_ctrl_rst(sfp_rst),
        .s_apb_ctrl(gt_apb_ctrl),

        .xcvr_gtpowergood_out(gtpowergood),
        .xcvr_gtrefclk00_in(sfp_mgt_refclk),
        .xcvr_qpll0pd_in(1'b0),
        .xcvr_qpll0reset_in(1'b0),
        .xcvr_qpll0pcierate_in(3'd0),
        .xcvr_qpll0lock_out(),
        .xcvr_qpll0clk_out(),
        .xcvr_qpll0refclk_out(),
        .xcvr_gtrefclk01_in(sfp_mgt_refclk),
        .xcvr_qpll1pd_in(1'b0),
        .xcvr_qpll1reset_in(1'b0),
        .xcvr_qpll1pcierate_in(3'd0),
        .xcvr_qpll1lock_out(),
        .xcvr_qpll1clk_out(),
        .xcvr_qpll1refclk_out(),

        .xcvr_txp(sfp_tx_p),
        .xcvr_txn(sfp_tx_n),
        .xcvr_rxp(sfp_rx_p),
        .xcvr_rxn(sfp_rx_n),

        .rx_clk(rx_clk),
        .rx_rst_in('{PORTS{1'b0}}),
        .rx_rst_out(rx_rst),
        .tx_clk(tx_clk),
        .tx_rst_in('{PORTS{1'b0}}),
        .tx_rst_out(tx_rst),

        .s_axis_tx(axis_tx),
        .m_axis_tx_cpl(axis_tx_cpl),
        .m_axis_rx(axis_rx),

        // PTP unused
        .ptp_clk(1'b0), .ptp_rst(1'b0), .ptp_sample_clk(1'b0), .ptp_td_sdi(1'b0),
        .tx_ptp_ts_in('{PORTS{'0}}), .tx_ptp_ts_out(), .tx_ptp_ts_step_out(),
        .tx_ptp_locked(),
        .rx_ptp_ts_in('{PORTS{'0}}), .rx_ptp_ts_out(), .rx_ptp_ts_step_out(),
        .rx_ptp_locked(),

        // Flow control unused
        .tx_lfc_req('{PORTS{1'b0}}), .tx_lfc_resend('{PORTS{1'b0}}),
        .rx_lfc_en('{PORTS{1'b0}}), .rx_lfc_req(), .rx_lfc_ack('{PORTS{1'b0}}),
        .tx_pfc_req('{PORTS{'0}}), .tx_pfc_resend('{PORTS{1'b0}}),
        .rx_pfc_en('{PORTS{'0}}), .rx_pfc_req(), .rx_pfc_ack('{PORTS{'0}}),
        .tx_lfc_pause_en('{PORTS{1'b0}}), .tx_pause_req('{PORTS{1'b0}}),
        .tx_pause_ack(),

        // Statistics unused
        .stat_clk(ctrl_clk), .stat_rst(ctrl_rst), .m_axis_stat(axis_stat),

        // Max frame length: raise from the 1518 default to 9600 so the BASE-R
        // PCS accepts jumbo frames (MTU 9000 ~ 9018 B on the wire incl. FCS).
        // Downstream FIFOs (MAC<->dp CDC, data-plane SAF) are sized to match.
        .cfg_tx_max_pkt_len('{PORTS{16'd9600 - 1}}),
        .cfg_rx_max_pkt_len('{PORTS{16'd9600 - 1}}),

        // Status
        .rx_error_count(),
        .rx_block_lock(rx_block_lock),
        .rx_high_ber(),
        .rx_status(rx_status)
    );

endmodule

`default_nettype wire
