// PacketWyrm test-packet RX checker -- BRAM-backed per-flow state.
//
// Functionally identical to pw_test_rx_checker (PIPELINE=1): one
// classification event per cycle (event_valid && TEST_RX), updating
// per-flow rx_frames / lost / duplicate / out_of_order / last_seq,
// latency min/max/sum/samples, and RFC-3393 IPDV jitter min/max/sum.
//
// The difference: the per-flow state lives in a BRAM record table
// instead of NUM_FLOWS-wide flip-flop arrays. This frees the wide
// per-flow update muxes (LUT) off the dp_clk wall and lifts the flow
// ceiling (BRAM is plentiful; FF/LUT were the limit). The histogram
// already moved to BRAM (pw_lat_histogram); this completes the move.
//
// Pipeline (mirrors the PIPELINE=1 path):
//   stage 0 (event): issue the record read (port A) at the event's flow
//     index; register {valid, idx, seq, latency, bucket}.
//   stage 1 (RMW):   the record is back from BRAM; apply the update and
//     write it back (port A). A same-flow back-to-back bypass forwards
//     the just-written record (TEST_RX events to one flow are normally
//     >= ~10 cycles apart, so this only guards the degenerate case).
//
// Snapshot read uses a second BRAM port (port B): rd_addr_i -> the
// record fields, registered (1-cycle latency). pw_stats_snapshot walks
// 0..NUM_FLOWS-1 on its trigger to copy the live records into its shadow.
//
// Per-flow latency/jitter min/max are 32-bit (a single sample/delta
// never approaches 2^32 ns); sums and counters stay 64-bit.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_test_rx_checker_bram #(
    parameter int NUM_FLOWS   = 16,
    parameter int NUM_BUCKETS = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  clear_i,

    input  wire [63:0]           timestamp_i,
    // Signed cross-card latency correction (two's complement), added to the RX
    // "now" before the tx-stamp subtract: lat = (timestamp_i + lat_correction_i)
    // - tx_ts. On an RX card it carries the inter-card counter offset (A_cnt -
    // B_cnt) so rx_wire_ts_B is re-expressed in the TX card's timebase and HW
    // accumulates the TRUE one-way latency per sample (min/max/sum/histogram all
    // corrected -> no SW post-hoc skew smear). 0 for same-card flows (default) ->
    // bit-identical to the uncorrected path. The free-running counter itself is
    // NEVER disciplined (Gray-CDC safe); only this computation is corrected.
    // The corrected result is clamped to [0, 2^32-1] before it feeds the 32-bit
    // min/max/jitter/histogram: a residual over-correction can make it slightly
    // negative, which would otherwise wrap to ~0xFFFFFFFF in the unsigned low-32
    // truncation. (A negative sample thus reads as 0 latency, not garbage.)
    input  wire [63:0]           lat_correction_i,
    input  pw_match_key_t        key_i,
    input  pw_class_result_t     result_i,
    input  wire                  event_valid_i,
    // Received L2 frame byte length for THIS event, aligned with the event like
    // timestamp_i. Accumulated per flow into rx_bytes (every classified frame,
    // test or not -- same gating as rx_frames) so a client can compute rx bps.
    input  wire [15:0]           byte_len_i,

    // Registered histogram event (always driven), as in pw_test_rx_checker.
    output logic                 hist_ev_o,
    output logic [15:0]          hist_flow_o,
    output logic [15:0]          hist_bucket_o,

    // 1-cycle pulse when this event increments the per-flow lost count (a
    // sequence gap = missing frames). Feeds the front-panel health LED's
    // sticky-error latch in the data plane. Registered alongside the RMW.
    output logic                 lost_event_o,

    // Snapshot read port (port B). Drive rd_addr_i; the record fields are
    // valid 1 cycle later (rd_valid_o pulses to mark it).
    input  wire [$clog2(NUM_FLOWS)-1:0] rd_addr_i,
    input  wire                  rd_en_i,
    output logic                 rd_valid_o,
    output logic [63:0]          rd_rx_frames_o,
    output logic [63:0]          rd_rx_bytes_o,
    output logic [63:0]          rd_lost_o,
    output logic [63:0]          rd_duplicate_o,
    output logic [63:0]          rd_out_of_order_o,
    output logic [63:0]          rd_last_seq_o,
    output logic [63:0]          rd_min_latency_o,
    output logic [63:0]          rd_max_latency_o,
    output logic [63:0]          rd_sum_latency_o,
    output logic [63:0]          rd_sample_count_o,
    output logic [63:0]          rd_jitter_min_o,
    output logic [63:0]          rd_jitter_max_o,
    output logic [63:0]          rd_jitter_sum_o
);

    // ---- record layout (flat bit-vector for clean BRAM inference) ----
    localparam int OFF_EXP   = 0;     // expected_seq   (64)
    localparam int OFF_LAST  = 64;    // last_seq       (64)
    localparam int OFF_LOST  = 128;   // lost           (64)
    localparam int OFF_DUP   = 192;   // duplicate      (64)
    localparam int OFF_OOO   = 256;   // out_of_order   (64)
    localparam int OFF_RXF   = 320;   // rx_frames      (64)
    localparam int OFF_SUML  = 384;   // sum_latency    (64)
    localparam int OFF_SAMP  = 448;   // sample_count   (64)
    localparam int OFF_JSUM  = 512;   // jitter_sum     (64)
    localparam int OFF_MINL  = 576;   // min_latency    (32)
    localparam int OFF_MAXL  = 608;   // max_latency    (32)
    localparam int OFF_JMIN  = 640;   // jitter_min     (32)
    localparam int OFF_JMAX  = 672;   // jitter_max     (32)
    localparam int OFF_PREVL = 704;   // prev_latency   (32)
    localparam int OFF_SEEN  = 736;   // flow_seen      (1)
    localparam int OFF_RXB   = 737;   // rx_bytes       (64)
    localparam int REC_W     = 801;
    localparam int AW        = $clog2(NUM_FLOWS);

    // A freshly-cleared record: latency/jitter min seeded to all-ones, the
    // rest zero, flow_seen = 0.
    function automatic logic [REC_W-1:0] blank_rec();
        logic [REC_W-1:0] r;
        r = '0;
        r[OFF_MINL +: 32] = 32'hFFFF_FFFF;
        r[OFF_JMIN +: 32] = 32'hFFFF_FFFF;
        return r;
    endfunction

    (* ram_style = "block" *) logic [REC_W-1:0] mem [NUM_FLOWS];

    // ---- port A: RMW (event path) ----
    logic [REC_W-1:0] a_rd_q;        // record read for the event in flight
    logic             a_we;
    logic [AW-1:0]    a_waddr;
    logic [REC_W-1:0] a_wdata;
    logic [AW-1:0]    a_raddr;

    // ---- port B: snapshot read ----
    logic [REC_W-1:0] b_rd_q;

    // log2 bucket for the histogram event.
    function automatic int log2_bucket(input logic [63:0] x);
        int b; b = 0;
        for (int i = 0; i < 64; i++) if (x[i]) b = i;
        return b;
    endfunction

    // ---- clear walk: BRAM has no async reset, so walk it writing blanks ----
    logic            clearing;
    logic [AW:0]     clear_idx;
    wire             clear_busy = clearing;

    // ---- stage 0: event decode + issue port-A read ----
    // A classified TEST_RX frame is counted whether or not it carries a
    // PacketWyrm test header. With a test header (is_test) we also derive
    // sequence (loss/dup/ooo) and latency/jitter; without one (e.g. a
    // header-defined flow with arbitrary payload, classified by the generic
    // slice classifier) we count rx_frames only -- loss is then the tx-vs-rx
    // count difference. The is_test path is bit-for-bit unchanged.
    wire event_take = event_valid_i && result_i.hit &&
                      result_i.action == PW_ACT_TEST_RX &&
                      result_i.local_flow_id < NUM_FLOWS;

    logic                          s1_valid;
    logic                          s1_is_test;
    logic [AW-1:0]                 s1_idx;
    logic [63:0]                   s1_seq;
    logic [63:0]                   s1_lat;
    logic [15:0]                   s1_bytelen;
    logic [$clog2(NUM_BUCKETS)-1:0] s1_bucket;

    // bypass register: the record just written by the previous RMW.
    logic             s2_we;
    logic [AW-1:0]    s2_idx;
    logic [REC_W-1:0] s2_rec;

    always_comb begin
        // Port-A read address: during a clear walk none (clear owns writes);
        // otherwise the incoming event's flow index.
        a_raddr = result_i.local_flow_id[AW-1:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            clearing <= 1'b1;     // clear once after reset to seed min = FFFF
            clear_idx <= '0;
        end else if (clear_i && !clearing) begin
            s1_valid <= 1'b0;
            clearing <= 1'b1;
            clear_idx <= '0;
        end else if (clearing) begin
            s1_valid <= 1'b0;     // drop events while clearing
            if (clear_idx == NUM_FLOWS[AW:0]) clearing <= 1'b0;
            else clear_idx <= clear_idx + 1'b1;
        end else begin
            // Corrected cross-card latency can go slightly NEGATIVE (over-
            // correction within the inter-card sync residual) or, on a misconfig,
            // exceed 32 bits. Treat the raw result as SIGNED and clamp to
            // [0, 0xFFFFFFFF] before it feeds the 32-bit min/max/jitter and the
            // histogram: a raw negative value's low 32 bits (lat32 = s1_lat[31:0])
            // would otherwise read as a huge UNSIGNED number and pin max/jitter to
            // 0xFFFFFFFF (and log2_bucket to the top bucket). MSB set = negative.
            automatic logic [63:0] lat_raw = (timestamp_i + lat_correction_i)
                                             - key_i.test_tx_timestamp;
            automatic logic [63:0] lat = lat_raw[63]      ? 64'd0            // negative -> 0
                                       : (|lat_raw[63:32]) ? 64'hFFFF_FFFF   // >32-bit -> saturate
                                                           : lat_raw;
            automatic int          b   = log2_bucket(lat);
            if (b >= NUM_BUCKETS) b = NUM_BUCKETS - 1;
            s1_valid  <= event_take;
            s1_is_test<= key_i.is_test;
            s1_idx    <= result_i.local_flow_id[AW-1:0];
            s1_seq    <= key_i.test_sequence;
            s1_lat    <= lat;
            s1_bytelen<= byte_len_i;
            s1_bucket <= ($clog2(NUM_BUCKETS))'(b);
        end
    end

    // ---- stage 1: RMW update + write-back (port A) ----
    logic [REC_W-1:0] rec, nr;
    logic [63:0]      exp;
    logic             seen;
    logic [31:0]      prev, lat32, curmin, curmax, jmin, jmax, jd;
    logic             lost_inc;   // this event increments lost (missing frames)

    always_comb begin
        // defaults (assign every signal on every path -> no latches)
        rec = '0; nr = '0; exp = '0; seen = 1'b0;
        prev = '0; lat32 = '0; curmin = '0; curmax = '0; jmin = '0; jmax = '0; jd = '0;
        a_we = 1'b0; a_waddr = s1_idx; a_wdata = '0;
        lost_inc = 1'b0;

        if (clearing) begin
            a_we    = (clear_idx < NUM_FLOWS[AW:0]);
            a_waddr = clear_idx[AW-1:0];
            a_wdata = blank_rec();
        end else if (s1_valid) begin
            // source record: bypass the previous write if same flow.
            rec    = (s2_we && s2_idx == s1_idx) ? s2_rec : a_rd_q;
            exp    = rec[OFF_EXP  +: 64];
            seen   = rec[OFF_SEEN];
            prev   = rec[OFF_PREVL +: 32];
            lat32  = s1_lat[31:0];
            curmin = rec[OFF_MINL +: 32];
            curmax = rec[OFF_MAXL +: 32];
            jmin   = rec[OFF_JMIN +: 32];
            jmax   = rec[OFF_JMAX +: 32];
            nr     = rec;

            // rx_frames + rx_bytes count every classified frame (test or not).
            nr[OFF_RXF  +: 64] = rec[OFF_RXF  +: 64] + 64'd1;
            nr[OFF_RXB  +: 64] = rec[OFF_RXB  +: 64] + 64'(s1_bytelen);

            // Sequence + latency + jitter need the test header; only update them
            // for is_test frames. Header-defined flows with no test header count
            // rx only (everything else holds its prior / blank value).
            if (s1_is_test) begin
                nr[OFF_LAST +: 64] = s1_seq;
                nr[OFF_SUML +: 64] = rec[OFF_SUML +: 64] + s1_lat;
                nr[OFF_SAMP +: 64] = rec[OFF_SAMP +: 64] + 64'd1;
                if (lat32 < curmin) nr[OFF_MINL +: 32] = lat32;
                if (lat32 > curmax) nr[OFF_MAXL +: 32] = lat32;

                // IPDV jitter once a prior sample exists.
                if (seen) begin
                    jd = (lat32 >= prev) ? (lat32 - prev) : (prev - lat32);
                    nr[OFF_JSUM +: 64] = rec[OFF_JSUM +: 64] + 64'(jd);
                    if (jd < jmin) nr[OFF_JMIN +: 32] = jd;
                    if (jd > jmax) nr[OFF_JMAX +: 32] = jd;
                end
                nr[OFF_PREVL +: 32] = lat32;

                // sequence-gap classification (same as pw_test_rx_checker).
                if (!seen) begin
                    nr[OFF_EXP +: 64] = s1_seq + 64'd1;
                    nr[OFF_SEEN]      = 1'b1;
                end else if (s1_seq == exp) begin
                    nr[OFF_EXP +: 64] = exp + 64'd1;
                end else if (s1_seq > exp) begin
                    nr[OFF_LOST +: 64] = rec[OFF_LOST +: 64] + (s1_seq - exp);
                    nr[OFF_EXP  +: 64] = s1_seq + 64'd1;
                    lost_inc = 1'b1;   // missing frames -> pulse the health LED
                end else if (s1_seq == exp - 64'd1) begin
                    nr[OFF_DUP +: 64] = rec[OFF_DUP +: 64] + 64'd1;
                end else begin
                    nr[OFF_OOO +: 64] = rec[OFF_OOO +: 64] + 64'd1;
                end
            end

            a_we    = 1'b1;
            a_waddr = s1_idx;
            a_wdata = nr;
        end
    end

    // BRAM: port A (RMW read + write), port B (snapshot read). Inferred TDP.
    always_ff @(posedge clk) begin
        if (a_we) mem[a_waddr] <= a_wdata;
        a_rd_q <= mem[a_raddr];
        b_rd_q <= mem[rd_addr_i];
    end

    // bypass + histogram-event registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_we <= 1'b0; s2_idx <= '0; s2_rec <= '0;
            hist_ev_o <= 1'b0; hist_flow_o <= '0; hist_bucket_o <= '0;
            rd_valid_o <= 1'b0; lost_event_o <= 1'b0;
        end else begin
            s2_we  <= (!clearing) && s1_valid;
            s2_idx <= s1_idx;
            s2_rec <= a_wdata;     // == nr when s1_valid
            // histogram event one cycle behind the RMW, mirroring the event.
            // Only test frames carry a latency, so non-test frames don't bin.
            hist_ev_o     <= (!clearing) && s1_valid && s1_is_test;
            hist_flow_o   <= 16'(s1_idx);
            hist_bucket_o <= 16'(s1_bucket);
            rd_valid_o    <= rd_en_i;
            lost_event_o  <= (!clearing) && s1_valid && s1_is_test && lost_inc;
        end
    end

    // ---- snapshot read outputs (port B, registered) ----
    always_comb begin
        rd_rx_frames_o    = b_rd_q[OFF_RXF  +: 64];
        rd_rx_bytes_o     = b_rd_q[OFF_RXB  +: 64];
        rd_lost_o         = b_rd_q[OFF_LOST +: 64];
        rd_duplicate_o    = b_rd_q[OFF_DUP  +: 64];
        rd_out_of_order_o = b_rd_q[OFF_OOO  +: 64];
        rd_last_seq_o     = b_rd_q[OFF_LAST +: 64];
        rd_sum_latency_o  = b_rd_q[OFF_SUML +: 64];
        rd_sample_count_o = b_rd_q[OFF_SAMP +: 64];
        rd_jitter_sum_o   = b_rd_q[OFF_JSUM +: 64];
        rd_min_latency_o  = {32'h0, b_rd_q[OFF_MINL +: 32]};
        rd_max_latency_o  = {32'h0, b_rd_q[OFF_MAXL +: 32]};
        rd_jitter_min_o   = {32'h0, b_rd_q[OFF_JMIN +: 32]};
        rd_jitter_max_o   = {32'h0, b_rd_q[OFF_JMAX +: 32]};
    end

endmodule

`default_nettype wire
