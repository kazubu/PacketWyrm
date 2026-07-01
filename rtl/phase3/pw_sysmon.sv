// pw_sysmon: minimal DRP reader for the on-chip System Monitor (SYSMONE4 in
// UltraScale+; the primitive itself is instantiated in the board top, like
// STARTUPE3 / ICAPE3). SYSMONE4 powers up in *default mode* and continuously
// samples the on-chip sensors with no sequencer configuration, so this reader
// only issues DRP READS and never writes config -- keeping it pure logic (no
// vendor primitive here), so it elaborates in simulation too.
//
// It round-robins the three on-chip measurement registers and latches the raw
// 16-bit ADC codes (measurement in [15:4]) for CSR readback:
//   0x00 = temperature, 0x01 = VCCINT, 0x02 = VCCAUX.
//
// A watchdog on the DRDY wait prevents a hang if the primitive never asserts
// DRDY (e.g. in a Verilator model without a SYSMONE4).
`default_nettype none
module pw_sysmon (
    input  wire        clk,
    input  wire        rst_n,

    // DRP master -> SYSMONE4 (board top). Read-only: dwe/di tied off.
    output reg  [7:0]  drp_daddr,
    output reg         drp_den,
    output wire        drp_dwe,
    output wire [15:0] drp_di,
    input  wire [15:0] drp_do,
    input  wire        drp_drdy,

    // Latched raw ADC codes (measurement in [15:4]); 0 until first read.
    output reg  [15:0] temp_o,
    output reg  [15:0] vccint_o,
    output reg  [15:0] vccaux_o
);
    assign drp_dwe = 1'b0;
    assign drp_di  = 16'h0000;

    localparam [7:0] A_TEMP = 8'h00, A_VCCINT = 8'h01, A_VCCAUX = 8'h02;

    reg [1:0]  idx;      // 0=temp, 1=vccint, 2=vccaux
    reg        state;    // 0=issue request, 1=wait for DRDY
    reg [11:0] wdog;     // DRDY watchdog

    localparam S_REQ = 1'b0, S_WAIT = 1'b1;

    function automatic [7:0] addr_of(input [1:0] i);
        case (i)
            2'd0:    addr_of = A_TEMP;
            2'd1:    addr_of = A_VCCINT;
            default: addr_of = A_VCCAUX;
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drp_daddr <= A_TEMP;
            drp_den   <= 1'b0;
            idx       <= 2'd0;
            state     <= S_REQ;
            wdog      <= 12'd0;
            temp_o    <= 16'h0000;
            vccint_o  <= 16'h0000;
            vccaux_o  <= 16'h0000;
        end else begin
            drp_den <= 1'b0;
            case (state)
                S_REQ: begin
                    drp_daddr <= addr_of(idx);
                    drp_den   <= 1'b1;     // single-cycle enable
                    wdog      <= 12'd0;
                    state     <= S_WAIT;
                end
                S_WAIT: begin
                    wdog <= wdog + 12'd1;
                    if (drp_drdy) begin
                        case (idx)
                            2'd0:    temp_o   <= drp_do;
                            2'd1:    vccint_o <= drp_do;
                            default: vccaux_o <= drp_do;
                        endcase
                        idx   <= (idx == 2'd2) ? 2'd0 : (idx + 2'd1);
                        state <= S_REQ;
                    end else if (&wdog) begin
                        // DRDY never came (no SYSMON / model): skip to next.
                        idx   <= (idx == 2'd2) ? 2'd0 : (idx + 2'd1);
                        state <= S_REQ;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
