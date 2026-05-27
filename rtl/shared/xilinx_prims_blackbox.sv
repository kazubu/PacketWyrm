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

`default_nettype wire
