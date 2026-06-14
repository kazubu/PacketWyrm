// AS02MC04 Phase 1 top-level.
//
// Goals:
//   - PCIe Gen3 endpoint enumerates on the host (vendor/device ID
//     defined in ip/pcie_gen3.tcl).
//   - BAR0 exposes pw_csr_min (device_id, version, build_id,
//     git_hash, capabilities, num_ports, timestamp pair, ...).
//   - led_hb blinks at 1 Hz off the 100 MHz LVDS housekeeping clock.
//   - led[1] lit when PCIe link is up.
//   - Timestamp counter free-running in the PCIe user-clock domain.
//
// Pin assignments live in xdc/pinout.xdc; port names here match
// what that file binds.

`default_nettype none

module pwfpga_top_phase1 (
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

    // Status LEDs
    output wire        led_hb,           // B9 - 1 Hz heartbeat
    output wire [3:0]  led               // B11 / C11 / A10 / B10
);

    import pw_pkg::*;

    // --- PCIe + AXI-Lite -----------------------------------------------------

    wire        axi_aclk;
    wire        axi_aresetn;
    wire        pcie_link_up;

    wire [11:0] m_axi_awaddr;
    wire        m_axi_awvalid;
    wire        m_axi_awready;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wvalid;
    wire        m_axi_wready;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_bvalid;
    wire        m_axi_bready;
    wire [11:0] m_axi_araddr;
    wire        m_axi_arvalid;
    wire        m_axi_arready;
    wire [31:0] m_axi_rdata;
    wire [1:0]  m_axi_rresp;
    wire        m_axi_rvalid;
    wire        m_axi_rready;

    pcie_axi_lite_bridge #(.AXIL_ADDR_W(12)) u_pcie (
        .pcie_refclk_p (pcie_refclk_p),
        .pcie_refclk_n (pcie_refclk_n),
        .pcie_perst_n  (pcie_reset_n),
        .pcie_rx_p     (pcie_rx_p),
        .pcie_rx_n     (pcie_rx_n),
        .pcie_tx_p     (pcie_tx_p),
        .pcie_tx_n     (pcie_tx_n),

        .axi_aclk      (axi_aclk),
        .axi_aresetn   (axi_aresetn),

        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),

        .link_up       (pcie_link_up)
    );

    // --- Housekeeping clock + reset (100 MHz LVDS domain) --------------------
    wire clk_100mhz;
    wire rst_n_100;

    clock_reset u_clkrst (
        .sys_clk_p        (clk_100mhz_p),
        .sys_clk_n        (clk_100mhz_n),
        .sys_rst_n        (pcie_reset_n),
        .clk_100mhz       (clk_100mhz),
        .rst_n_100        (rst_n_100),
        .pcie_user_clk    (axi_aclk),
        .pcie_user_resetn (axi_aresetn),
        .clk_axi          (),
        .rst_n_axi        ()
    );

    // --- Timestamp counter ---------------------------------------------------
    wire [63:0] timestamp;
    pw_timestamp u_ts (
        .clk    (axi_aclk),
        .rst_n  (axi_aresetn),
        .ts_o   (timestamp)
    );

    // --- CSR fabric ----------------------------------------------------------
    pw_csr_min #(
        .CAPABILITIES    (PW_PHASE1_CAPABILITIES),
        .NUM_PORTS       (PW_NUM_LOCAL_PORTS),
        .NUM_FLOWS       (0),
        .NUM_LOGICAL_IFS (0),
        .NUM_CLASSIFIER  (0),
        .NUM_HIST_BINS   (0)
    ) u_csr (
        .s_axi_aclk         (axi_aclk),
        .s_axi_aresetn      (axi_aresetn),
        .s_axi_awaddr       (m_axi_awaddr),
        .s_axi_awvalid      (m_axi_awvalid),
        .s_axi_awready      (m_axi_awready),
        .s_axi_wdata        (m_axi_wdata),
        .s_axi_wstrb        (m_axi_wstrb),
        .s_axi_wvalid       (m_axi_wvalid),
        .s_axi_wready       (m_axi_wready),
        .s_axi_bresp        (m_axi_bresp),
        .s_axi_bvalid       (m_axi_bvalid),
        .s_axi_bready       (m_axi_bready),
        .s_axi_araddr       (m_axi_araddr),
        .s_axi_arvalid      (m_axi_arvalid),
        .s_axi_arready      (m_axi_arready),
        .s_axi_rdata        (m_axi_rdata),
        .s_axi_rresp        (m_axi_rresp),
        .s_axi_rvalid       (m_axi_rvalid),
        .s_axi_rready       (m_axi_rready),
        .global_control_o   (),
        .error_status_set_i (32'h0),
        .timestamp_i        (timestamp),
        // Phase 2 SFP CSR ports unused in Phase 1.
        .sfp_status_i (32'h0), .sfp_rx0_i (32'h0), .sfp_rx1_i (32'h0),
        .sfp_tx0_i (32'h0), .sfp_tx1_i (32'h0), .sfp_control_o ()
    );

    // --- LEDs ----------------------------------------------------------------
    // led_hb : 1 Hz heartbeat (FPGA alive)
    // led[1] : PCIe link up
    // led[0,2,3]: reserved for Phase 2 SFP+ status
    pw_heartbeat #(.CLK_HZ(100_000_000), .RATE_HZ(1)) u_hb (
        .clk   (clk_100mhz),
        .rst_n (rst_n_100),
        .led_o (led_hb)
    );

    assign led = {2'b00, pcie_link_up, 1'b0};

endmodule

`default_nettype wire
