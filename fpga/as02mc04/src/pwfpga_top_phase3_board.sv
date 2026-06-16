// AS02MC04 Phase 3 board top: full data plane on real 10G SFP+ ports.
//
// PCIe Gen3 endpoint + BAR0 -> pw_csr_full (identity + classifier /
// flow / stats / histogram windows) driving pw_data_plane_axis (64-bit
// AXIS streaming), with the
// two SFP+ 10GBASE-R ports (Taxi MAC/PCS/GTY) as the line interface.
// The data plane runs on dp_clk (156.25 MHz = 10G line rate, from the
// board MMCM); the host BAR crosses in from the 250 MHz PCIe user clock
// via an AXI4-Lite clock converter. The MAC runs in its per-port GT
// clocks, bridged to dp_clk by pw_mac_axis_cdc.
//
// This is the network-tester data path: the host programs a flow + a
// classifier rule over PCIe, the FPGA generates IPv4/UDP test traffic
// out one SFP+ port, the DAC carries it to the other, and the RX
// checker reports per-flow loss / latency / jitter back through the CSR.

`default_nettype none

module pwfpga_top_phase3_board (
    input  wire        clk_100mhz_p,
    input  wire        clk_100mhz_n,
    input  wire        pcie_refclk_p,
    input  wire        pcie_refclk_n,
    input  wire        pcie_reset_n,
    input  wire [7:0]  pcie_rx_p,
    input  wire [7:0]  pcie_rx_n,
    output wire [7:0]  pcie_tx_p,
    output wire [7:0]  pcie_tx_n,
    input  wire        sfp_mgt_refclk_p,
    input  wire        sfp_mgt_refclk_n,
    input  wire        sfp_rx_p [2],
    input  wire        sfp_rx_n [2],
    output wire        sfp_tx_p [2],
    output wire        sfp_tx_n [2],
    output wire        led_hb,
    output wire [3:0]  led,
    output wire        sfp_led [2]
);
    import pw_pkg::*;
    localparam int ADDR_W = 16;

    // --- PCIe -> AXI4-Lite (16-bit CSR window) ------------------------------
    wire        axi_aclk, axi_aresetn, pcie_link_up;
    wire [ADDR_W-1:0] aw, ar;  wire [31:0] wd, rd;  wire [3:0] ws;
    wire awv,awr,wv,wr,bv,br,arv,arr,rv,rr;  wire [1:0] bresp,rresp;

    pcie_axi_lite_bridge #(.AXIL_ADDR_W(ADDR_W)) u_pcie (
        .pcie_refclk_p(pcie_refclk_p), .pcie_refclk_n(pcie_refclk_n), .pcie_perst_n(pcie_reset_n),
        .pcie_rx_p(pcie_rx_p), .pcie_rx_n(pcie_rx_n), .pcie_tx_p(pcie_tx_p), .pcie_tx_n(pcie_tx_n),
        .axi_aclk(axi_aclk), .axi_aresetn(axi_aresetn),
        .m_axi_awaddr(aw), .m_axi_awvalid(awv), .m_axi_awready(awr),
        .m_axi_wdata(wd), .m_axi_wstrb(ws), .m_axi_wvalid(wv), .m_axi_wready(wr),
        .m_axi_bresp(bresp), .m_axi_bvalid(bv), .m_axi_bready(br),
        .m_axi_araddr(ar), .m_axi_arvalid(arv), .m_axi_arready(arr),
        .m_axi_rdata(rd), .m_axi_rresp(rresp), .m_axi_rvalid(rv), .m_axi_rready(rr),
        .link_up(pcie_link_up)
    );

    // --- clocks / reset -----------------------------------------------------
    wire clk_100mhz, rst_n_100;
    clock_reset u_clkrst (
        .sys_clk_p(clk_100mhz_p), .sys_clk_n(clk_100mhz_n), .sys_rst_n(pcie_reset_n),
        .clk_100mhz(clk_100mhz), .rst_n_100(rst_n_100),
        .pcie_user_clk(axi_aclk), .pcie_user_resetn(axi_aresetn), .clk_axi(), .rst_n_axi()
    );

    // VCO = 100 MHz * 12.5 = 1250 MHz. CLKOUT0 /10 = 125 MHz (MAC ctrl);
    // CLKOUT1 /8 = 156.25 MHz = the data-plane clock (10G line rate). The
    // data plane does not meet the 250 MHz PCIe user clock, so it runs on
    // dp_clk and the BAR crosses in via an AXI4-Lite clock converter.
    wire clk_125mhz, mmcm_fb, mmcm_lock, clk125_u, fb_u, dp_clk_u, dp_clk;
    MMCME4_BASE #(.CLKIN1_PERIOD(10.000), .CLKFBOUT_MULT_F(12.500),
                  .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(10.000),
                  .CLKOUT1_DIVIDE(8)) u_mmcm (
        .CLKIN1(clk_100mhz), .CLKFBIN(mmcm_fb), .CLKFBOUT(fb_u), .CLKOUT0(clk125_u),
        .CLKOUT0B(),.CLKOUT1(dp_clk_u),.CLKOUT1B(),.CLKOUT2(),.CLKOUT2B(),.CLKOUT3(),.CLKOUT3B(),
        .CLKOUT4(),.CLKOUT5(),.CLKOUT6(), .LOCKED(mmcm_lock), .PWRDWN(1'b0), .RST(!rst_n_100));
    BUFG b0(.I(clk125_u),.O(clk_125mhz));
    BUFG b1(.I(fb_u),.O(mmcm_fb));
    BUFG b2(.I(dp_clk_u),.O(dp_clk));

    // Data-plane reset: async-assert (axi reset or MMCM unlocked),
    // synchronously deassert into dp_clk.
    wire dp_arst_src = axi_aresetn & mmcm_lock;
    (* ASYNC_REG = "true" *) logic [1:0] dp_rstn_sync = 2'b00;
    always_ff @(posedge dp_clk or negedge dp_arst_src) begin
        if (!dp_arst_src) dp_rstn_sync <= 2'b00;
        else              dp_rstn_sync <= {dp_rstn_sync[0], 1'b1};
    end
    wire dp_aresetn = dp_rstn_sync[1];
    wire dp_rst     = !dp_aresetn;

    // --- SFP+ 10G MAC -------------------------------------------------------
    wire sfp_tx_clk[2], sfp_tx_rst[2], sfp_rx_clk[2], sfp_rx_rst[2];
    wire sfp_block_lock[2], sfp_rx_status[2], sfp_gtpwr;
    wire [63:0] mac_tx_d[2], mac_rx_d[2];  wire [7:0] mac_tx_k[2], mac_rx_k[2];
    wire mac_tx_v[2], mac_tx_r[2], mac_tx_l[2], mac_tx_u[2];
    wire mac_rx_v[2], mac_rx_l[2], mac_rx_u[2];

    pw_sfp_10g #(.FAMILY("kintexuplus"), .PORTS(2), .DATA_W(64)) u_sfp (
        .ctrl_clk(clk_125mhz), .ctrl_rst(!rst_n_100 || !mmcm_lock),
        .sfp_mgt_refclk_p(sfp_mgt_refclk_p), .sfp_mgt_refclk_n(sfp_mgt_refclk_n),
        .sfp_tx_p(sfp_tx_p), .sfp_tx_n(sfp_tx_n), .sfp_rx_p(sfp_rx_p), .sfp_rx_n(sfp_rx_n),
        .tx_clk(sfp_tx_clk), .tx_rst(sfp_tx_rst), .rx_clk(sfp_rx_clk), .rx_rst(sfp_rx_rst),
        .tx_tdata(mac_tx_d), .tx_tkeep(mac_tx_k), .tx_tvalid(mac_tx_v),
        .tx_tready(mac_tx_r), .tx_tlast(mac_tx_l), .tx_tuser(mac_tx_u),
        .rx_tdata(mac_rx_d), .rx_tkeep(mac_rx_k), .rx_tvalid(mac_rx_v),
        .rx_tlast(mac_rx_l), .rx_tuser(mac_rx_u),
        .rx_block_lock(sfp_block_lock), .rx_status(sfp_rx_status), .gtpowergood(sfp_gtpwr)
    );

    // --- AXIS CDC: MAC per-port clocks <-> data-plane clock (axi_aclk) ------
    wire [63:0] dprx_d[2], dptx_d[2];  wire [7:0] dprx_k[2], dptx_k[2];
    wire dprx_v[2], dprx_r[2], dprx_l[2], dprx_u[2];
    wire dptx_v[2], dptx_r[2], dptx_l[2], dptx_u[2];

    pw_mac_axis_cdc #(.PORTS(2), .DATA_W(64), .DEPTH(1024)) u_cdc (
        .dp_clk(dp_clk), .dp_rst(dp_rst),
        .rx_clk(sfp_rx_clk), .rx_rst(sfp_rx_rst), .tx_clk(sfp_tx_clk), .tx_rst(sfp_tx_rst),
        .mac_rx_tdata(mac_rx_d), .mac_rx_tkeep(mac_rx_k), .mac_rx_tvalid(mac_rx_v),
        .mac_rx_tlast(mac_rx_l), .mac_rx_tuser(mac_rx_u),
        .mac_tx_tdata(mac_tx_d), .mac_tx_tkeep(mac_tx_k), .mac_tx_tvalid(mac_tx_v),
        .mac_tx_tready(mac_tx_r), .mac_tx_tlast(mac_tx_l), .mac_tx_tuser(mac_tx_u),
        .dp_rx_tdata(dprx_d), .dp_rx_tkeep(dprx_k), .dp_rx_tvalid(dprx_v),
        .dp_rx_tready(dprx_r), .dp_rx_tlast(dprx_l), .dp_rx_tuser(dprx_u),
        .dp_tx_tdata(dptx_d), .dp_tx_tkeep(dptx_k), .dp_tx_tvalid(dptx_v),
        .dp_tx_tready(dptx_r), .dp_tx_tlast(dptx_l), .dp_tx_tuser(dptx_u)
    );

    // --- timestamp + data plane core ----------------------------------------
    // Timestamp lives in dp_clk: the flow generator stamps TX frames and the
    // RX checker measures latency against the same epoch, both on dp_clk.
    wire [63:0] ts;
    pw_timestamp u_ts (.clk(dp_clk), .rst_n(dp_aresetn), .ts_o(ts));

    // --- AXI4-Lite clock converter: BAR (axi_aclk 250) -> dp_clk (156.25) ---
    wire [ADDR_W-1:0] daw, dar;  wire [31:0] dwd, drd;  wire [3:0] dws;
    wire dawv,dawr,dwv,dwr,dbv,dbr,darv,darr,drv,drr;  wire [1:0] dbresp,drresp;

    axi_clk_conv u_axil_cc (
        .s_axi_aclk(axi_aclk), .s_axi_aresetn(axi_aresetn),
        .s_axi_awaddr(aw), .s_axi_awprot(3'b000), .s_axi_awvalid(awv), .s_axi_awready(awr),
        .s_axi_wdata(wd), .s_axi_wstrb(ws), .s_axi_wvalid(wv), .s_axi_wready(wr),
        .s_axi_bresp(bresp), .s_axi_bvalid(bv), .s_axi_bready(br),
        .s_axi_araddr(ar), .s_axi_arprot(3'b000), .s_axi_arvalid(arv), .s_axi_arready(arr),
        .s_axi_rdata(rd), .s_axi_rresp(rresp), .s_axi_rvalid(rv), .s_axi_rready(rr),
        .m_axi_aclk(dp_clk), .m_axi_aresetn(dp_aresetn),
        .m_axi_awaddr(daw), .m_axi_awprot(), .m_axi_awvalid(dawv), .m_axi_awready(dawr),
        .m_axi_wdata(dwd), .m_axi_wstrb(dws), .m_axi_wvalid(dwv), .m_axi_wready(dwr),
        .m_axi_bresp(dbresp), .m_axi_bvalid(dbv), .m_axi_bready(dbr),
        .m_axi_araddr(dar), .m_axi_arprot(), .m_axi_arvalid(darv), .m_axi_arready(darr),
        .m_axi_rdata(drd), .m_axi_rresp(drresp), .m_axi_rvalid(drv), .m_axi_rready(drr)
    );

    wire [63:0] punt_d;  wire [7:0] punt_k;  wire punt_v, punt_l;

    // Large scale: 32 flows / 16 classifier rules / 16 latency bins.
    // Enabled by the BRAM-backed latency histogram (freed the FF wall)
    // plus the wide CSR address map (16 KB classifier/flow/stats windows,
    // 8 KB histogram, 128 B histogram stride). 64/64/16 overflows the
    // xcku3p (LUTs 135%); 32/32/16 fits but is congestion-limited (WNS
    // -1.58, 78% LUT, the 32-entry classifier key match fanout dominates
    // the route delay). Halving the classifier to 16 rules relieves that
    // congestion while keeping the 32-slot generator / checker / BRAM
    // histogram (16 rules => up to 16 distinctly-classified flows).
    pwfpga_top_phase3 #(
        .ADDR_W(ADDR_W), .CAPABILITIES(PW_PHASE1_CAPABILITIES),
        .NUM_PORTS(2), .NUM_FLOWS(32), .NUM_CLASSIFIER(16), .NUM_HIST_BINS(16)
    ) u_dp (
        .clk(dp_clk), .rst_n(dp_aresetn),
        .s_axi_awaddr(daw), .s_axi_awvalid(dawv), .s_axi_awready(dawr),
        .s_axi_wdata(dwd), .s_axi_wstrb(dws), .s_axi_wvalid(dwv), .s_axi_wready(dwr),
        .s_axi_bresp(dbresp), .s_axi_bvalid(dbv), .s_axi_bready(dbr),
        .s_axi_araddr(dar), .s_axi_arvalid(darv), .s_axi_arready(darr),
        .s_axi_rdata(drd), .s_axi_rresp(drresp), .s_axi_rvalid(drv), .s_axi_rready(drr),
        .s_axis_rx_tdata(dprx_d), .s_axis_rx_tkeep(dprx_k), .s_axis_rx_tvalid(dprx_v),
        .s_axis_rx_tready(dprx_r), .s_axis_rx_tlast(dprx_l),
        .m_axis_tx_tdata(dptx_d), .m_axis_tx_tkeep(dptx_k), .m_axis_tx_tvalid(dptx_v),
        .m_axis_tx_tready(dptx_r), .m_axis_tx_tlast(dptx_l),
        .m_axis_punt_tdata(punt_d), .m_axis_punt_tkeep(punt_k), .m_axis_punt_tvalid(punt_v),
        .m_axis_punt_tready(1'b1), .m_axis_punt_tlast(punt_l),
        .timestamp_i(ts)
    );

    // data-plane TX has no error/tuser input on this core; tie off CDC's.
    for (genvar p = 0; p < 2; p++) begin : g_txu
        assign dptx_u[p] = 1'b0;
    end

    // --- LEDs ---------------------------------------------------------------
    pw_heartbeat #(.CLK_HZ(100_000_000), .RATE_HZ(1)) u_hb (.clk(clk_100mhz), .rst_n(rst_n_100), .led_o(led_hb));
    assign sfp_led[0] = !sfp_rx_status[0];
    assign sfp_led[1] = !sfp_rx_status[1];
    assign led = {1'b1, 1'b1, ~pcie_link_up, 1'b1};

endmodule

`default_nettype wire
