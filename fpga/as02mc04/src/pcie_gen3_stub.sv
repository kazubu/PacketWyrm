// Phase 1 lint/no-IP placeholder for the generated xdma wrapper
// (AXI-Stream DMA mode + AXI-Lite master). Kept in sync BY HAND with the
// generated IP stub (pcie_gen3_wrapper_stub.v) after the IP was reconfigured
// to AXI-Stream (xdma_axi_intf_mm=AXI_Stream): the MM master ports (m_axi_*)
// are gone; the DMA now rides the H2C/C2H AXI-Stream channels. Used only for
// lint and the use_ip=0 LED/timing smoke build; the real IP wrapper replaces
// it when use_ip=1. If the IP config changes again, re-sync this to the
// generated stub's port list.

`default_nettype none

module pcie_gen3_wrapper (
    input  wire         sys_clk,
    input  wire         sys_clk_gt,
    input  wire         sys_rst_n,
    output wire         user_lnk_up,
    output wire [7:0]   pci_exp_txp,
    output wire [7:0]   pci_exp_txn,
    input  wire [7:0]   pci_exp_rxp,
    input  wire [7:0]   pci_exp_rxn,
    output wire         axi_aclk,
    output wire         axi_aresetn,
    input  wire [0:0]   usr_irq_req,
    output wire [0:0]   usr_irq_ack,
    // AXI-Lite master -> CSR slave (the BAR CSR window)
    output wire [31:0]  m_axil_awaddr,
    output wire [2:0]   m_axil_awprot,
    output wire         m_axil_awvalid,
    input  wire         m_axil_awready,
    output wire [31:0]  m_axil_wdata,
    output wire [3:0]   m_axil_wstrb,
    output wire         m_axil_wvalid,
    input  wire         m_axil_wready,
    input  wire         m_axil_bvalid,
    input  wire [1:0]   m_axil_bresp,
    output wire         m_axil_bready,
    output wire [31:0]  m_axil_araddr,
    output wire [2:0]   m_axil_arprot,
    output wire         m_axil_arvalid,
    input  wire         m_axil_arready,
    input  wire [31:0]  m_axil_rdata,
    input  wire [1:0]   m_axil_rresp,
    input  wire         m_axil_rvalid,
    output wire         m_axil_rready,
    input  wire [18:0]  cfg_mgmt_addr,
    input  wire         cfg_mgmt_write,
    input  wire [31:0]  cfg_mgmt_write_data,
    input  wire [3:0]   cfg_mgmt_byte_enable,
    input  wire         cfg_mgmt_read,
    output wire [31:0]  cfg_mgmt_read_data,
    output wire         cfg_mgmt_read_write_done,
    // XDMA AXI-Stream DMA channels (single channel 0). C2H = punt (FPGA->host,
    // slave in), H2C = inject (host->FPGA, master out). 256-bit @ axi_aclk.
    input  wire [255:0] s_axis_c2h_tdata_0,
    input  wire         s_axis_c2h_tlast_0,
    input  wire         s_axis_c2h_tvalid_0,
    output wire         s_axis_c2h_tready_0,
    input  wire [31:0]  s_axis_c2h_tkeep_0,
    output wire [255:0] m_axis_h2c_tdata_0,
    output wire         m_axis_h2c_tlast_0,
    output wire         m_axis_h2c_tvalid_0,
    input  wire         m_axis_h2c_tready_0,
    output wire [31:0]  m_axis_h2c_tkeep_0
);

    // Quiet defaults: never drive the line, never master a transaction.
    // The real IP wrapper overrides this module at use_ip=1.
    assign axi_aclk    = sys_clk;
    assign axi_aresetn = sys_rst_n;
    assign user_lnk_up = 1'b0;
    assign pci_exp_txp = '0;
    assign pci_exp_txn = '0;
    assign usr_irq_ack = '0;
    assign m_axil_awaddr = '0;
    assign m_axil_awprot = '0;
    assign m_axil_awvalid = '0;
    assign m_axil_wdata = '0;
    assign m_axil_wstrb = '0;
    assign m_axil_wvalid = '0;
    assign m_axil_bready = '0;
    assign m_axil_araddr = '0;
    assign m_axil_arprot = '0;
    assign m_axil_arvalid = '0;
    assign m_axil_rready = '0;
    assign cfg_mgmt_read_data = '0;
    assign cfg_mgmt_read_write_done = '0;
    // DMA streams: sink C2H, source nothing on H2C.
    assign s_axis_c2h_tready_0 = '0;
    assign m_axis_h2c_tdata_0  = '0;
    assign m_axis_h2c_tlast_0  = '0;
    assign m_axis_h2c_tvalid_0 = '0;
    assign m_axis_h2c_tkeep_0  = '0;

    // Soak up unused inputs for a clean lint.
    wire _unused = &{1'b0, sys_clk, sys_clk_gt, sys_rst_n, pci_exp_rxp, pci_exp_rxn, usr_irq_req, m_axil_awready, m_axil_wready, m_axil_bvalid, m_axil_bresp, m_axil_arready, m_axil_rdata, m_axil_rresp, m_axil_rvalid, cfg_mgmt_addr, cfg_mgmt_write, cfg_mgmt_write_data, cfg_mgmt_byte_enable, cfg_mgmt_read, s_axis_c2h_tdata_0, s_axis_c2h_tlast_0, s_axis_c2h_tvalid_0, s_axis_c2h_tkeep_0, m_axis_h2c_tready_0, 1'b0};

endmodule

`default_nettype wire
