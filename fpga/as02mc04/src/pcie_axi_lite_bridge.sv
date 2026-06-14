// PCIe Gen3 endpoint -> AXI4-Lite master bridge.
//
// Thin shim around the Xilinx DMA/Bridge Subsystem for PCIe (module
// `pcie_gen3_wrapper`, generated as xdma in DMA mode by
// ip/pcie_gen3.tcl). The IP's AXI4-Lite *master* (M_AXI_LITE, ports
// m_axil_*) is a PCIe BAR mapped to host MMIO: host reads/writes to
// that BAR appear here as AXI-Lite transactions, which drive the
// pw_csr_min CSR slave in the top-level. The IP's DMA AXI-MM master
// (m_axi_*), config-management (cfg_mgmt_*) and user IRQ ports are
// unused in Phase 1 and tied off; Phase 2 will use the DMA engine for
// the host punt / inject rings.
//
// This module's interface to the top-level is unchanged from the
// earlier stub-era version (axi_aclk/axi_aresetn, a 32-bit-data
// AXI-Lite master truncated to AXIL_ADDR_W address bits, link_up), so
// pwfpga_top_phase1.sv binds to it without changes.

`default_nettype none

module pcie_axi_lite_bridge #(
    parameter int AXIL_ADDR_W = 12
) (
    // PCIe board pins
    input  wire        pcie_refclk_p,
    input  wire        pcie_refclk_n,
    input  wire        pcie_perst_n,
    input  wire [7:0]  pcie_rx_p,
    input  wire [7:0]  pcie_rx_n,
    output wire [7:0]  pcie_tx_p,
    output wire [7:0]  pcie_tx_n,

    // AXI4-Lite master to the CSR fabric (clocked by axi_aclk)
    output wire                    axi_aclk,
    output wire                    axi_aresetn,

    output wire [AXIL_ADDR_W-1:0]  m_axi_awaddr,
    output wire                    m_axi_awvalid,
    input  wire                    m_axi_awready,
    output wire [31:0]             m_axi_wdata,
    output wire [3:0]              m_axi_wstrb,
    output wire                    m_axi_wvalid,
    input  wire                    m_axi_wready,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output wire                    m_axi_bready,
    output wire [AXIL_ADDR_W-1:0]  m_axi_araddr,
    output wire                    m_axi_arvalid,
    input  wire                    m_axi_arready,
    input  wire [31:0]             m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rvalid,
    output wire                    m_axi_rready,

    // Status to surface in CSR / LED
    output wire        link_up
);

    // --- GT reference clock buffer ------------------------------------------
    // The PCIe MGT refclk (T7/T6, 100 MHz) feeds the IP as a buffered
    // clock (sys_clk_gt) plus a /2 fabric clock (sys_clk).
    wire sys_clk;
    wire sys_clk_gt;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_refclk_ibuf (
        .I     (pcie_refclk_p),
        .IB    (pcie_refclk_n),
        .CEB   (1'b0),
        .O     (sys_clk_gt),
        .ODIV2 (sys_clk)
    );

    // --- AXI-Lite master address truncation ---------------------------------
    // The IP drives a full 32-bit AXI-Lite address; the CSR window only
    // needs the low AXIL_ADDR_W bits.
    wire [31:0] axil_awaddr;
    wire [31:0] axil_araddr;
    assign m_axi_awaddr = axil_awaddr[AXIL_ADDR_W-1:0];
    assign m_axi_araddr = axil_araddr[AXIL_ADDR_W-1:0];

    pcie_gen3_wrapper u_pcie (
        // clocks / reset / status
        .sys_clk      (sys_clk),
        .sys_clk_gt   (sys_clk_gt),
        .sys_rst_n    (pcie_perst_n),
        .user_lnk_up  (link_up),
        .axi_aclk     (axi_aclk),
        .axi_aresetn  (axi_aresetn),

        // PCIe serial lanes
        .pci_exp_txp  (pcie_tx_p),
        .pci_exp_txn  (pcie_tx_n),
        .pci_exp_rxp  (pcie_rx_p),
        .pci_exp_rxn  (pcie_rx_n),

        // user IRQ -- unused
        .usr_irq_req  (1'b0),
        .usr_irq_ack  (),

        // DMA AXI-MM master -- unused in Phase 1: tie inputs off, leave
        // outputs open.
        .m_axi_awready (1'b0),
        .m_axi_wready  (1'b0),
        .m_axi_bid     (4'b0),
        .m_axi_bresp   (2'b0),
        .m_axi_bvalid  (1'b0),
        .m_axi_arready (1'b0),
        .m_axi_rid     (4'b0),
        .m_axi_rdata   (256'b0),
        .m_axi_rresp   (2'b0),
        .m_axi_rlast   (1'b0),
        .m_axi_rvalid  (1'b0),
        .m_axi_awid    (),
        .m_axi_awaddr  (),
        .m_axi_awlen   (),
        .m_axi_awsize  (),
        .m_axi_awburst (),
        .m_axi_awprot  (),
        .m_axi_awvalid (),
        .m_axi_awlock  (),
        .m_axi_awcache (),
        .m_axi_wdata   (),
        .m_axi_wstrb   (),
        .m_axi_wlast   (),
        .m_axi_wvalid  (),
        .m_axi_bready  (),
        .m_axi_arid    (),
        .m_axi_araddr  (),
        .m_axi_arlen   (),
        .m_axi_arsize  (),
        .m_axi_arburst (),
        .m_axi_arprot  (),
        .m_axi_arvalid (),
        .m_axi_arlock  (),
        .m_axi_arcache (),
        .m_axi_rready  (),

        // AXI-Lite master -> CSR slave (the BAR CSR window)
        .m_axil_awaddr  (axil_awaddr),
        .m_axil_awprot  (),
        .m_axil_awvalid (m_axi_awvalid),
        .m_axil_awready (m_axi_awready),
        .m_axil_wdata   (m_axi_wdata),
        .m_axil_wstrb   (m_axi_wstrb),
        .m_axil_wvalid  (m_axi_wvalid),
        .m_axil_wready  (m_axi_wready),
        .m_axil_bvalid  (m_axi_bvalid),
        .m_axil_bresp   (m_axi_bresp),
        .m_axil_bready  (m_axi_bready),
        .m_axil_araddr  (axil_araddr),
        .m_axil_arprot  (),
        .m_axil_arvalid (m_axi_arvalid),
        .m_axil_arready (m_axi_arready),
        .m_axil_rdata   (m_axi_rdata),
        .m_axil_rresp   (m_axi_rresp),
        .m_axil_rvalid  (m_axi_rvalid),
        .m_axil_rready  (m_axi_rready),

        // PCIe config-management -- unused
        .cfg_mgmt_addr            (19'b0),
        .cfg_mgmt_write           (1'b0),
        .cfg_mgmt_write_data      (32'b0),
        .cfg_mgmt_byte_enable     (4'b0),
        .cfg_mgmt_read            (1'b0),
        .cfg_mgmt_read_data       (),
        .cfg_mgmt_read_write_done ()
    );

endmodule

`default_nettype wire
