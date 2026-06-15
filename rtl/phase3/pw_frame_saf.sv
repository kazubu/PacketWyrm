// PacketWyrm store-and-forward frame buffer (64-bit AXIS).
//
// Snoops a 64-bit AXIS RX stream into a beat FIFO and, one cycle after
// each frame's tlast, takes a routing decision: keep (enqueue for
// re-emission, tagged with an opaque route) or discard. Frames that do
// not fit are dropped whole (drop-on-overflow, like a real NIC ingress
// buffer) -- the beats written so far are rolled back, never partially
// emitted. The committed frames drain out as a clean AXIS master, each
// carrying its route tag for a downstream egress / punt arbiter.
//
// Why this exists: in the 64-bit streaming data plane the classifier's
// FORWARD_PORT / PUNT / MIRROR decision lands one cycle AFTER the
// frame's tlast (pw_parser_axis emits the key post-EOF). The frame has
// already streamed past, so re-emitting it requires having buffered it.
// TEST_RX / DROP need no buffer and never reach this block.
//
// TIMING CONTRACT: the decision (dec_valid_i) for a frame arrives
// exactly one cycle after that frame's tlast beat, and the next frame's
// first beat does NOT arrive in that same decision cycle (i.e. there is
// at least one idle/decision cycle between frames presented here). This
// holds for our MAC + CDC + flow generator, which never emit zero-gap
// back-to-back frames into the data plane, and mirrors the rest of the
// Phase 3 plane's "one event per cycle" simplifications.
//
// HEAD-OF-LINE: a single drain port per ingress. If the head frame's
// egress is congested, later frames behind it block. Acceptable for a
// test appliance (no VOQ); documented rather than engineered around.

`default_nettype none

module pw_frame_saf #(
    parameter int DEPTH_BEATS = 512,  // beat storage (x8 bytes); ~2.7 max frames at 512
    parameter int DESC_DEPTH  = 16,   // max frames in flight
    parameter int ROUTE_W     = 5     // opaque routing tag width
) (
    input  wire               clk,
    input  wire               rst_n,

    // Write / snoop side (no backpressure; whole-frame drop on overflow).
    input  wire [63:0]        s_tdata,
    input  wire [7:0]         s_tkeep,
    input  wire               s_tvalid,
    input  wire               s_tlast,

    // Per-frame decision, pulsed one cycle after the frame's tlast.
    input  wire               dec_valid_i,
    input  wire               dec_keep_i,            // 1 = enqueue, 0 = discard
    input  wire [ROUTE_W-1:0] dec_route_i,

    output logic              overflow_drop_o,       // pulse: a keep-frame dropped (full)

    // Drain side AXIS master (one frame at a time, FIFO order).
    output logic [63:0]       m_tdata,
    output logic [7:0]        m_tkeep,
    output logic              m_tvalid,
    input  wire               m_tready,
    output logic              m_tlast,
    output logic [ROUTE_W-1:0] m_route
);
    localparam int AW   = $clog2(DEPTH_BEATS);
    localparam int DAW  = $clog2(DESC_DEPTH);
    localparam int BEATW = 1 + 8 + 64;   // {tlast, tkeep, tdata}

    // --- beat storage ------------------------------------------------------
    logic [BEATW-1:0] mem [DEPTH_BEATS];

    // Pointers carry one extra MSB for full/empty disambiguation.
    logic [AW:0] rd_ptr;       // drain read pointer (committed region)
    logic [AW:0] wr_commit;    // last committed write pointer
    logic [AW:0] wr_spec;      // speculative write pointer (current frame)

    // Speculative occupancy (spec writes not yet committed count as used,
    // so we never overwrite undrained committed data). With (AW+1)-bit
    // pointers, used_spec spans 0..DEPTH_BEATS; == DEPTH_BEATS means full.
    wire [AW:0] used_spec = wr_spec - rd_ptr;
    wire        can_write = (used_spec != DEPTH_BEATS[AW:0]);

    logic       aborted;       // current frame overflowed -> will be dropped

    // --- descriptor FIFO (route per committed frame) -----------------------
    logic [ROUTE_W-1:0] desc_mem [DESC_DEPTH];
    logic [DAW:0]       desc_rd, desc_wr;
    wire  [DAW:0]       desc_used = desc_wr - desc_rd;
    wire                desc_empty = (desc_wr == desc_rd);
    wire                desc_full  = (desc_used == DESC_DEPTH[DAW:0]);

    // --- write / commit / rollback FSM -------------------------------------
    wire beat_we = s_tvalid && !aborted && can_write;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_commit       <= '0;
            wr_spec         <= '0;
            aborted         <= 1'b0;
            desc_wr         <= '0;
            overflow_drop_o <= 1'b0;
        end else begin
            overflow_drop_o <= 1'b0;

            // Speculative beat write for the in-progress frame.
            if (s_tvalid) begin
                if (beat_we) begin
                    mem[wr_spec[AW-1:0]] <= {s_tlast, s_tkeep, s_tdata};
                    wr_spec              <= wr_spec + 1'b1;
                end else begin
                    // No room -> this frame can no longer be emitted intact.
                    aborted <= 1'b1;
                end
            end

            // Decision lands one cycle after tlast. Commit or roll back the
            // whole speculative frame. (Per the timing contract no new beat
            // arrives this cycle, so wr_spec is stable here.)
            if (dec_valid_i) begin
                if (dec_keep_i && !aborted && !desc_full) begin
                    wr_commit                  <= wr_spec;      // publish frame
                    desc_mem[desc_wr[DAW-1:0]] <= dec_route_i;
                    desc_wr                    <= desc_wr + 1'b1;
                end else begin
                    wr_spec <= wr_commit;                       // drop: roll back
                    if (dec_keep_i && (aborted || desc_full))
                        overflow_drop_o <= 1'b1;
                end
                aborted <= 1'b0;
            end
        end
    end

    // --- drain / read side -------------------------------------------------
    wire [BEATW-1:0] head      = mem[rd_ptr[AW-1:0]];
    wire             head_last = head[BEATW-1];
    wire             committed_avail = (rd_ptr != wr_commit);

    assign m_tvalid = !desc_empty && committed_avail;
    assign m_tdata  = head[63:0];
    assign m_tkeep  = head[71:64];
    assign m_tlast  = head_last;
    assign m_route  = desc_empty ? '0 : desc_mem[desc_rd[DAW-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= '0;
            desc_rd <= '0;
        end else if (m_tvalid && m_tready) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (head_last)
                desc_rd <= desc_rd + 1'b1;   // frame fully drained
        end
    end

    // Tie off helper signals Verilator may flag as unused.
    wire _unused = &{1'b0, desc_used, 1'b0};

endmodule

`default_nettype wire
