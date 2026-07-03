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
    output wire        led_r,               // front-panel R/G health LED (active-low)
    output wire        led_g,
    output wire        sfp_led [2],
    inout  wire [5:0]  gpio,                // J5 header: cross-card time-sync
    inout  wire        sfp_scl [2],         // per-SFP I2C clock (open-drain)
    inout  wire        sfp_sda [2]          // per-SFP I2C data  (open-drain)
);
    import pw_pkg::*;
    localparam int ADDR_W = 16;

    // --- PCIe -> AXI4-Lite (16-bit CSR window) ------------------------------
    wire        axi_aclk, axi_aresetn, pcie_link_up;
    wire [ADDR_W-1:0] aw, ar;  wire [31:0] wd, rd;  wire [3:0] ws;
    wire awv,awr,wv,wr,bv,br,arv,arr,rv,rr;  wire [1:0] bresp,rresp;

    // XDMA AXI-Stream slow-path channels (axi_aclk domain): H2C = host->FPGA
    // (inject), C2H = FPGA->host (punt). Bridge <-> core (pw_dma_slowpath).
    wire [255:0] h2c_td, c2h_td;  wire [31:0] h2c_tk, c2h_tk;
    wire         h2c_tv, h2c_tr, h2c_tl, c2h_tv, c2h_tr, c2h_tl;

    pcie_axi_lite_bridge #(.AXIL_ADDR_W(ADDR_W)) u_pcie (
        .pcie_refclk_p(pcie_refclk_p), .pcie_refclk_n(pcie_refclk_n), .pcie_perst_n(pcie_reset_n),
        .pcie_rx_p(pcie_rx_p), .pcie_rx_n(pcie_rx_n), .pcie_tx_p(pcie_tx_p), .pcie_tx_n(pcie_tx_n),
        .axi_aclk(axi_aclk), .axi_aresetn(axi_aresetn),
        .m_axi_awaddr(aw), .m_axi_awvalid(awv), .m_axi_awready(awr),
        .m_axi_wdata(wd), .m_axi_wstrb(ws), .m_axi_wvalid(wv), .m_axi_wready(wr),
        .m_axi_bresp(bresp), .m_axi_bvalid(bv), .m_axi_bready(br),
        .m_axi_araddr(ar), .m_axi_arvalid(arv), .m_axi_arready(arr),
        .m_axi_rdata(rd), .m_axi_rresp(rresp), .m_axi_rvalid(rv), .m_axi_rready(rr),
        .h2c_tdata(h2c_td), .h2c_tkeep(h2c_tk), .h2c_tvalid(h2c_tv),
        .h2c_tready(h2c_tr), .h2c_tlast(h2c_tl),
        .c2h_tdata(c2h_td), .c2h_tkeep(c2h_tk), .c2h_tvalid(c2h_tv),
        .c2h_tready(c2h_tr), .c2h_tlast(c2h_tl),
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

    // Data-plane reset synchroniser: async-assert / sync-deassert into dp_clk.
    // The async-assert MUST come from the combined sources (PCIe user reset OR
    // MMCM unlocked) so a lock loss asserts reset IMMEDIATELY -- mmcm_lock cannot
    // be qualified synchronously here because dp_clk is generated by that very
    // MMCM and stops/glitches on lock loss (a synchronous path would miss it).
    // Combining two async reset SOURCES inherently needs a gate on the async pin
    // (a benign assert-only merge, the proc_sys_reset pattern); the deassert is
    // synchronised by the 2-FF chain.
    wire dp_arst_src = axi_aresetn & mmcm_lock;
    (* ASYNC_REG = "true" *) logic [1:0] dp_rstn_sync = 2'b00;
    always_ff @(posedge dp_clk or negedge dp_arst_src) begin
        if (!dp_arst_src) dp_rstn_sync <= 2'b00;
        else              dp_rstn_sync <= {dp_rstn_sync[0], 1'b1};
    end
    wire dp_aresetn = dp_rstn_sync[1];
    wire dp_rst     = !dp_aresetn;

    // SFP control reset: assert on PCIe-domain reset OR MMCM unlocked. Async
    // (combinational) for the same reason as dp_arst_src above -- clk_125mhz is
    // MMCM-derived and stops on lock loss, so a synchronous qualifier would miss
    // it. The OR is a benign assert-only reset-source merge.
    wire sfp_ctrl_rst = !rst_n_100 || !mmcm_lock;

    // --- SFP+ 10G MAC -------------------------------------------------------
    wire sfp_tx_clk[2], sfp_tx_rst[2], sfp_rx_clk[2], sfp_rx_rst[2];
    wire sfp_block_lock[2], sfp_rx_status[2], sfp_gtpwr;
    wire [63:0] mac_tx_d[2], mac_rx_d[2];  wire [7:0] mac_tx_k[2], mac_rx_k[2];
    wire mac_tx_v[2], mac_tx_r[2], mac_tx_l[2], mac_tx_u[2];
    wire mac_rx_v[2], mac_rx_l[2], mac_rx_u[2];

    pw_sfp_10g #(.FAMILY("kintexuplus"), .PORTS(2), .DATA_W(64)) u_sfp (
        .ctrl_clk(clk_125mhz), .ctrl_rst(sfp_ctrl_rst),
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
    wire dprx_v[2], dprx_r[2], dprx_l[2];
    wire [64:0] dprx_uwide[2];                 // CDC RX user = {rx_wire_ts[63:0], err}
    wire        dprx_err[2];  wire [63:0] dprx_wts[2];   // split for the data plane
    wire dptx_v[2], dptx_r[2], dptx_l[2], dptx_u[2];

    // --- RX ingress wire-timestamp (MAC RX clock domain) -------------------
    // Sample the dp_clk free-running timestamp in each port's MAC RX clock and
    // latch it at the frame's wire arrival (SOF). It rides the RX async FIFO as
    // extra tuser bits (RX_USER_W widened to 65) so it stays glued to its frame
    // across the CDC; the data plane reads it as the true wire-to-wire RX time
    // (frame-size independent, unlike a dp_clk sample taken AFTER the store-and-
    // forward FIFO). The dp_clk->rx_clk crossing reuses the Gray-coded scheme of
    // the egress pw_ts_insert path (constrained in xdc/phase3_cdc.xdc).
    wire [63:0] ts_rx[2];
    wire [64:0] mac_rx_uwide[2];               // {rx_wire_ts[63:0], mac_rx_err}
    for (genvar prx = 0; prx < 2; prx++) begin : g_rx_wirestamp
        pw_ts_gray_cdc #(.W(64)) u_rxtscdc (
            .src_clk(dp_clk), .src_bin(ts), .dst_clk(sfp_rx_clk[prx]), .dst_bin(ts_rx[prx])
        );
        logic        rx_in_frame = 1'b0;
        logic [63:0] rx_wts_held = '0;
        always_ff @(posedge sfp_rx_clk[prx] or posedge sfp_rx_rst[prx]) begin
            if (sfp_rx_rst[prx]) begin rx_in_frame <= 1'b0; rx_wts_held <= '0; end
            else if (mac_rx_v[prx]) begin
                if (!rx_in_frame) rx_wts_held <= ts_rx[prx];   // latch the SOF wire time
                rx_in_frame <= !mac_rx_l[prx];
            end
        end
        // Present the wire-ts on every beat. The SOF beat carries ts_rx directly
        // (rx_wts_held only updates a cycle later, via NBA), later beats carry the
        // held value -- so whichever beat the data plane reads sees this frame's
        // wire time. err stays at bit 0 (the RX FIFO's bad-frame mask = bit 0).
        assign mac_rx_uwide[prx] = {(rx_in_frame ? rx_wts_held : ts_rx[prx]), mac_rx_u[prx]};
    end
    for (genvar prx = 0; prx < 2; prx++) begin : g_rx_split
        assign dprx_err[prx] = dprx_uwide[prx][0];
        assign dprx_wts[prx] = dprx_uwide[prx][64:1];
    end

    // DEPTH is the per-direction MAC<->dp_clk frame-FIFO byte capacity (taxi
    // FRAME_FIFO + DROP_OVERSIZE). It must hold a whole frame, so 16384 covers a
    // jumbo frame (MTU 9000 ~ 9018 B on the wire) + margin. (Was 2048 = ~1518 B;
    // widened for jumbo alongside the MAC max_pkt_len and the data-plane SAF.)
    // --- soft-reset flush of the MAC-TX CDC + egress timestamper ------------
    // The CSR DP_RESET pulse (u_dp.dp_soft_rst_o) only resets the dp_clk-domain
    // data plane (gen/SAF/arbiters). A frame wedged in the MAC-TX FIFO or in
    // ts_insert (per-port tx_clk domain) survives it, leaving TX dead until a
    // full bitstream reload. The CDC flushes its own TX FIFO from this pulse
    // (stretch + per-tx_clk sync are internal); it returns the synchronized
    // per-port flush level (tx_soft_flush_w) so we also reset ts_insert in the
    // same domain -- recovering a wedged egress without JTAG / ICAP reboot.
    wire dp_soft_rst_pulse;
    wire tx_soft_flush_w [2];

    pw_mac_axis_cdc #(.PORTS(2), .DATA_W(64), .DEPTH(16384), .RX_USER_W(65)) u_cdc (
        .dp_clk(dp_clk), .dp_rst(dp_rst),
        .rx_clk(sfp_rx_clk), .rx_rst(sfp_rx_rst), .tx_clk(sfp_tx_clk), .tx_rst(sfp_tx_rst),
        .dp_soft_flush(dp_soft_rst_pulse), .tx_soft_flush_o(tx_soft_flush_w),
        .mac_rx_tdata(mac_rx_d), .mac_rx_tkeep(mac_rx_k), .mac_rx_tvalid(mac_rx_v),
        .mac_rx_tlast(mac_rx_l), .mac_rx_tuser(mac_rx_uwide),
        .mac_tx_tdata(cdc_tx_d), .mac_tx_tkeep(cdc_tx_k), .mac_tx_tvalid(cdc_tx_v),
        .mac_tx_tready(cdc_tx_r), .mac_tx_tlast(cdc_tx_l), .mac_tx_tuser(cdc_tx_u),
        .dp_rx_tdata(dprx_d), .dp_rx_tkeep(dprx_k), .dp_rx_tvalid(dprx_v),
        .dp_rx_tready(dprx_r), .dp_rx_tlast(dprx_l), .dp_rx_tuser(dprx_uwide),
        .dp_tx_tdata(dptx_d), .dp_tx_tkeep(dptx_k), .dp_tx_tvalid(dptx_v),
        .dp_tx_tready(dptx_r), .dp_tx_tlast(dptx_l), .dp_tx_tuser(dptx_u)
    );

    // --- egress hardware timestamping (MAC TX clock domain) ----------------
    // Overwrite each test packet's tx_timestamp with the true departure time
    // (here, at the MAC), so measured latency reflects the DUT, not this
    // tester's own TX-FIFO queuing. The dp_clk timestamp is Gray-CDC'd into
    // each port's MAC TX clock. Sits between the CDC's MAC-TX output and the
    // MAC's TX AXIS.
    wire [63:0] cdc_tx_d[2];  wire [7:0] cdc_tx_k[2];
    wire        cdc_tx_v[2], cdc_tx_r[2], cdc_tx_l[2], cdc_tx_u[2];
    wire [63:0] ts_tx[2];
    for (genvar p = 0; p < 2; p++) begin : g_ts_egress
        // ts_insert shares the CDC's single registered tx-domain reset
        // (tx_soft_flush_w = tx_rst | flush). Register the active-low form so a
        // clean FF output (not a LUT) drives ts_insert's async reset -- the
        // invert sits on the D path, where glitches are sampled away. Asserts
        // immediately on sfp_tx_rst; re-zeros ts_insert alongside the TX FIFO.
        logic tsins_rstn = 1'b0;
        always_ff @(posedge sfp_tx_clk[p] or posedge sfp_tx_rst[p]) begin
            if (sfp_tx_rst[p]) tsins_rstn <= 1'b0;
            else               tsins_rstn <= ~tx_soft_flush_w[p];
        end
        pw_ts_gray_cdc #(.W(64)) u_tscdc (
            .src_clk(dp_clk), .src_bin(ts), .dst_clk(sfp_tx_clk[p]), .dst_bin(ts_tx[p])
        );
        pw_ts_insert u_tsins (
            .clk(sfp_tx_clk[p]), .rst_n(tsins_rstn), .ts_now(ts_tx[p]),
            .s_tdata(cdc_tx_d[p]), .s_tkeep(cdc_tx_k[p]), .s_tvalid(cdc_tx_v[p]),
            .s_tready(cdc_tx_r[p]), .s_tlast(cdc_tx_l[p]), .s_tuser(cdc_tx_u[p]),
            .m_tdata(mac_tx_d[p]), .m_tkeep(mac_tx_k[p]), .m_tvalid(mac_tx_v[p]),
            .m_tready(mac_tx_r[p]), .m_tlast(mac_tx_l[p]), .m_tuser(mac_tx_u[p])
        );
    end

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

    // Scale: 32 flows / 16 classifier rules / 16 latency bins. TEST_RX flows no
    // longer need a classifier rule -- they are classified by the BRAM flow-id
    // map (pw_flowid_map: test_flow_id -> checker slot, scales to MAP_DEPTH=256),
    // so the small 16-entry classifier (routable; a wider one is congestion-
    // bound, WNS -1.58 at 32) now only carries non-test rules (PUNT/FORWARD).
    // The flow count is bounded by the checker/generator (NUM_FLOWS), not the
    // classifier -- 32 measured flows over the SFP+ loopback at loss=0.
    pwfpga_top_phase3 #(
        .ADDR_W(ADDR_W), .CAPABILITIES(PW_PHASE3_CAPABILITIES),
        .NUM_PORTS(2), .NUM_FLOWS(32), .NUM_CLASSIFIER(16), .NUM_HIST_BINS(16),
        .NUM_CMP(12), .NUM_UDF(2), .NUM_RULE(32), .SLICE_WIN(48), .HASH_DEPTH(128),
        .SAF_DEPTH_BEATS(2048)   // 16 KB per-ingress forward/punt SAF for jumbo (MTU 9000)
    ) u_dp (
        .clk(dp_clk), .rst_n(dp_aresetn),
        .s_axi_awaddr(daw), .s_axi_awvalid(dawv), .s_axi_awready(dawr),
        .s_axi_wdata(dwd), .s_axi_wstrb(dws), .s_axi_wvalid(dwv), .s_axi_wready(dwr),
        .s_axi_bresp(dbresp), .s_axi_bvalid(dbv), .s_axi_bready(dbr),
        .s_axi_araddr(dar), .s_axi_arvalid(darv), .s_axi_arready(darr),
        .s_axi_rdata(drd), .s_axi_rresp(drresp), .s_axi_rvalid(drv), .s_axi_rready(drr),
        .s_axis_rx_tdata(dprx_d), .s_axis_rx_tkeep(dprx_k), .s_axis_rx_tvalid(dprx_v),
        .s_axis_rx_tready(dprx_r), .s_axis_rx_tlast(dprx_l), .s_axis_rx_tuser(dprx_err),
        .s_axis_rx_wire_ts(dprx_wts),
        // link-health status levels (async; synchronized in the data plane)
        .link_up_i(sfp_rx_status), .block_lock_i(sfp_block_lock),
        .m_axis_tx_tdata(dptx_d), .m_axis_tx_tkeep(dptx_k), .m_axis_tx_tvalid(dptx_v),
        .m_axis_tx_tready(dptx_r), .m_axis_tx_tlast(dptx_l), .m_axis_tx_tuser(dptx_u),
        .timestamp_i(ts),
        .spi_sck_o(spi_sck), .spi_cs_n_o(spi_cs_n), .spi_mosi_o(spi_mosi), .spi_miso_i(spi_miso),
        .icap_csib_o(icap_csib), .icap_rdwrb_o(icap_rdwrb), .icap_i_o(icap_i),
        .dp_soft_rst_o(dp_soft_rst_pulse),
        .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_t(gpio_t),
        .sfp_i2c_i(sfp_i2c_i), .sfp_i2c_o(sfp_i2c_o), .sfp_i2c_t(sfp_i2c_t),
        .status_err_o(status_err_dp), .status_activity_o(status_act_dp),
        .sysmon_temp_i(sysmon_temp_w), .sysmon_vccint_i(sysmon_vccint_w),
        .sysmon_vccaux_i(sysmon_vccaux_w),
        // XDMA AXI-Stream slow path (axi_aclk domain; axi_rst active-high).
        .axi_clk(axi_aclk), .axi_rst(~axi_aresetn),
        .s_h2c_tdata(h2c_td), .s_h2c_tkeep(h2c_tk), .s_h2c_tvalid(h2c_tv),
        .s_h2c_tready(h2c_tr), .s_h2c_tlast(h2c_tl),
        .m_c2h_tdata(c2h_td), .m_c2h_tkeep(c2h_tk), .m_c2h_tvalid(c2h_tv),
        .m_c2h_tready(c2h_tr), .m_c2h_tlast(c2h_tl)
    );

    // ---- On-chip SYSMON (die temperature + VCCINT/VCCAUX) --------------------
    // pw_sysmon is a pure-logic DRP reader (same dp_clk domain as the CSR, so no
    // CDC on the codes); the SYSMONE4 primitive lives here in the board top, per
    // the STARTUPE3 / ICAPE3 pattern. SYSMONE4 powers up in default mode and
    // continuously samples the on-chip sensors, so we only issue DRP reads.
    wire [15:0] sysmon_temp_w, sysmon_vccint_w, sysmon_vccaux_w;
    wire [7:0]  sm_daddr;
    wire        sm_den, sm_dwe, sm_drdy;
    wire [15:0] sm_di, sm_do;

    pw_sysmon u_sysmon (
        .clk(dp_clk), .rst_n(dp_aresetn),
        .drp_daddr(sm_daddr), .drp_den(sm_den), .drp_dwe(sm_dwe),
        .drp_di(sm_di), .drp_do(sm_do), .drp_drdy(sm_drdy),
        .temp_o(sysmon_temp_w), .vccint_o(sysmon_vccint_w), .vccaux_o(sysmon_vccaux_w)
    );

    SYSMONE4 #(
        .SIM_MONITOR_FILE("design.txt")
    ) u_sysmone4 (
        .DCLK(dp_clk),
        .DADDR(sm_daddr), .DEN(sm_den), .DWE(sm_dwe), .DI(sm_di),
        .DO(sm_do), .DRDY(sm_drdy),
        .RESET(~dp_aresetn),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .VP(1'b0), .VN(1'b0),
        .VAUXP(16'b0), .VAUXN(16'b0),
        .I2C_SCLK(1'b0), .I2C_SDA(1'b0),
        // unused status outputs
        .ALM(), .OT(), .BUSY(), .CHANNEL(), .EOC(), .EOS(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(), .MUXADDR(),
        .I2C_SCLK_TS(), .I2C_SDA_TS(), .SMBALERT_TS()
    );

    // --- J5 GPIO bidirectional pads (cross-card time-sync) ----------------
    // pw_gpio_sync drives only its configured sync-out pin (gpio_t low) and
    // leaves the rest hi-Z (gpio_t high). The inputs are asynchronous and
    // synchronised inside pw_gpio_sync; constrained as false_path in timing.xdc.
    wire [5:0] gpio_i, gpio_o, gpio_t;
    genvar gg;
    generate
        for (gg = 0; gg < 6; gg++) begin : g_gpio_iobuf
            IOBUF u_iobuf (.I(gpio_o[gg]), .O(gpio_i[gg]), .T(gpio_t[gg]), .IO(gpio[gg]));
        end
    endgenerate

    // --- Per-SFP I2C management pads (open-drain, SW bit-bang) -------------
    // One independent 2-wire bus per SFP cage (SCL/SDA). The core drives only
    // low (sfp_i2c_o=0) and releases via sfp_i2c_t (external board pull-ups give
    // the idle-high). Line order: [0]SFP0 SCL [1]SFP0 SDA [2]SFP1 SCL [3]SFP1 SDA.
    // Async inputs synchronised in the core; false_path in timing.xdc.
    wire [3:0] sfp_i2c_i, sfp_i2c_o, sfp_i2c_t;
    IOBUF u_sfp0_scl (.I(sfp_i2c_o[0]), .O(sfp_i2c_i[0]), .T(sfp_i2c_t[0]), .IO(sfp_scl[0]));
    IOBUF u_sfp0_sda (.I(sfp_i2c_o[1]), .O(sfp_i2c_i[1]), .T(sfp_i2c_t[1]), .IO(sfp_sda[0]));
    IOBUF u_sfp1_scl (.I(sfp_i2c_o[2]), .O(sfp_i2c_i[2]), .T(sfp_i2c_t[2]), .IO(sfp_scl[1]));
    IOBUF u_sfp1_sda (.I(sfp_i2c_o[3]), .O(sfp_i2c_i[3]), .T(sfp_i2c_t[3]), .IO(sfp_sda[1]));

    // --- in-band reconfiguration via ICAPE3 -------------------------------
    // pw_icap_reboot streams IPROG here on the host's REBOOT magic write;
    // the FPGA reloads its bitstream from flash (PCIe drops, host rescans).
    wire        icap_csib, icap_rdwrb;
    wire [31:0] icap_i;
    ICAPE3 #(
        .ICAP_AUTO_SWITCH("DISABLE"),
        .SIM_CFG_FILE_NAME("NONE")
    ) u_icape3 (
        .AVAIL   (),
        .O       (),
        .PRDONE  (),
        .PRERROR (),
        .CLK     (dp_clk),
        .CSIB    (icap_csib),
        .I       (icap_i),
        .RDWRB   (icap_rdwrb)
    );

    // --- in-system SPI flash access via STARTUPE3 -------------------------
    // The config flash (MT25QU256) hangs off the dedicated config pins;
    // STARTUPE3 grants user access to them after configuration, so the
    // CSR SPI master can erase/program/read the boot image live (PCIe and
    // the data plane stay up). x1 SPI: DQ0=MOSI (drive), DQ1=MISO (input),
    // DQ2=WP#/DQ3=HOLD# driven high so neither is asserted during access.
    wire        spi_sck, spi_cs_n, spi_mosi, spi_miso;
    wire [3:0]  startup_di;
    assign spi_miso = startup_di[1];
    STARTUPE3 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) u_startup (
        .CFGCLK    (),
        .CFGMCLK   (),
        .DI        (startup_di),                       // [1]=MISO
        .DO        ({1'b1, 1'b1, 1'b0, spi_mosi}),     // DQ3/2 high, DQ0=MOSI
        .DTS       (4'b0010),                          // DQ1 input, others drive
        .EOS       (),
        .PREQ      (),
        .FCSBO     (spi_cs_n),                         // chip select
        .FCSBTS    (1'b0),
        .GSR       (1'b0),
        .GTS       (1'b0),
        .KEYCLEARB (1'b1),
        .PACK      (1'b0),
        .USRCCLKO  (spi_sck),                          // SPI clock
        .USRCCLKTS (1'b0),
        .USRDONEO  (1'b1),
        .USRDONETS (1'b1)
    );

    // dptx_u carries the data plane's "generator test frame" marker (driven by
    // the egress arbiter's sel_gen), CDC'd to each MAC TX clock and consumed by
    // pw_ts_insert below to gate egress timestamping + the IPv6 UDP csum fixup.
    // It is NOT the MAC's tx-error tuser -- pw_ts_insert drives m_tuser=0.

    // --- LEDs ---------------------------------------------------------------
    pw_heartbeat #(.CLK_HZ(100_000_000), .RATE_HZ(1)) u_hb (.clk(clk_100mhz), .rst_n(rst_n_100), .led_o(led_hb));
    assign sfp_led[0] = !sfp_rx_status[0];
    assign sfp_led[1] = !sfp_rx_status[1];
    assign led = {1'b1, 1'b1, ~pcie_link_up, 1'b1};

    // --- Front-panel R/G health LED (active-low: 0 = lit) -------------------
    // Data-plane status (dp_clk domain) synchronised into the 100 MHz LED
    // domain, plus pcie_link_up as the "configured/up" gate. Scheme:
    //   RED solid     : sticky error since the last stats.clear (loss/FCS/drop)
    //   GREEN blink   : up, clean, traffic flowing
    //   GREEN solid   : up, clean, idle
    //   OFF           : not up (PCIe down / not configured); red overrides green
    wire status_err_dp, status_act_dp;    // from the core (dp_clk)
    // 2-FF synchronisers (first stage = the async capture, false-pathed in
    // timing.xdc like lu_sync0/bl_sync0). Separate *_sync0/*_sync1 names so the
    // false_path can target the capture FF unambiguously (no bracket-glob).
    (* ASYNC_REG = "true" *) logic err_sync0, err_sync1;
    (* ASYNC_REG = "true" *) logic act_sync0, act_sync1;
    (* ASYNC_REG = "true" *) logic pcie_sync0, pcie_sync1;
    always_ff @(posedge clk_100mhz or negedge rst_n_100) begin
        if (!rst_n_100) begin
            err_sync0 <= 1'b0; err_sync1 <= 1'b0;
            act_sync0 <= 1'b0; act_sync1 <= 1'b0;
            pcie_sync0 <= 1'b0; pcie_sync1 <= 1'b0;
        end else begin
            err_sync0  <= status_err_dp; err_sync1  <= err_sync0;
            act_sync0  <= status_act_dp; act_sync1  <= act_sync0;
            pcie_sync0 <= pcie_link_up;  pcie_sync1 <= pcie_sync0;
        end
    end
    // ~3 Hz blink from a free-running counter's top bit.
    logic [24:0] blink_cnt;
    always_ff @(posedge clk_100mhz or negedge rst_n_100) begin
        if (!rst_n_100) blink_cnt <= '0; else blink_cnt <= blink_cnt + 1'b1;
    end
    wire blink = blink_cnt[24];
    wire up    = pcie_sync1;
    wire err   = err_sync1;
    wire act   = act_sync1;
    wire red_on = up &&  err;
    wire grn_on = up && !err && (act ? blink : 1'b1);
    assign led_r = ~red_on;   // active-low
    assign led_g = ~grn_on;

endmodule

`default_nettype wire
