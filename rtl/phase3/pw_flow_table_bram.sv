// BRAM-backed flow table for the multi-flow generator.
//
// Replaces the registered 32-wide decoded flow table (pw_flow_window's
// flow_rows_o) that fanned out into every egress generator and forced a
// 32:1 wide mux per generator (the route-heavy, LUT-hungry path). Instead:
//
//   * The CSR staging is a 32-bit-word block RAM (NOT a register double-buffer).
//     The host writes one 32-bit word per CSR write at offset N*ROW_BYTES + w*4.
//   * On commit, a word-serial walk reads the staging BRAM (one 32-bit word per
//     cycle), reassembles each ROW_BYTES row, decodes it ONCE (a single
//     pw_decode_flow_row instance), and writes the decoded pw_flow_row_t into a
//     per-egress-port block-RAM plus a small per-slot SCHEDULING descriptor
//     (valid / egress / tokens / cap / cost) into a flip-flop array.
//   * Each generator schedules from the compact flow_sched_o[] array (all slots
//     visible every cycle) and reads ONLY its picked slot's wide row content
//     from BRAM via rd_addr_i / rd_row_o (registered, 1-cycle latency -- the
//     same latency the old f_rows_i[pick] register mux had).
//
// Net: the wide decode happens once (not x32 in parallel), the 32-deep
// pw_flow_row_t register array and its wide fan-out are gone, AND the CSR
// staging that used to be a shadow+live register double-buffer (pw_csr_window:
// ~94 K FFs read by a 32:1 x 2048-bit `live_rows[waddr]` mux, ~17 K LUT) is now
// a block RAM read by the word-serial walk. That register file + wide mux was
// the dominant LUT/FF cost of this module; staging it in BRAM frees it the same
// way the checker and SPI-flash register arrays were moved to BRAM. The CSR
// address map / commit register / wire model are unchanged, so software is
// unaffected.
//
// Commit transient: the walk now takes DEPTH*ROW_DW cycles (one 32-bit word per
// cycle) plus a few pipeline cycles -- ~13 us for 32x256 B at 156.25 MHz. A
// slot's sched + BRAM row update on the cycle its last word is assembled, so for
// the duration of the walk the table is a mix of old/new rows. Configs are
// committed before a run, so this is benign (same "commit takes effect shortly
// after" contract as before, just a wider window). The per-port row BRAM is the
// live store the generators read; it is only rewritten during the walk.

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

    // Pulses for ONE cycle when a commit is ACCEPTED and the walk BEGINS -- NOT
    // when the live table is fully updated (the walk then takes DEPTH*ROW_DW
    // cycles, during which the per-port row BRAM is a mix of old/new rows). A
    // consumer that needs "new table fully live" must wait the walk duration (or
    // a future commit_done_o would be needed); today this is unconnected.
    output logic                 commit_pulse_o
);
    localparam int IDXW      = (DEPTH  > 1) ? $clog2(DEPTH) : 1;
    localparam int ROW_BYTES = PW_FLOW_ROW_BYTES;
    localparam int ROW_DW    = ROW_BYTES / 4;        // 32-bit words per row
    localparam int WORD_W    = $clog2(ROW_DW);        // word index within a row
    localparam int NWORDS    = DEPTH * ROW_DW;        // staging BRAM depth
    localparam int WADDR_W   = $clog2(NWORDS);
    localparam int ROWBITS   = $bits(pw_flow_row_t);

    // --- CSR staging: a 32-bit-word block RAM (write = host CSR word writes) ---
    // Address decode mirrors the old pw_csr_window: a row N occupies the byte
    // range [WIN_BASE + N*ROW_BYTES, +ROW_BYTES); word w of row N is at byte
    // offset N*ROW_BYTES + w*4, i.e. flat word index N*ROW_DW + w = rel >> 2.
    (* ram_style = "block" *) logic [31:0] stg [NWORDS];
    // Zero-init the staging so an unwritten row decodes inert (valid=0) at
    // POWER-ON / config-load (Vivado defaults inferred block RAM to 0; make it
    // explicit). NOTE: `initial` does NOT fire on a logic reset (rst_n) -- block
    // RAM has no async reset -- so a bare reset leaves the pre-reset bytes here.
    // The post-reset inert contract is enforced instead by the `word_written`
    // guard below (the commit walk forces any row not (re)written since reset to
    // valid=0), so stale staging bytes can never become a live flow.
    initial begin
        for (int i = 0; i < NWORDS; i++) stg[i] = '0;
    end

    wire [ADDR_W-1:0] rel           = wr_addr - WIN_BASE;
    wire              is_commit_reg = (wr_addr == (WIN_BASE + COMMIT_OFFSET));
    wire              is_row        = (wr_addr >= WIN_BASE) &&
                                      (rel < (DEPTH * ROW_BYTES));
    wire [WADDR_W-1:0] wword        = rel[2 +: WADDR_W];

    // --- commit-walk FSM -----------------------------------------------------
    // walking issues sequential staging reads; the read data (1-cycle BRAM
    // latency) is reassembled into one row, then decoded + written to the
    // per-port row BRAM + the sched descriptor at each row boundary.
    logic                    commit_req;
    logic                    walking;
    // Per-WORD "written since the last reset" guard. The `initial` zeroes the BRAM
    // only at power-on/config-load; a logic reset (rst_n) does NOT re-zero block
    // RAM, so the staging keeps its pre-reset bytes. Without a guard, a commit
    // after a bare reset would walk those stale bytes in as live rows (the old
    // pw_csr_window zeroed its whole shadow on reset, so every UNWRITTEN WORD read
    // back as 0). We replicate that exactly: a 1-bit/word flag, reset to 0, set on
    // each CSR word write; the commit walk substitutes 0 for any word not (re)-
    // written since reset when reassembling the row, so a fully-unwritten row
    // decodes inert (valid=0) and a partially-written row sees zeros for its
    // untouched words -- bit-identical to the old zero-shadow contract (not just
    // row-granular). NWORDS FFs (~2K for DEPTH=32); no post-reset programming delay.
    logic [NWORDS-1:0]       word_written;
    logic [WADDR_W:0]        rd_ptr;        // 0..NWORDS (NWORDS = all issued)
    logic [31:0]             stg_q;         // registered staging read data
    logic                    ww_q;          // word_written for stg_q (aligned)
    logic [WADDR_W:0]        rd_ptr_d;      // addr that stg_q corresponds to
    logic                    rd_vld_d;      // stg_q holds a valid staging word

    logic [ROW_DW-1:0][31:0] row_acc;       // row being assembled (one row)
    logic                    row_done;      // row_acc holds a complete row
    logic [IDXW-1:0]         row_idx;       // which flow slot row_acc is for

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            commit_req <= 1'b0; walking <= 1'b0; rd_ptr <= '0;
            rd_ptr_d <= '0; rd_vld_d <= 1'b0; row_done <= 1'b0;
            row_idx <= '0; commit_pulse_o <= 1'b0;
            word_written <= '0;  // every word reads back 0 until (re)written after reset
        end else begin
            commit_pulse_o <= 1'b0;
            row_done       <= 1'b0;

            // mark each staging word the host writes (cleared only by reset)
            if (wr_en && is_row) word_written[wword] <= 1'b1;

            // latch a commit request (write-1 to the commit register)
            if (wr_en && is_commit_reg && wr_data[0]) commit_req <= 1'b1;

            // start / advance the walk
            if (!walking) begin
                if (commit_req) begin
                    walking        <= 1'b1;
                    commit_req     <= 1'b0;
                    rd_ptr         <= '0;
                    commit_pulse_o <= 1'b1;   // commit accepted; walk BEGINS (not "live"; see port decl)
                end
            end else begin
                if (rd_ptr == (WADDR_W+1)'(NWORDS)) walking <= 1'b0;
                else rd_ptr <= rd_ptr + 1'b1;
            end

            // staging read pipeline (BRAM has 1-cycle latency). Unconditional
            // read keeps inference clean; rd_vld_d gates the use of stg_q. ww_q
            // tracks word_written for the same word so the assemble below can
            // substitute 0 for any word not written since reset.
            stg_q    <= stg[rd_ptr[WADDR_W-1:0]];
            ww_q     <= word_written[rd_ptr[WADDR_W-1:0]];
            rd_ptr_d <= rd_ptr;
            rd_vld_d <= walking && (rd_ptr < (WADDR_W+1)'(NWORDS));

            // reassemble the row; a word not written since reset reads back as 0
            // (the old zero-shadow contract). Flag completion at the last word.
            if (rd_vld_d) begin
                row_acc[rd_ptr_d[WORD_W-1:0]] <= ww_q ? stg_q : 32'h0;
                if (rd_ptr_d[WORD_W-1:0] == WORD_W'(ROW_DW-1)) begin
                    row_done <= 1'b1;                       // row_acc complete next cycle
                    row_idx  <= rd_ptr_d[WADDR_W-1:WORD_W];
                end
            end
        end
    end

    // staging write port (host CSR). Same clk block as the read above would
    // create a true SDP; keep writes in their own block for clarity -- the two
    // never address-collide in practice (host writes, then commits, then walk).
    always_ff @(posedge clk) begin
        if (wr_en && is_row) stg[wword] <= wr_data;
    end

    // --- decode the assembled row (single decoder instance) ------------------
    logic [ROW_BYTES*8-1:0] rowflat;
    pw_flow_row_t           wrow;
    always_comb begin
        for (int d = 0; d < ROW_DW; d++) rowflat[d*32 +: 32] = row_acc[d];
        wrow = pw_decode_flow_row(rowflat);
    end
    wire [ROWBITS-1:0] wrow_bits = wrow;
    // No row-level gate needed: unwritten words were already zeroed into row_acc
    // (word_written), so an unwritten/partial row decodes inert exactly as the old
    // zero-shadow would have.

    // --- scheduling descriptor (registered) ----------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < DEPTH; s++) flow_sched_o[s] <= '0;
        end else if (row_done) begin
            // Token cost meters by the smallest legal frame of this flow: the
            // minimum-payload frame, or the configured frame_len_min if larger.
            // Exact for a fixed size (RFC2544, min==max); a min<max sweep meters
            // by min (slight over-rate on the larger frames -- IMIX only).
            // TEST reserves a 32-byte test-header payload region; raw templates
            // have no test header, so their minimum-payload frame is header-only
            // (payload floor 0). pw_frame_bytes is template-aware.
            automatic int test_pl    = (wrow.frame_template == 2'd0)
                                       ? FRAME_LEN_PAYLOAD : 0;
            automatic int min_legal  = pw_frame_bytes(wrow, test_pl);
            automatic int cfg_min    = int'(wrow.frame_len_min);
            automatic int cost_b     = (cfg_min > min_legal) ? cfg_min : min_legal;
            flow_sched_o[row_idx].valid     <= wrow.valid;
            flow_sched_o[row_idx].egress    <= wrow.egress;
            flow_sched_o[row_idx].tokens_fp <= wrow.tokens_fp;
            flow_sched_o[row_idx].cap       <= {wrow.burst, 16'h0};
            flow_sched_o[row_idx].cost      <= {16'(cost_b), 16'h0};
            flow_sched_o[row_idx].len_min   <= wrow.frame_len_min;
            flow_sched_o[row_idx].len_max   <= wrow.frame_len_max;
            flow_sched_o[row_idx].len_step  <= wrow.frame_len_step;
            flow_sched_o[row_idx].ovh       <= 12'(pw_frame_bytes(wrow, 0));
            flow_sched_o[row_idx].frame_template <= wrow.frame_template;
        end
    end

    // --- BRAM holding the decoded wide rows, one copy per read port ----------
    // Replicated per generator so each gets an independent (write-walk +
    // read-pick) simple-dual-port block RAM -- no read arbitration. Stored as a
    // flat bit-vector (not a struct array) and read into an internal register
    // (not the output port) -- both are required for clean block-RAM inference.
    generate
        for (genvar p = 0; p < PORTS; p++) begin : g_bank
            (* ram_style = "block" *) logic [ROWBITS-1:0] mem [DEPTH];
            logic [ROWBITS-1:0] rd_q;
            always_ff @(posedge clk) begin
                if (row_done) mem[row_idx] <= wrow_bits;   // write (commit walk)
                rd_q <= mem[rd_addr_i[p]];                 // read (generator pick)
            end
            assign rd_row_o[p] = pw_flow_row_t'(rd_q);
        end
    endgenerate

endmodule

`default_nettype wire
