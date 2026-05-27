// AS02MC04 Phase 1 top-level.
//
// Goals:
//   - PCIe Gen3 endpoint enumerates on the host
//   - BAR0 exposes pw_csr_min (device_id, version, capabilities, ...)
//   - LED heartbeat shows the FPGA is alive
//   - Free-running 64-bit timestamp counter is readable via BAR0
//
// Out of scope for Phase 1: SFP+ data plane, classifier, flow gen,
// punt queues, DMA rings. Those land in Phases 2 - 4.

`default_nettype none

module pwfpga_top_phase1 (
    // PCIe
    input  wire        pcie_refclk_p,
    input  wire        pcie_refclk_n,
    input  wire        pcie_perst_n,
    input  wire [7:0]  pcie_rx_p,
    input  wire [7:0]  pcie_rx_n,
    output wire [7:0]  pcie_tx_p,
    output wire [7:0]  pcie_tx_n,

    // Board reference clock + reset (pinned in XDC)
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        sys_rst_n,

    // User LEDs (count and polarity from board schematic)
    output wire [3:0]  led
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
        .pcie_perst_n  (pcie_perst_n),
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

    // --- Clocking + reset ----------------------------------------------------
    wire clk_100mhz;
    wire rst_n_100;

    clock_reset u_clkrst (
        .sys_clk_p        (sys_clk_p),
        .sys_clk_n        (sys_clk_n),
        .sys_rst_n        (sys_rst_n),
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
        .timestamp_i        (timestamp)
    );

    // --- LEDs ----------------------------------------------------------------
    // led[0]: 1 Hz heartbeat (FPGA alive)
    // led[1]: PCIe link up
    // led[2..3]: reserved for SFP link status (Phase 2)
    wire heartbeat;
    pw_heartbeat #(.CLK_HZ(100_000_000), .RATE_HZ(1)) u_hb (
        .clk   (clk_100mhz),
        .rst_n (rst_n_100),
        .led_o (heartbeat)
    );

    assign led = {2'b00, pcie_link_up, heartbeat};

endmodule

`default_nettype wire
