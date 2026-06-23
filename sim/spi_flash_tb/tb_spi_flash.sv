// Testbench for pw_spi_flash: the CSR-driven x1 SPI master engine.
//
// Two checks:
//   1. Loopback (miso tied to mosi): proves the byte engine shifts LEN
//      bytes MSB-first and captures them -- RX buffer must equal TX.
//   2. A small behavioral SPI-flash model (mode 0): WREN / page-program /
//      read-back through the CSR, proving the host-style command flow.
//
// The behavioral model drives MISO combinationally from its (fbyte,fbit)
// receive counters, so there is no master/slave edge race in the model.

`default_nettype none

module tb_spi_flash;

    localparam logic [15:0] WIN  = 16'h0800;
    localparam int          BUF  = 512;
    localparam int          DIV  = 2;
    localparam logic [15:0] CTRL = WIN + 16'h000;
    localparam logic [15:0] LEN  = WIN + 16'h004;
    localparam logic [15:0] TXB  = WIN + 16'h100;
    localparam logic [15:0] RXB  = WIN + 16'h100 + BUF;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic        wr_en;
    logic [15:0] wr_addr, rd_addr;
    logic [31:0] wr_data, rd_data;
    logic        sck, cs_n, mosi, miso;

    logic        loopback = 1;
    logic        miso_model;
    assign miso = loopback ? mosi : miso_model;

    pw_spi_flash #(.WIN_BASE(WIN), .BUF_BYTES(BUF), .CLK_DIV(DIV)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    // ---- behavioral x1 SPI flash model (mode 0, 1 KB) ----
    logic [7:0] fmem [0:1023];
    logic [7:0] in_sh;
    int         fbit, fbyte;
    logic [7:0] fcmd;
    logic [9:0] faddr, read_base;
    logic       fwel;

    always @(negedge cs_n) begin fbit = 0; fbyte = 0; in_sh = 0; end

    always @(posedge sck) if (!cs_n) begin
        logic [7:0] b;
        b     = {in_sh[6:0], mosi};   // assembled byte when fbit==7
        in_sh = {in_sh[6:0], mosi};
        if (fbit == 7) begin
            case (fbyte)
                0: begin fcmd = b; if (b == 8'h06) fwel = 1'b1; end
                1: ;                       // addr[23:16] -- ignored (1 KB model)
                2: faddr[9:8] = b[1:0];
                3: begin faddr[7:0] = b; read_base = faddr; end
                default: if (fcmd == 8'h02 && fwel) begin
                             fmem[faddr] = b; faddr = faddr + 1'b1;
                         end
            endcase
            fbit = 0; fbyte = fbyte + 1;
        end else begin
            fbit = fbit + 1;
        end
    end

    // MISO driven combinationally from the receive position.
    logic [7:0] rd_byte;
    always_comb begin
        rd_byte = 8'h00;
        if (fcmd == 8'h03 && fbyte >= 4)
            rd_byte = fmem[read_base + 10'(fbyte - 4)];
        else if (fcmd == 8'h05)            // RDSR: WIP=0, WEL=fwel
            rd_byte = {6'h0, fwel, 1'b0};
        miso_model = rd_byte[7 - fbit];
    end

    // ---- CSR helpers ----
    task automatic csr_wr(input logic [15:0] a, input logic [31:0] d);
        @(posedge clk); wr_en = 1; wr_addr = a; wr_data = d;
        @(posedge clk); wr_en = 0;
    endtask
    task automatic csr_rd(input logic [15:0] a, output logic [31:0] d);
        // rd_data is now a registered (1-cycle) read: rx buffer is block RAM and
        // the status mux is registered (the real CSR captures it via spi_pend).
        rd_addr = a; @(posedge clk); #1; d = rd_data;
    endtask

    task automatic spi_xfer(input logic [7:0] tx [512], input int n, input bit cshold);
        logic [31:0] d, st;
        for (int i = 0; i < n; i += 4) begin
            d = 0;
            for (int k = 0; k < 4; k++) if (i + k < n) d[k*8 +: 8] = tx[i + k];
            csr_wr(TXB + 16'(i), d);
        end
        csr_wr(LEN, 32'(n));
        csr_wr(CTRL, {30'h0, cshold, 1'b1});
        repeat (3) @(posedge clk);
        do begin @(posedge clk); csr_rd(CTRL, st); end while (st[0]);
    endtask

    task automatic spi_rx(input int i, output logic [7:0] b);
        logic [31:0] d;
        csr_rd(RXB + 16'(i & 32'hFFFC), d);
        b = d[(i % 4) * 8 +: 8];
    endtask

    int errors = 0;
    task automatic chk(string what, longint g, longint e);
        if (g !== e) begin $display("[FAIL] %s: got=%0d exp=%0d", what, g, e); errors++; end
        else           $display("[ ok ] %s: %0d", what, g);
    endtask

    logic [7:0] tx [512];

    initial begin
        wr_en = 0; wr_addr = 0; wr_data = 0; rd_addr = 0;
        fwel = 0; fbit = 0; fbyte = 0; fcmd = 0; faddr = 0; in_sh = 0;
        for (int i = 0; i < 1024; i++) fmem[i] = 8'h00;
        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---- scenario 1: loopback ----
        loopback = 1;
        for (int i = 0; i < 8; i++) tx[i] = 8'(8'hA0 + i);
        spi_xfer(tx, 8, 1'b0);
        begin logic [7:0] b; int ne = 0;
            for (int i = 0; i < 8; i++) begin spi_rx(i, b); if (b == 8'(8'hA0 + i)) ne++; end
            chk("loopback rx==tx (8 bytes)", ne, 8);
        end

        // ---- scenario 2: flash model -- page program then read back ----
        loopback = 0;
        tx[0] = 8'h06; spi_xfer(tx, 1, 1'b0);                 // WREN
        tx[0] = 8'h02; tx[1] = 8'h00; tx[2] = 8'h00; tx[3] = 8'h10;
        tx[4] = 8'hDE; tx[5] = 8'hAD; tx[6] = 8'hBE; tx[7] = 8'hEF;
        spi_xfer(tx, 8, 1'b0);                                // PAGE PROGRAM @0x010
        tx[0] = 8'h03; tx[1] = 8'h00; tx[2] = 8'h00; tx[3] = 8'h10;
        tx[4] = 0; tx[5] = 0; tx[6] = 0; tx[7] = 0;
        spi_xfer(tx, 8, 1'b0);                                // READ @0x010
        begin logic [7:0] b0,b1,b2,b3;
            spi_rx(4, b0); spi_rx(5, b1); spi_rx(6, b2); spi_rx(7, b3);
            chk("read back [0] DE", b0, 8'hDE);
            chk("read back [1] AD", b1, 8'hAD);
            chk("read back [2] BE", b2, 8'hBE);
            chk("read back [3] EF", b3, 8'hEF);
        end

        if (errors == 0) $display("ALL SPI_FLASH SCENARIOS PASS");
        else             $display("SPI_FLASH FAILURES: %0d", errors);
        $finish;
    end

    initial begin #2000000; $display("WATCHDOG"); $fatal; end

endmodule

`default_nettype wire
