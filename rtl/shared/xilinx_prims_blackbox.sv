// Black-box stubs of the Xilinx UltraScale+ primitives PacketWyrm
// instantiates by name (IBUFDS, BUFG, ...). Used for Verilator lint
// only; Vivado picks up the real `unisims` library at synthesis.
// Do not add this file to the Vivado fileset.

`default_nettype none

module IBUFDS #(
    parameter DIFF_TERM    = "FALSE",
    parameter IBUF_LOW_PWR = "TRUE",
    parameter IOSTANDARD   = "DEFAULT"
) (
    input  wire I,
    input  wire IB,
    output wire O
);
    assign O = I;
    wire _unused = &{1'b0, IB, 1'b0};
endmodule

module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

// GT reference-clock input buffer (PCIe MGT refclk). O = buffered
// refclk to the GT, ODIV2 = refclk/2 to fabric. Lint stub only.
module IBUFDS_GTE4 #(
    parameter         REFCLK_EN_TX_PATH  = 1'b0,
    parameter [1:0]   REFCLK_HROW_CK_SEL = 2'b00,
    parameter [1:0]   REFCLK_ICNTL_RX    = 2'b00
) (
    input  wire I,
    input  wire IB,
    input  wire CEB,
    output wire O,
    output wire ODIV2
);
    assign O     = I;
    assign ODIV2 = I;
    wire _unused = &{1'b0, IB, CEB, 1'b0};
endmodule

`default_nettype wire
