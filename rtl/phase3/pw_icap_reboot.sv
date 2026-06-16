// PacketWyrm in-band reconfiguration trigger (ICAP IPROG).
//
// On a CSR-driven pulse, streams the IPROG command sequence into the
// FPGA's internal configuration access port (ICAPE3, instantiated in the
// board top). IPROG restarts configuration from the SPI flash at the
// WBSTAR address (0 = the boot image), so a freshly flashed bitstream
// can be loaded WITHOUT JTAG or a power cycle.
//
// IMPORTANT: reconfiguration reloads the whole FPGA, including the PCIe
// hard block, so the PCIe endpoint DROPS during reconfig -- the host
// must re-enumerate (PCIe remove + rescan) afterwards. If the reloaded
// image is bad the device will not come back (JTAG is the recovery).
//
// The engine is board-agnostic (plain ICAP write port) so it simulates;
// the board top wires icap_o_* to the ICAPE3 primitive (CLK = same clk).
//
// ICAP data ordering: the config logic expects each byte bit-reversed on
// I[31:0]. ICAP_BITSWAP (default 1) applies that per-byte reversal; if a
// board ever needs the raw order, set it to 0.

`default_nettype none

module pw_icap_reboot #(
    parameter logic [31:0] WBSTAR      = 32'h0000_0000,  // boot/reload address
    parameter int          ICAP_BITSWAP = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        reboot_i,       // 1-cycle pulse: start IPROG

    // ICAP write port (to ICAPE3 in the board top)
    output logic       icap_csib,      // active-low chip select
    output logic       icap_rdwrb,     // 0 = write
    output logic [31:0] icap_i,        // config data
    output logic       icap_busy_o     // sequence in progress (status)
);

    // IPROG command sequence (readable; bit-swapped below for ICAP).
    localparam int N = 9;
    logic [31:0] seq [N];
    initial begin
        seq[0] = 32'hFFFF_FFFF;  // dummy pad
        seq[1] = 32'hAA99_5566;  // sync word
        seq[2] = 32'h2000_0000;  // type-1 NOOP
        seq[3] = 32'h3002_0001;  // type-1 write 1 word -> WBSTAR
        seq[4] = WBSTAR;         // reload start address
        seq[5] = 32'h3000_8001;  // type-1 write 1 word -> CMD
        seq[6] = 32'h0000_000F;  // CMD = IPROG (restart config)
        seq[7] = 32'h2000_0000;  // NOOP
        seq[8] = 32'h2000_0000;  // NOOP
    end

    // Per-byte bit reversal (ICAP I[] convention).
    function automatic logic [31:0] bswap(input logic [31:0] w);
        logic [31:0] o;
        for (int b = 0; b < 4; b++)
            for (int i = 0; i < 8; i++)
                o[b*8 + i] = w[b*8 + (7 - i)];
        return o;
    endfunction

    logic        running;
    logic [3:0]  idx;

    assign icap_busy_o = running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running    <= 1'b0;
            idx        <= 4'd0;
            icap_csib  <= 1'b1;        // deselected
            icap_rdwrb <= 1'b1;        // read (idle)
            icap_i     <= 32'hFFFF_FFFF;
        end else if (!running) begin
            icap_csib  <= 1'b1;
            icap_rdwrb <= 1'b1;
            icap_i     <= 32'hFFFF_FFFF;
            if (reboot_i) begin
                running    <= 1'b1;
                idx        <= 4'd0;
                icap_csib  <= 1'b0;     // select + write
                icap_rdwrb <= 1'b0;
                icap_i     <= ICAP_BITSWAP ? bswap(seq[0]) : seq[0];
            end
        end else begin
            // Stream one command word per clock with CSIB held low.
            if (idx == N - 1) begin
                // last word issued; deselect. (The config logic has by now
                // accepted IPROG and is restarting -- the device is on its
                // way out; nothing more to do.)
                running   <= 1'b0;
                icap_csib <= 1'b1;
                icap_rdwrb<= 1'b1;
                icap_i    <= 32'hFFFF_FFFF;
            end else begin
                idx    <= idx + 4'd1;
                icap_i <= ICAP_BITSWAP ? bswap(seq[idx + 4'd1]) : seq[idx + 4'd1];
            end
        end
    end

endmodule

`default_nettype wire
