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
    localparam int WORDS  = BUF_BYTES / 4;
    localparam int WAW    = $clog2(WORDS);

    // TX/RX buffers as 32-bit-word BLOCK RAM (the host accesses them a dword at a
    // time, and the byte engine streams bytes sequentially). This replaces two
    // 512-byte register arrays whose byte-indexed read/write muxes cost ~10k LUT
    // -- block RAM is ~free here and the SPI clock is clk/(2*CLK_DIV) so the
    // 1-cycle BRAM latency is trivially absorbed.
    (* ram_style = "block" *) logic [31:0] tx_mem [WORDS];
    (* ram_style = "block" *) logic [31:0] rx_mem [WORDS];
    logic [LENW-1:0] len;
    logic            cs_hold;
    logic            go;
    logic            busy;

    // ---- CSR writes (dword into the TX word RAM) ----
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
                    tx_mem[(woff - TX_OFF) >> 2] <= wr_data;
                end
            end
        end
    end

    // ---- CSR reads (registered, 1-cycle: rx_mem BRAM read + status mux). The
    // CSR (pw_csr_full) gives the SPI window a one-cycle pending read, like the
    // histogram / punt windows. ----
    wire [15:0]    roff   = rd_addr - WIN_BASE;
    wire [WAW-1:0] rx_wsel = (roff >= RX_OFF) ? (roff - RX_OFF) >> 2 : '0;
    logic [15:0]   roff_q;
    logic [31:0]   rx_rd;
    always_ff @(posedge clk) begin
        roff_q <= roff;
        rx_rd  <= rx_mem[rx_wsel];
    end
    always_comb begin
        rd_data = 32'h0;
        if      (roff_q == 16'h000) rd_data = {31'h0, busy};
        else if (roff_q == 16'h004) rd_data = {{(32-LENW){1'b0}}, len};
        else if (roff_q >= RX_OFF && roff_q < RX_OFF + BUF_BYTES) rd_data = rx_rd;
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
    logic [7:0]      sh_rx;     // shift-in (full byte after 8 rising edges)
    logic [31:0]     rxw;       // RX word accumulator (written to rx_mem per word)

    // TX: drive MOSI by a direct bit-select of the current word (registered BRAM
    // read of tx_mem[cur_word]). The 1-cycle BRAM read latency on a word crossing
    // is harmless: MOSI is only sampled at the SCK rising edge, which is CLK_DIV
    // cycles after the byte advance, long after txw has settled. byte within the
    // word = byte_i[1:0]; bit MSB-first = 7-bit_i.
    wire [WAW-1:0] cur_word = byte_i[LENW-1:2];
    logic [31:0]   txw;
    always_ff @(posedge clk) txw <= tx_mem[cur_word];
    wire [4:0] mosi_bit = {byte_i[1:0], 3'b0} + (5'd7 - {2'b0, bit_i});
    assign mosi = txw[mosi_bit];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            sck    <= 1'b0;
            cs_n   <= 1'b1;
            busy   <= 1'b0;
            byte_i <= '0;
            bit_i  <= 3'd0;
            sh_rx  <= 8'h0;
            rxw    <= 32'h0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    sck <= 1'b0;
                    if (go && len != 0) begin
                        cs_n   <= 1'b0;
                        busy   <= 1'b1;
                        byte_i <= '0;
                        bit_i  <= 3'd0;
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
                            // assemble the just-finished byte into the RX word and
                            // flush the word to BRAM when it fills (or on the last
                            // byte -- a partial last word's high bytes are unread).
                            automatic logic [31:0] rxw_n = rxw;
                            rxw_n[byte_i[1:0]*8 +: 8] = sh_rx;
                            rxw <= rxw_n;
                            if (byte_i[1:0] == 2'd3 || byte_i == len - 1)
                                rx_mem[cur_word] <= rxw_n;
                            bit_i <= 3'd0;
                            if (byte_i == len - 1) state  <= S_FIN;
                            else                   byte_i <= byte_i + 1'b1;
                        end else begin
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
