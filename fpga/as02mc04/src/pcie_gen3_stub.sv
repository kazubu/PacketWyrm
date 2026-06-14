// Phase 1 lint/no-IP placeholder for the generated xdma wrapper
// (DMA mode + AXI-Lite master). AUTO-GENERATED from the IP's
// pcie_gen3_wrapper_stub.v by ip/gen_stub.sh -- do not hand-edit;
// regenerate after changing the IP config. Used only for Verilator
// lint and the use_ip=0 LED/timing smoke build; the real IP wrapper
// replaces it when use_ip=1.

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
    input  wire         m_axi_awready,
    input  wire         m_axi_wready,
    input  wire [3:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    input  wire         m_axi_arready,
    input  wire [3:0]   m_axi_rid,
    input  wire [255:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire [3:0]   m_axi_awid,
    output wire [63:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire [2:0]   m_axi_awprot,
    output wire         m_axi_awvalid,
    output wire         m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [255:0] m_axi_wdata,
    output wire [31:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    output wire         m_axi_bready,
    output wire [3:0]   m_axi_arid,
    output wire [63:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire [2:0]   m_axi_arprot,
    output wire         m_axi_arvalid,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire         m_axi_rready,
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
    output wire         cfg_mgmt_read_write_done
);

    // Quiet defaults: never drive the line, never master a transaction.
    // The real IP wrapper overrides this module at use_ip=1.
    assign axi_aclk    = sys_clk;
    assign axi_aresetn = sys_rst_n;
    assign user_lnk_up = 1'b0;
    assign pci_exp_txp = '0;
    assign pci_exp_txn = '0;
    assign usr_irq_ack = '0;
    assign m_axi_awid = '0;
    assign m_axi_awaddr = '0;
    assign m_axi_awlen = '0;
    assign m_axi_awsize = '0;
    assign m_axi_awburst = '0;
    assign m_axi_awprot = '0;
    assign m_axi_awvalid = '0;
    assign m_axi_awlock = '0;
    assign m_axi_awcache = '0;
    assign m_axi_wdata = '0;
    assign m_axi_wstrb = '0;
    assign m_axi_wlast = '0;
    assign m_axi_wvalid = '0;
    assign m_axi_bready = '0;
    assign m_axi_arid = '0;
    assign m_axi_araddr = '0;
    assign m_axi_arlen = '0;
    assign m_axi_arsize = '0;
    assign m_axi_arburst = '0;
    assign m_axi_arprot = '0;
    assign m_axi_arvalid = '0;
    assign m_axi_arlock = '0;
    assign m_axi_arcache = '0;
    assign m_axi_rready = '0;
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

    // Soak up unused inputs for a clean lint.
    wire _unused = &{1'b0, sys_clk, sys_clk_gt, sys_rst_n, pci_exp_rxp, pci_exp_rxn, usr_irq_req, m_axi_awready, m_axi_wready, m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_arready, m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, m_axil_awready, m_axil_wready, m_axil_bvalid, m_axil_bresp, m_axil_arready, m_axil_rdata, m_axil_rresp, m_axil_rvalid, cfg_mgmt_addr, cfg_mgmt_write, cfg_mgmt_write_data, cfg_mgmt_byte_enable, cfg_mgmt_read, 1'b0};

endmodule

`default_nettype wire
