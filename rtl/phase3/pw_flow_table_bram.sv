// BRAM-backed flow table for the multi-flow generator.
//
// Replaces the registered 32-wide decoded flow table (pw_flow_window's
// flow_rows_o) that fanned out into every egress generator and forced a
// 32:1 wide mux per generator (the route-heavy, LUT-hungry path). Instead:
//
//   * The CSR shadow/commit staging is unchanged (pw_csr_window).
//   * On commit, a single decoder WALKS the committed rows once (one row per
//     cycle) and writes the decoded pw_flow_row_t into a block-RAM (one copy
//     per egress port so each generator gets an independent read port), plus a
//     small per-slot SCHEDULING descriptor (valid / egress / tokens / cap /
//     cost) into a flip-flop array.
//   * Each generator schedules from the compact flow_sched_o[] array (all slots
//     visible every cycle) and reads ONLY its picked slot's wide row content
//     from BRAM via rd_addr_i / rd_row_o (registered, 1-cycle latency -- the
//     same latency the old f_rows_i[pick] register mux had).
//
// Net: the wide decode happens once (not x32 in parallel), the 32-deep
// pw_flow_row_t register array and its wide fan-out are gone, and the
// generator's 32:1 row mux becomes a BRAM read. cost/cap are precomputed here
// (Q16.16) so the generator no longer computes frame_bytes.
//
// Commit transient: the walk takes DEPTH cycles; a slot's sched + BRAM update
// on the cycle it is walked, so for ~DEPTH cycles after a commit the table is a
// mix of old/new rows. Configs are committed before a run, so this is benign
// (matches the old "commit takes effect ~1 cycle later" contract, just wider).

`default_nettype none

import pw_axis_pkg::*;

module pw_flow_table_bram #(
    parameter int ADDR_W   = 16,
    parameter int DEPTH    = 32,
    parameter int PORTS    = 2,                 // independent generator read ports
    parameter int FRAME_LEN_PAYLOAD = 32,       // L4 payload (for the token cost)
    parameter logic [ADDR_W-1:0] WIN_BASE      = 16'h2000,
    parameter logic [ADDR_W-1:0] COMMIT_OFFSET = 16'h0FFC
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [31:0]           wr_data,

    // Compact per-slot scheduling descriptors (registered; all slots).
    output pw_flow_sched_t       flow_sched_o [DEPTH],

    // Per-generator wide-row read port (registered, 1-cycle latency).
    input  wire  [$clog2(DEPTH)-1:0] rd_addr_i [PORTS],
    output pw_flow_row_t             rd_row_o  [PORTS],

    output logic                 commit_pulse_o
);
    localparam int IDXW      = $clog2(DEPTH);
    localparam int ROW_BYTES = PW_FLOW_ROW_BYTES;

    // --- CSR shadow/commit staging (unchanged) -----------------------------
    logic [DEPTH-1:0][ROW_BYTES*8-1:0] live_rows;
    logic                              commit_pulse;
    assign commit_pulse_o = commit_pulse;

    pw_csr_window #(
        .ADDR_W        (ADDR_W),
        .DEPTH         (DEPTH),
        .ROW_BYTES     (ROW_BYTES),
        .WIN_BASE      (WIN_BASE),
        .COMMIT_OFFSET (COMMIT_OFFSET)
    ) u_win (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .live_rows_o    (live_rows),
        .commit_pulse_o (commit_pulse)
    );

    // --- commit walk: decode one committed row per cycle -------------------
    // live_rows is promoted on commit_pulse; start the walk the next cycle.
    logic            walking;
    logic [IDXW:0]   widx;          // 0..DEPTH (DEPTH = done)
    pw_flow_row_t    wrow;          // decoded row being written this cycle
    logic            wwe;           // BRAM write-enable for this cycle
    logic [IDXW-1:0] waddr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            walking <= 1'b0; widx <= '0;
        end else begin
            if (commit_pulse) begin
                walking <= 1'b1; widx <= '0;
            end else if (walking) begin
                if (widx == IDXW'(DEPTH-1) || widx == (DEPTH)) walking <= 1'b0;
                widx <= widx + 1'b1;
            end
        end
    end

    // Decode the row currently addressed by the walk (combinational, single
    // decoder instance) and register the scheduling descriptor.
    always_comb begin
        waddr = widx[IDXW-1:0];
        wrow  = pw_decode_flow_row(live_rows[waddr]);
        wwe   = walking;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < DEPTH; s++) flow_sched_o[s] <= '0;
        end else if (wwe) begin
            flow_sched_o[waddr].valid     <= wrow.valid;
            flow_sched_o[waddr].egress    <= wrow.egress;
            flow_sched_o[waddr].tokens_fp <= wrow.tokens_fp;
            flow_sched_o[waddr].cap       <= {wrow.burst, 16'h0};
            flow_sched_o[waddr].cost      <= {16'(pw_frame_bytes(wrow, FRAME_LEN_PAYLOAD)), 16'h0};
        end
    end

    // --- BRAM holding the decoded wide rows, one copy per read port --------
    // Replicated per generator so each gets an independent (write-walk +
    // read-pick) simple-dual-port block RAM -- no read arbitration. Stored as a
    // flat bit-vector (not a struct array) and read into an internal register
    // (not the output port) -- both are required for clean block-RAM inference.
    localparam int ROWBITS = $bits(pw_flow_row_t);
    wire [ROWBITS-1:0] wrow_bits = wrow;
    generate
        for (genvar p = 0; p < PORTS; p++) begin : g_bank
            (* ram_style = "block" *) logic [ROWBITS-1:0] mem [DEPTH];
            logic [ROWBITS-1:0] rd_q;
            always_ff @(posedge clk) begin
                if (wwe) mem[waddr] <= wrow_bits;     // write (commit walk)
                rd_q <= mem[rd_addr_i[p]];            // read (generator pick)
            end
            assign rd_row_o[p] = pw_flow_row_t'(rd_q);
        end
    endgenerate

endmodule

`default_nettype wire
