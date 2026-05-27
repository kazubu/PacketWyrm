// PCIe Gen3 endpoint -> AXI4-Lite slave bridge.
//
// Thin shim around the Xilinx PCIe Gen3 hard IP (xdma / pcie4 /
// pcie_ultrascale_plus, configured by ip/pcie_gen3.tcl). The hard IP
// already implements config space, MSI(/-X), and a BAR-attached
// AXI4-Lite master; this wrapper just renames signals so the top-
// level wiring stays readable.
//
// Phase 1 only exposes BAR0 as AXI-Lite. Phase 2 adds BAR0 windows
// for DMA descriptor rings on a separate AXI-Full master.

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

    // The actual instance comes from the Xilinx PCIe Gen3 IP whose
    // module name is set by ip/pcie_gen3.tcl. We bind to it by name
    // so the build script can swap between pcie4_uscale_plus_0 and
    // xdma_0 without touching this file.
    //
    // The IP must be configured with:
    //   - x8 Gen3 lanes
    //   - BAR0 = 64 KB, AXI-Lite mapped
    //   - Vendor / Device ID = (TBD, set in ip/pcie_gen3.tcl)
    //   - Subsystem ID encoding "AS02MC04 / PacketWyrm"
    //   - 250 MHz user clock
    //
    // The instantiation lives in ip/pcie_gen3_stub.v which the IP
    // generator overwrites with the real wrapper.

    pcie_gen3_wrapper u_pcie (
        .sys_clk_p      (pcie_refclk_p),
        .sys_clk_n      (pcie_refclk_n),
        .sys_rst_n      (pcie_perst_n),
        .pci_exp_rxp    (pcie_rx_p),
        .pci_exp_rxn    (pcie_rx_n),
        .pci_exp_txp    (pcie_tx_p),
        .pci_exp_txn    (pcie_tx_n),

        .axi_aclk       (axi_aclk),
        .axi_aresetn    (axi_aresetn),

        .m_axil_awaddr  (m_axi_awaddr),
        .m_axil_awvalid (m_axi_awvalid),
        .m_axil_awready (m_axi_awready),
        .m_axil_wdata   (m_axi_wdata),
        .m_axil_wstrb   (m_axi_wstrb),
        .m_axil_wvalid  (m_axi_wvalid),
        .m_axil_wready  (m_axi_wready),
        .m_axil_bresp   (m_axi_bresp),
        .m_axil_bvalid  (m_axi_bvalid),
        .m_axil_bready  (m_axi_bready),
        .m_axil_araddr  (m_axi_araddr),
        .m_axil_arvalid (m_axi_arvalid),
        .m_axil_arready (m_axi_arready),
        .m_axil_rdata   (m_axi_rdata),
        .m_axil_rresp   (m_axi_rresp),
        .m_axil_rvalid  (m_axi_rvalid),
        .m_axil_rready  (m_axi_rready),

        .user_link_up   (link_up)
    );

endmodule

`default_nettype wire
