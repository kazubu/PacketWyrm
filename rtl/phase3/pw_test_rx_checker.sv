// PacketWyrm test-packet RX checker.
//
// Sees one classification event per cycle (frame_valid && action ==
// TEST_RX). Updates per-flow counters: rx_frames, lost (gap),
// duplicate, out_of_order, last_sequence, plus per-flow min/max/sum
// latency, keyed off (timestamp_i - key.test_tx_timestamp). Latency
// is meaningful only for same-card flows; cross-card flows pass
// through the same code path, but the daemon ignores their latency by
// honouring `latency_valid` in the flow meta.
//
// The latency *histogram* lives in BRAM (pw_lat_histogram), so this
// checker no longer keeps the power-of-two bucket array in flip-flops
// on the data path. Instead it emits a registered histogram *event*
// per counted frame -- {hist_ev_o, hist_flow_o, hist_bucket_o} -- that
// pw_lat_histogram accumulates. The flat FF histogram (hist_o) is kept
// only when EMIT_HIST_ARRAY=1, for the legacy wide-bus plane and its
// sims; the streaming data plane sets it to 0 and leaves hist_o open.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_test_rx_checker #(
    parameter int NUM_FLOWS   = 16,
    parameter int NUM_BUCKETS = 16,  // power-of-2 latency buckets
    // 0: single-cycle compute+update (default; wide-bus plane + its sims
    //    expect counters one cycle after the event).
    // 1: split into stage-1 {latency / log2 bucket / idx} register and
    //    stage-2 counter update, to break the long classifier ->
    //    64-bit subtract -> priority-encoder path. Identical counter
    //    values, produced one extra cycle later. Safe because TEST_RX
    //    events are frame-spaced (no back-to-back).
    parameter int PIPELINE    = 0,
    // 1: keep the flat FF latency histogram on hist_o (legacy plane).
    // 0: drop it (hist_o tied 0); the streaming plane accumulates the
    //    histogram in BRAM from the emitted events instead.
    parameter int EMIT_HIST_ARRAY = 1
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Synchronous soft clear: zeroes all per-flow counters + state and
    // re-baselines sequence tracking (the next frame sets expected_seq).
    // Driven by a CSR write so `test arm` can reset stats without rst_n.
    input  wire                  clear_i,

    input  wire [63:0]           timestamp_i,

    input  pw_match_key_t        key_i,
    input  pw_class_result_t     result_i,
    input  wire                  event_valid_i,

    output logic [63:0]          rx_frames_o   [NUM_FLOWS],
    output logic [63:0]          lost_o        [NUM_FLOWS],
    output logic [63:0]          duplicate_o   [NUM_FLOWS],
    output logic [63:0]          out_of_order_o[NUM_FLOWS],
    output logic [63:0]          last_seq_o    [NUM_FLOWS],
    output logic [63:0]          min_latency_o [NUM_FLOWS],
    output logic [63:0]          max_latency_o [NUM_FLOWS],
    output logic [63:0]          sum_latency_o [NUM_FLOWS],
    output logic [63:0]          sample_count_o[NUM_FLOWS],

    // Per-flow IPDV jitter (RFC-3393 style): |latency[n] - latency[n-1]|
    // accumulated per flow. min/max/sum over the deltas; the first sample
    // of a flow seeds prev_latency without producing a delta.
    output logic [63:0]          jitter_min_o  [NUM_FLOWS],
    output logic [63:0]          jitter_max_o  [NUM_FLOWS],
    output logic [63:0]          jitter_sum_o  [NUM_FLOWS],

    // Registered histogram event: one pulse per counted frame, carrying
    // the flow id and its log2 latency bucket. Always driven.
    output logic                 hist_ev_o,
    output logic [15:0]          hist_flow_o,
    output logic [15:0]          hist_bucket_o,

    // Flat histogram: hist_o[flow * NUM_BUCKETS + bucket]. Driven only
    // when EMIT_HIST_ARRAY=1, otherwise tied to 0.
    output logic [63:0]          hist_o        [NUM_FLOWS * NUM_BUCKETS]
);

    logic [63:0] expected_seq [NUM_FLOWS];
    logic        flow_seen    [NUM_FLOWS];
    logic [63:0] prev_latency [NUM_FLOWS];   // last sample's latency, for IPDV

    // Find the highest set bit in `x` (returns 0 when x==0). The
    // simulator unrolls this comfortably for 64 bits; the same
    // structure becomes a single priority encoder in synthesis.
    function automatic int log2_bucket(input logic [63:0] x);
        int b;
        b = 0;
        for (int i = 0; i < 64; i++) begin
            if (x[i]) b = i;
        end
        return b;
    endfunction

    // Histogram-event source signals (combinational), shared by the
    // emitted event registers and the optional flat FF array. Their
    // timing matches the counter update of the active PIPELINE mode.
    logic        h_wr;
    logic [31:0] h_idx;
    logic [15:0] h_bkt;

    // Per-flow counter reset via an initial block (works under sim and
    // as an FPGA bitstream-init value); the per-flow counters also get
    // the synchronous reset path below.
    initial begin
        for (int i = 0; i < NUM_FLOWS; i++) begin
            rx_frames_o[i]    = '0;
            lost_o[i]         = '0;
            duplicate_o[i]    = '0;
            out_of_order_o[i] = '0;
            last_seq_o[i]     = '0;
            min_latency_o[i]  = 64'hFFFF_FFFF_FFFF_FFFF;
            max_latency_o[i]  = '0;
            sum_latency_o[i]  = '0;
            sample_count_o[i] = '0;
            jitter_min_o[i]   = 64'hFFFF_FFFF_FFFF_FFFF;
            jitter_max_o[i]   = '0;
            jitter_sum_o[i]   = '0;
            prev_latency[i]   = '0;
            expected_seq[i]   = '0;
            flow_seen[i]      = 1'b0;
        end
    end

    // Event accepted for counting: a valid TEST_RX hit to an in-range flow.
    wire event_take = event_valid_i && result_i.hit &&
                      result_i.action == PW_ACT_TEST_RX &&
                      key_i.is_test && result_i.local_flow_id < NUM_FLOWS;

    generate
    if (PIPELINE == 0) begin : g_flat
        // ---- single-cycle compute + update (original behaviour) ----
        always_comb begin
            automatic logic [63:0] lat = timestamp_i - key_i.test_tx_timestamp;
            automatic int          b   = log2_bucket(lat);
            if (b >= NUM_BUCKETS) b = NUM_BUCKETS - 1;
            h_wr  = event_take;
            h_idx = 32'(result_i.local_flow_id);
            h_bkt = 16'(b);
        end

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear_i) begin
                for (int i = 0; i < NUM_FLOWS; i++) begin
                    rx_frames_o[i]    <= '0;
                    lost_o[i]         <= '0;
                    duplicate_o[i]    <= '0;
                    out_of_order_o[i] <= '0;
                    last_seq_o[i]     <= '0;
                    min_latency_o[i]  <= 64'hFFFF_FFFF_FFFF_FFFF;
                    max_latency_o[i]  <= '0;
                    sum_latency_o[i]  <= '0;
                    sample_count_o[i] <= '0;
                    jitter_min_o[i]   <= 64'hFFFF_FFFF_FFFF_FFFF;
                    jitter_max_o[i]   <= '0;
                    jitter_sum_o[i]   <= '0;
                    prev_latency[i]   <= '0;
                    expected_seq[i]   <= '0;
                    flow_seen[i]      <= 1'b0;
                end
            end else if (event_take) begin
                automatic int           idx       = int'(result_i.local_flow_id);
                automatic logic [63:0]  rx_seq    = key_i.test_sequence;
                automatic logic [63:0]  latency   = timestamp_i - key_i.test_tx_timestamp;

                rx_frames_o[idx]            <= rx_frames_o[idx] + 64'd1;
                last_seq_o[idx]             <= rx_seq;
                sum_latency_o[idx]          <= sum_latency_o[idx] + latency;
                sample_count_o[idx]         <= sample_count_o[idx] + 64'd1;
                if (latency < min_latency_o[idx]) min_latency_o[idx] <= latency;
                if (latency > max_latency_o[idx]) max_latency_o[idx] <= latency;

                // IPDV jitter: |latency - prev_latency|. flow_seen gates the
                // first sample (no prior latency yet); prev_latency always tracks.
                if (flow_seen[idx]) begin
                    automatic logic [63:0] jdelta =
                        (latency >= prev_latency[idx]) ? (latency - prev_latency[idx])
                                                       : (prev_latency[idx] - latency);
                    jitter_sum_o[idx]               <= jitter_sum_o[idx] + jdelta;
                    if (jdelta < jitter_min_o[idx]) jitter_min_o[idx] <= jdelta;
                    if (jdelta > jitter_max_o[idx]) jitter_max_o[idx] <= jdelta;
                end
                prev_latency[idx]           <= latency;

                if (!flow_seen[idx]) begin
                    expected_seq[idx] <= rx_seq + 64'd1;
                    flow_seen[idx]    <= 1'b1;
                end else if (rx_seq == expected_seq[idx]) begin
                    expected_seq[idx] <= expected_seq[idx] + 64'd1;
                end else if (rx_seq > expected_seq[idx]) begin
                    lost_o[idx]       <= lost_o[idx] + (rx_seq - expected_seq[idx]);
                    expected_seq[idx] <= rx_seq + 64'd1;
                end else if (rx_seq == expected_seq[idx] - 64'd1) begin
                    duplicate_o[idx]  <= duplicate_o[idx] + 64'd1;
                end else begin
                    out_of_order_o[idx] <= out_of_order_o[idx] + 64'd1;
                end
            end
        end
    end else begin : g_pipe
        // ---- stage 1: latency / log2 bucket / idx decode (registered) ----
        // Breaks the 64-bit subtract + priority-encoder out of the update
        // path. timestamp_i is sampled at the event cycle, same as flat.
        logic                          s1_valid;
        logic [31:0]                   s1_idx;
        logic [63:0]                   s1_seq;
        logic [63:0]                   s1_lat;
        logic [$clog2(NUM_BUCKETS)-1:0] s1_bucket;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear_i) begin
                s1_valid <= 1'b0;
            end else begin
                automatic logic [63:0] lat = timestamp_i - key_i.test_tx_timestamp;
                automatic int          b   = log2_bucket(lat);
                if (b >= NUM_BUCKETS) b = NUM_BUCKETS - 1;
                s1_valid  <= event_take;
                s1_idx    <= result_i.local_flow_id;
                s1_seq    <= key_i.test_sequence;
                s1_lat    <= lat;
                s1_bucket <= ($clog2(NUM_BUCKETS))'(b);
            end
        end

        // Histogram event sourced from the (already registered) stage-1
        // values, so the HW path keeps the subtract/encoder pipelined.
        always_comb begin
            h_wr  = s1_valid;
            h_idx = s1_idx;
            h_bkt = 16'(s1_bucket);
        end

        // ---- stage 2: counter / seq-gap update ----
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear_i) begin
                for (int i = 0; i < NUM_FLOWS; i++) begin
                    rx_frames_o[i]    <= '0;
                    lost_o[i]         <= '0;
                    duplicate_o[i]    <= '0;
                    out_of_order_o[i] <= '0;
                    last_seq_o[i]     <= '0;
                    min_latency_o[i]  <= 64'hFFFF_FFFF_FFFF_FFFF;
                    max_latency_o[i]  <= '0;
                    sum_latency_o[i]  <= '0;
                    sample_count_o[i] <= '0;
                    jitter_min_o[i]   <= 64'hFFFF_FFFF_FFFF_FFFF;
                    jitter_max_o[i]   <= '0;
                    jitter_sum_o[i]   <= '0;
                    prev_latency[i]   <= '0;
                    expected_seq[i]   <= '0;
                    flow_seen[i]      <= 1'b0;
                end
            end else if (s1_valid) begin
                automatic int          idx     = int'(s1_idx);
                automatic logic [63:0] rx_seq  = s1_seq;
                automatic logic [63:0] latency = s1_lat;

                rx_frames_o[idx]            <= rx_frames_o[idx] + 64'd1;
                last_seq_o[idx]             <= rx_seq;
                sum_latency_o[idx]          <= sum_latency_o[idx] + latency;
                sample_count_o[idx]         <= sample_count_o[idx] + 64'd1;
                if (latency < min_latency_o[idx]) min_latency_o[idx] <= latency;
                if (latency > max_latency_o[idx]) max_latency_o[idx] <= latency;

                // IPDV jitter: |latency - prev_latency|. flow_seen gates the
                // first sample (no prior latency yet); prev_latency always tracks.
                if (flow_seen[idx]) begin
                    automatic logic [63:0] jdelta =
                        (latency >= prev_latency[idx]) ? (latency - prev_latency[idx])
                                                       : (prev_latency[idx] - latency);
                    jitter_sum_o[idx]               <= jitter_sum_o[idx] + jdelta;
                    if (jdelta < jitter_min_o[idx]) jitter_min_o[idx] <= jdelta;
                    if (jdelta > jitter_max_o[idx]) jitter_max_o[idx] <= jdelta;
                end
                prev_latency[idx]           <= latency;

                if (!flow_seen[idx]) begin
                    expected_seq[idx] <= rx_seq + 64'd1;
                    flow_seen[idx]    <= 1'b1;
                end else if (rx_seq == expected_seq[idx]) begin
                    expected_seq[idx] <= expected_seq[idx] + 64'd1;
                end else if (rx_seq > expected_seq[idx]) begin
                    lost_o[idx]       <= lost_o[idx] + (rx_seq - expected_seq[idx]);
                    expected_seq[idx] <= rx_seq + 64'd1;
                end else if (rx_seq == expected_seq[idx] - 64'd1) begin
                    duplicate_o[idx]  <= duplicate_o[idx] + 64'd1;
                end else begin
                    out_of_order_o[idx] <= out_of_order_o[idx] + 64'd1;
                end
            end
        end
    end
    endgenerate

    // ---- registered histogram event outputs (always driven) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear_i) begin
            hist_ev_o     <= 1'b0;
            hist_flow_o   <= '0;
            hist_bucket_o <= '0;
        end else begin
            hist_ev_o     <= h_wr;
            hist_flow_o   <= h_idx[15:0];
            hist_bucket_o <= h_bkt;
        end
    end

    // ---- optional flat FF histogram (legacy plane only) ----
    generate
    if (EMIT_HIST_ARRAY != 0) begin : g_harr
        initial begin
            for (int j = 0; j < NUM_FLOWS * NUM_BUCKETS; j++) hist_o[j] = '0;
        end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear_i) begin
                for (int j = 0; j < NUM_FLOWS * NUM_BUCKETS; j++) hist_o[j] <= '0;
            end else if (h_wr) begin
                automatic int fi = int'(h_idx);
                automatic int bi = int'(h_bkt);
                hist_o[fi * NUM_BUCKETS + bi] <= hist_o[fi * NUM_BUCKETS + bi] + 64'd1;
            end
        end
    end else begin : g_noharr
        for (genvar j = 0; j < NUM_FLOWS * NUM_BUCKETS; j++)
            assign hist_o[j] = 64'd0;
    end
    endgenerate

endmodule

`default_nettype wire
