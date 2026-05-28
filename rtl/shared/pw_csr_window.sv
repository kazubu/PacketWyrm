// PacketWyrm shadow + commit windowed CSR table.
//
// Generic, parameterisable: a window owns a contiguous AXI-Lite
// address range starting at WIN_BASE. Within it, the host writes
// one ROW_BYTES-sized row per index N at offset N*ROW_BYTES. A
// single write-1-to-commit register at WIN_BASE + COMMIT_OFFSET
// atomically promotes the staged "shadow" rows to the "live"
// output. Until commit, the live output keeps the previously
// committed values, so the data plane never observes a torn entry.
//
// The window is driven by a small decoded-write strobe from the
// owning AXI-Lite slave (see `pw_csr_full.sv`):
//
//   wr_en   1-cycle pulse for a committed AXI-Lite write
//   wr_addr the AXI-Lite byte address of the write
//   wr_data the AXI-Lite write data (32-bit)
//
// Outputs: `live_rows_o` exposes each row as a packed byte array
// (byte 0 in the low 8 bits) so downstream RTL can index byte-wise.
// `commit_pulse_o` ticks for one cycle on a successful commit.

`default_nettype none

module pw_csr_window #(
    parameter int ADDR_W   = 16,
    parameter int DEPTH    = 8,
    parameter int ROW_BYTES = 128,
    parameter logic [ADDR_W-1:0] WIN_BASE      = '0,
    parameter logic [ADDR_W-1:0] COMMIT_OFFSET = 16'h0FFC
) (
    input  wire                                clk,
    input  wire                                rst_n,

    input  wire                                wr_en,
    input  wire [ADDR_W-1:0]                   wr_addr,
    input  wire [31:0]                         wr_data,

    output logic [DEPTH-1:0][ROW_BYTES*8-1:0]  live_rows_o,
    output logic                               commit_pulse_o
);

    localparam int ROW_DW    = ROW_BYTES / 4;
    localparam int ROW_IDX_W = (DEPTH  > 1) ? $clog2(DEPTH)  : 1;
    localparam int OFF_DW_W  = (ROW_DW > 1) ? $clog2(ROW_DW) : 1;
    localparam int BYTE_W    = $clog2(ROW_BYTES);

    logic [DEPTH-1:0][ROW_DW-1:0][31:0] shadow;
    logic [DEPTH-1:0][ROW_DW-1:0][31:0] live;

    wire [ADDR_W-1:0] rel = wr_addr - WIN_BASE;
    wire              is_commit_reg = (wr_addr == (WIN_BASE + COMMIT_OFFSET));
    wire              is_row        = (wr_addr >= WIN_BASE) &&
                                      (rel < (DEPTH * ROW_BYTES));

    wire [ROW_IDX_W-1:0] row_idx = rel[BYTE_W +: ROW_IDX_W];
    wire [OFF_DW_W-1:0]  off_dw  = rel[2 +: OFF_DW_W];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow         <= '0;
            live           <= '0;
            commit_pulse_o <= 1'b0;
        end else begin
            commit_pulse_o <= 1'b0;
            if (wr_en && is_commit_reg) begin
                if (wr_data[0]) begin
                    live           <= shadow;
                    commit_pulse_o <= 1'b1;
                end
            end else if (wr_en && is_row) begin
                shadow[row_idx][off_dw] <= wr_data;
            end
        end
    end

    // Expose live rows as packed byte arrays (byte 0 in low bits).
    always_comb begin
        for (int r = 0; r < DEPTH; r++) begin
            for (int d = 0; d < ROW_DW; d++) begin
                live_rows_o[r][d*32 +: 32] = live[r][d];
            end
        end
    end

endmodule

`default_nettype wire
