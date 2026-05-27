// AS02MC04 clock + reset distribution for Phase 1.
//
// Inputs:
//   - sys_clk_p/n: differential reference clock from the board
//     (frequency TBD from schematic; XDC pins it to the actual
//     MMCM-capable bank).
//   - sys_rst_n: active-low board reset (push-button / PCIe PERST#
//     fan-out, configured in XDC).
//
// Outputs:
//   - clk_100mhz: housekeeping clock for the heartbeat / sysmon
//   - clk_axi:    AXI4-Lite domain clock (drives pw_csr_min). Phase
//                 1 ties this directly to the PCIe user clock from
//                 the hard IP, so this module's clk_axi output is
//                 unused in the Phase 1 top-level. It is kept so the
//                 same module can be reused when Phase 2 adds an
//                 independent MAC clock domain.
//   - rst_n_axi:  synchronous reset for the AXI domain
//   - rst_n_100:  synchronous reset for the 100 MHz domain

`default_nettype none

module clock_reset (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    input  wire sys_rst_n,

    output wire clk_100mhz,
    output wire rst_n_100,

    // Pass-through PCIe user clock / reset, retimed for downstream use
    input  wire pcie_user_clk,
    input  wire pcie_user_resetn,
    output wire clk_axi,
    output wire rst_n_axi
);

    // Phase 1: synthesise an MMCM-derived 100 MHz domain from
    // sys_clk. The exact MMCM parameters are owned by
    // ip/clk_wiz.tcl; this stub uses a BUFG passthrough so a fresh
    // checkout synthesises without the IP generated.

    wire sys_clk;
    IBUFDS #(.DIFF_TERM("TRUE")) u_sysclk_ibuf (
        .I  (sys_clk_p),
        .IB (sys_clk_n),
        .O  (sys_clk)
    );

    BUFG u_bufg_100 (.I(sys_clk), .O(clk_100mhz));

    // Two-flop reset synchronisers into each domain.
    reg [1:0] r100_sync;
    always @(posedge clk_100mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) r100_sync <= 2'b00;
        else            r100_sync <= {r100_sync[0], 1'b1};
    end
    assign rst_n_100 = r100_sync[1];

    assign clk_axi   = pcie_user_clk;
    reg [1:0] raxi_sync;
    always @(posedge pcie_user_clk or negedge pcie_user_resetn) begin
        if (!pcie_user_resetn) raxi_sync <= 2'b00;
        else                   raxi_sync <= {raxi_sync[0], 1'b1};
    end
    assign rst_n_axi = raxi_sync[1];

endmodule

`default_nettype wire
