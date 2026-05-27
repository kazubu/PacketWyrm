// Free-running 64-bit timestamp counter, used by the CSR fabric to
// expose a card-local clock. RX checker / flow generators (Phase 3)
// will tap the same counter for sequence / latency stamping.

`default_nettype none

module pw_timestamp (
    input  wire        clk,
    input  wire        rst_n,
    output reg [63:0]  ts_o
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts_o <= '0;
        else        ts_o <= ts_o + 1'b1;
    end

endmodule

`default_nettype wire
