// pw_sysmon: DRP driver for the on-chip System Monitor (SYSMONE4 in
// UltraScale+; the primitive itself is instantiated in the board top, like
// STARTUPE3 / ICAPE3). Pure logic (no vendor primitive here), so it elaborates
// in simulation too.
//
// On reset it first WRITES a small config set so the ADC actually runs:
//   0x40 (config0) = 0x0000  -- no averaging
//   0x41 (config1) = 0x0000  -- default mode (SEQ=0): auto-samples the on-chip
//                               sensors (temp / VCCINT / VCCAUX / VCCBRAM),
//                               no channel-sequencer setup needed
//   0x42 (config2) = 0x0800  -- ADCCLK = DCLK/8. At DCLK=156.25 MHz that is
//                               ~19.5 MHz, inside SYSMONE4's ADCCLK range.
//                               Without a sane divider the ADC never completes
//                               a conversion and the measurement regs stay 0.
// then continuously READS the three on-chip measurement registers and latches
// the raw 16-bit codes (measurement in [15:4]) for CSR readback:
//   0x00 = temperature, 0x01 = VCCINT, 0x02 = VCCAUX.
//
// A watchdog on the DRDY wait prevents a hang if DRDY never asserts.
`default_nettype none
module pw_sysmon (
    input  wire        clk,
    input  wire        rst_n,

    // DRP master -> SYSMONE4 (board top).
    output reg  [7:0]  drp_daddr,
    output reg         drp_den,
    output reg         drp_dwe,
    output reg  [15:0] drp_di,
    input  wire [15:0] drp_do,
    input  wire        drp_drdy,

    // Latched raw ADC codes (measurement in [15:4]); 0 until first read.
    output reg  [15:0] temp_o,
    output reg  [15:0] vccint_o,
    output reg  [15:0] vccaux_o
);
    // Config writes (addr, data), applied once after reset.
    localparam int      NCFG     = 3;
    localparam [1:0]    CFG_LAST = 2'(NCFG - 1);
    // Read addresses, polled round-robin forever.
    localparam [7:0] A_TEMP = 8'h00, A_VCCINT = 8'h01, A_VCCAUX = 8'h02;

    function automatic [7:0] cfg_addr(input [1:0] i);
        case (i) 2'd0: cfg_addr = 8'h40; 2'd1: cfg_addr = 8'h41; default: cfg_addr = 8'h42; endcase
    endfunction
    function automatic [15:0] cfg_data(input [1:0] i);
        case (i) 2'd0: cfg_data = 16'h0000; 2'd1: cfg_data = 16'h0000; default: cfg_data = 16'h0800; endcase
    endfunction
    function automatic [7:0] rd_addr(input [1:0] i);
        case (i) 2'd0: rd_addr = A_TEMP; 2'd1: rd_addr = A_VCCINT; default: rd_addr = A_VCCAUX; endcase
    endfunction

    // phase: 0 = config-write sweep, 1 = read loop
    reg        phase;
    reg [1:0]  idx;
    reg        state;    // 0 = issue transaction, 1 = wait for DRDY
    reg [11:0] wdog;
    localparam S_REQ = 1'b0, S_WAIT = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drp_daddr <= 8'h40; drp_den <= 1'b0; drp_dwe <= 1'b0; drp_di <= 16'h0;
            phase <= 1'b0; idx <= 2'd0; state <= S_REQ; wdog <= 12'd0;
            temp_o <= 16'h0; vccint_o <= 16'h0; vccaux_o <= 16'h0;
        end else begin
            drp_den <= 1'b0;
            case (state)
                S_REQ: begin
                    if (!phase) begin           // config write
                        drp_daddr <= cfg_addr(idx);
                        drp_di    <= cfg_data(idx);
                        drp_dwe   <= 1'b1;
                    end else begin              // measurement read
                        drp_daddr <= rd_addr(idx);
                        drp_dwe   <= 1'b0;
                    end
                    drp_den <= 1'b1;            // single-cycle enable
                    wdog    <= 12'd0;
                    state   <= S_WAIT;
                end
                S_WAIT: begin
                    wdog <= wdog + 12'd1;
                    if (drp_drdy || (&wdog)) begin
                        if (phase && drp_drdy) begin
                            case (idx)
                                2'd0:    temp_o   <= drp_do;
                                2'd1:    vccint_o <= drp_do;
                                default: vccaux_o <= drp_do;
                            endcase
                        end
                        // advance index; after the config sweep, switch to reads
                        if (!phase) begin
                            if (idx == CFG_LAST) begin phase <= 1'b1; idx <= 2'd0; end
                            else idx <= idx + 2'd1;
                        end else begin
                            idx <= (idx == 2'd2) ? 2'd0 : (idx + 2'd1);
                        end
                        drp_dwe <= 1'b0;
                        state   <= S_REQ;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
