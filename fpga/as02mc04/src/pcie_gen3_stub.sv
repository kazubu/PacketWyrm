// Phase 1 placeholder for the Xilinx PCIe Gen3 IP wrapper.
//
// This stub exists so the project synthesises before the IP is
// generated. `make ip` runs ip/pcie_gen3.tcl which calls
// create_ip / generate_target on the Xilinx PCIe Gen3 IP and
// produces the real wrapper at:
//
//   build/<run>/<project>.gen/sources_1/ip/pcie_gen3_wrapper/...
//
// Once the IP is generated, Vivado will prefer the IP's wrapper
// over this stub. Until then, the stub keeps signals quiet so a
// fresh checkout still synthesises (without of course functioning
// on a real card).

`default_nettype none

module pcie_gen3_wrapper (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        sys_rst_n,
    input  wire [7:0]  pci_exp_rxp,
    input  wire [7:0]  pci_exp_rxn,
    output wire [7:0]  pci_exp_txp,
    output wire [7:0]  pci_exp_txn,

    output wire        axi_aclk,
    output wire        axi_aresetn,

    output wire [11:0] m_axil_awaddr,
    output wire        m_axil_awvalid,
    input  wire        m_axil_awready,
    output wire [31:0] m_axil_wdata,
    output wire [3:0]  m_axil_wstrb,
    output wire        m_axil_wvalid,
    input  wire        m_axil_wready,
    input  wire [1:0]  m_axil_bresp,
    input  wire        m_axil_bvalid,
    output wire        m_axil_bready,
    output wire [11:0] m_axil_araddr,
    output wire        m_axil_arvalid,
    input  wire        m_axil_arready,
    input  wire [31:0] m_axil_rdata,
    input  wire [1:0]  m_axil_rresp,
    input  wire        m_axil_rvalid,
    output wire        m_axil_rready,

    output wire        user_link_up
);

    // Quiet defaults. Drives nothing on the line, never asserts a
    // master transaction. A real IP wrapper will override this file
    // at IP generation time.
    assign pci_exp_txp    = '0;
    assign pci_exp_txn    = '0;
    assign axi_aclk       = sys_clk_p;
    assign axi_aresetn    = sys_rst_n;
    assign m_axil_awaddr  = '0;
    assign m_axil_awvalid = 1'b0;
    assign m_axil_wdata   = '0;
    assign m_axil_wstrb   = '0;
    assign m_axil_wvalid  = 1'b0;
    assign m_axil_bready  = 1'b0;
    assign m_axil_araddr  = '0;
    assign m_axil_arvalid = 1'b0;
    assign m_axil_rready  = 1'b0;
    assign user_link_up   = 1'b0;

    // Suppress lint warnings for unused inputs in the stub.
    wire _unused = &{1'b0, sys_clk_n, pci_exp_rxp, pci_exp_rxn,
                     m_axil_awready, m_axil_wready, m_axil_bresp,
                     m_axil_bvalid, m_axil_arready, m_axil_rdata,
                     m_axil_rresp, m_axil_rvalid, 1'b0};

endmodule

`default_nettype wire
