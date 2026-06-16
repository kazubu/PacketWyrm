// PacketWyrm in-system SPI flash access (live, over the CSR/PCIe path).
//
// A thin CSR-driven SPI master that reaches the board's configuration
// flash (Micron MT25QU256) through the FPGA's STARTUPE3 primitive AFTER
// configuration -- so the host can erase / program / read-back the boot
// image over PCIe WHILE the data plane keeps running (no JTAG, no
// reconfiguration, the PCIe endpoint stays up). The current run is
// unaffected: the FPGA already has its bitstream in SRAM and does not
// touch the flash until the next power-on.
//
// Deliberately minimal (a lab/update tool, not a fielded auto-update):
// this is a RAW single-bit (x1) SPI mode-0 byte engine. Software composes
// the flash command sequences (WREN 06, sector-erase 20/D8, page-program
// 02, read 03, read-status 05) as raw byte streams and verifies by
// read-back. No golden/fallback multiboot: a failed write is simply
// re-written (verify!), and JTAG can always re-flash as a last resort.
//
// CSR map (byte offsets from WIN_BASE, dword-accessed):
//   0x000 CTRL   W: [0]=go (start a transfer), [1]=cs_hold (leave CS
//                   asserted after the transfer, to chain commands)
//                R: [0]=busy
//   0x004 LEN    number of bytes to shift this transfer (1..BUF_BYTES)
//   0x100..      TX buffer (BUF_BYTES, little-endian within each dword)
//   0x100+BUF..  RX buffer (BUF_BYTES) -- MISO captured per shifted byte
//
// Transfer: on go, CS is asserted, LEN bytes are shifted MSB-first on
// MOSI (mode 0: drive while SCK low, sample MISO on SCK rising), the
// received bytes land in the RX buffer, then CS is deasserted unless
// cs_hold is set. The SPI clock is clk / (2*CLK_DIV).

`default_nettype none

module pw_spi_flash #(
    parameter int          ADDR_W    = 16,
    parameter logic [15:0] WIN_BASE  = 16'h0800,
    parameter int          BUF_BYTES = 512,
    parameter int          CLK_DIV   = 8       // SCK = clk / (2*CLK_DIV)
) (
    input  wire              clk,
    input  wire              rst_n,

    // CSR write strobe (from pw_csr_full's decoded AXI-Lite write)
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [31:0]       wr_data,

    // CSR read (combinational; csr_full muxes this in for the SPI range)
    input  wire [ADDR_W-1:0] rd_addr,
    output logic [31:0]      rd_data,

    // SPI pins -- wired to STARTUPE3 in the board top (HW only).
    output logic             sck,
    output logic             cs_n,
    output logic             mosi,
    input  wire              miso
);

    localparam int TX_OFF = 16'h100;
    localparam int RX_OFF = 16'h100 + BUF_BYTES;
    localparam int LENW   = $clog2(BUF_BYTES + 1);

    logic [7:0]      tx_buf [BUF_BYTES];
    logic [7:0]      rx_buf [BUF_BYTES];
    logic [LENW-1:0] len;
    logic            cs_hold;
    logic            go;
    logic            busy;

    // ---- CSR writes ----
    wire [15:0] woff = wr_addr - WIN_BASE;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go      <= 1'b0;
            cs_hold <= 1'b0;
            len     <= '0;
        end else begin
            go <= 1'b0;   // one-cycle pulse
            if (wr_en) begin
                if (woff == 16'h000) begin
                    go      <= wr_data[0];
                    cs_hold <= wr_data[1];
                end else if (woff == 16'h004) begin
                    len <= wr_data[LENW-1:0];
                end else if (woff >= TX_OFF && woff < TX_OFF + BUF_BYTES) begin
                    automatic int b = int'(woff) - TX_OFF;   // dword-aligned
                    tx_buf[b+0] <= wr_data[7:0];
                    tx_buf[b+1] <= wr_data[15:8];
                    tx_buf[b+2] <= wr_data[23:16];
                    tx_buf[b+3] <= wr_data[31:24];
                end
            end
        end
    end

    // ---- CSR reads ----
    logic [15:0] roff;
    always_comb roff = rd_addr - WIN_BASE;
    always_comb begin
        rd_data = 32'h0;
        if (roff == 16'h000)
            rd_data = {31'h0, busy};
        else if (roff == 16'h004)
            rd_data = {{(32-LENW){1'b0}}, len};
        else if (roff >= RX_OFF && roff < RX_OFF + BUF_BYTES)
            rd_data = {rx_buf[int'(roff)-RX_OFF+3], rx_buf[int'(roff)-RX_OFF+2],
                       rx_buf[int'(roff)-RX_OFF+1], rx_buf[int'(roff)-RX_OFF]};
    end

    // ---- SPI mode-0 byte engine ----
    // Half-period tick generator: SCK toggles every CLK_DIV clocks.
    localparam int DW = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV);
    logic [DW:0]     div;
    logic            tick;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div  <= '0;
            tick <= 1'b0;
        end else if (busy) begin
            if (div == (CLK_DIV[DW:0] - 1)) begin
                div  <= '0;
                tick <= 1'b1;
            end else begin
                div  <= div + 1'b1;
                tick <= 1'b0;
            end
        end else begin
            div  <= '0;
            tick <= 1'b0;
        end
    end

    typedef enum logic [1:0] { S_IDLE, S_XFER, S_FIN } state_e;
    state_e          state;
    logic [LENW-1:0] byte_i;
    logic [2:0]      bit_i;
    logic [7:0]      sh_tx;     // MSB-first shift-out (mosi = sh_tx[7])
    logic [7:0]      sh_rx;     // shift-in (full byte after 8 rising edges)

    assign mosi = sh_tx[7];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            sck    <= 1'b0;
            cs_n   <= 1'b1;
            busy   <= 1'b0;
            byte_i <= '0;
            bit_i  <= 3'd0;
            sh_tx  <= 8'h0;
            sh_rx  <= 8'h0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    sck <= 1'b0;
                    if (go && len != 0) begin
                        cs_n   <= 1'b0;
                        busy   <= 1'b1;
                        byte_i <= '0;
                        bit_i  <= 3'd0;
                        sh_tx  <= tx_buf[0];
                        sh_rx  <= 8'h0;
                        state  <= S_XFER;
                    end
                end
                S_XFER: if (tick) begin
                    if (!sck) begin
                        // rising edge: sample MISO into the shift register
                        sck   <= 1'b1;
                        sh_rx <= {sh_rx[6:0], miso};
                    end else begin
                        // falling edge: advance bit / byte
                        sck <= 1'b0;
                        if (bit_i == 3'd7) begin
                            rx_buf[byte_i] <= sh_rx;   // full byte captured
                            bit_i <= 3'd0;
                            if (byte_i == len - 1) begin
                                state <= S_FIN;
                            end else begin
                                sh_tx  <= tx_buf[byte_i + 1];
                                byte_i <= byte_i + 1'b1;
                            end
                        end else begin
                            sh_tx <= {sh_tx[6:0], 1'b0};
                            bit_i <= bit_i + 1'b1;
                        end
                    end
                end
                S_FIN: begin
                    sck  <= 1'b0;
                    cs_n <= cs_hold ? 1'b0 : 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
