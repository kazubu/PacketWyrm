// PacketWyrm LED heartbeat. Asserts `led_o` ~1 Hz so a working
// bitstream is visibly distinguishable from a stuck / unprogrammed
// FPGA. The divider is a parameter so the same module works on
// 100 MHz, 125 MHz and 250 MHz reference domains.

`default_nettype none

module pw_heartbeat #(
    parameter int CLK_HZ = 100_000_000,
    parameter int RATE_HZ = 1
) (
    input  wire clk,
    input  wire rst_n,
    output reg  led_o
);

    localparam int DIVIDER = CLK_HZ / (2 * RATE_HZ);
    localparam int CW      = $clog2(DIVIDER);

    reg [CW-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= '0;
            led_o <= 1'b0;
        end else if (cnt == CW'(DIVIDER - 1)) begin
            cnt   <= '0;
            led_o <= ~led_o;
        end else begin
            cnt   <= cnt + 1'b1;
        end
    end

endmodule

`default_nettype wire
