// PacketWyrm test-packet RX checker.
//
// Sees one classification event per cycle (frame_valid && action ==
// TEST_RX). Updates per-flow counters: rx_frames, lost (gap),
// duplicate, out_of_order, last_sequence, plus a power-of-two
// latency histogram with NUM_BUCKETS bins keyed off
// (timestamp_i - key.test_tx_timestamp). Latency is meaningful
// only for same-card flows; cross-card flows pass through the
// same code path, but the daemon ignores their histogram by
// honouring `latency_valid` in the flow meta.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_test_rx_checker #(
    parameter int NUM_FLOWS   = 16,
    parameter int NUM_BUCKETS = 16,  // power-of-2 latency buckets
    // 0: single-cycle compute+update (default; wide-bus plane + its sims
    //    expect counters one cycle after the event).
    // 1: split into stage-1 {latency / log2 bucket / idx} register and
    //    stage-2 counter+histogram update, to break the long
    //    classifier -> 64-bit subtract -> priority-encoder -> hist path.
    //    Identical counter values, produced one extra cycle later. Safe
    //    because TEST_RX events are frame-spaced (no back-to-back).
    parameter int PIPELINE    = 0
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

    // Flat histogram: hist_o[flow * NUM_BUCKETS + bucket]
    output logic [63:0]          hist_o        [NUM_FLOWS * NUM_BUCKETS]
);

    logic [63:0] expected_seq [NUM_FLOWS];
    logic        flow_seen    [NUM_FLOWS];

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

    // Per-flow + histogram register reset. Verilator dislikes
    // delayed-assignment-in-for-loop on unpacked arrays, so reset
    // the histogram via an initial block (works under sim and as
    // an FPGA bitstream-init value); the per-flow counters still
    // get the synchronous reset path that ASIC tools want.
    initial begin
        for (int j = 0; j < NUM_FLOWS * NUM_BUCKETS; j++)
            hist_o[j] = '0;
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
                    expected_seq[i]   <= '0;
                    flow_seen[i]      <= 1'b0;
                end
            end else if (event_take) begin
                automatic int           idx       = int'(result_i.local_flow_id);
                automatic logic [63:0]  rx_seq    = key_i.test_sequence;
                automatic logic [63:0]  latency   = timestamp_i - key_i.test_tx_timestamp;
                automatic int           bucket    = log2_bucket(latency);

                if (bucket >= NUM_BUCKETS) bucket = NUM_BUCKETS - 1;

                rx_frames_o[idx]            <= rx_frames_o[idx] + 64'd1;
                last_seq_o[idx]             <= rx_seq;
                sum_latency_o[idx]          <= sum_latency_o[idx] + latency;
                sample_count_o[idx]         <= sample_count_o[idx] + 64'd1;
                if (latency < min_latency_o[idx]) min_latency_o[idx] <= latency;
                if (latency > max_latency_o[idx]) max_latency_o[idx] <= latency;
                hist_o[idx * NUM_BUCKETS + bucket]
                    <= hist_o[idx * NUM_BUCKETS + bucket] + 64'd1;

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

        // ---- stage 2: counter / seq-gap / histogram update ----
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
                    expected_seq[i]   <= '0;
                    flow_seen[i]      <= 1'b0;
                end
            end else if (s1_valid) begin
                automatic int          idx     = int'(s1_idx);
                automatic logic [63:0] rx_seq  = s1_seq;
                automatic logic [63:0] latency = s1_lat;
                automatic int          bucket  = int'(s1_bucket);

                rx_frames_o[idx]            <= rx_frames_o[idx] + 64'd1;
                last_seq_o[idx]             <= rx_seq;
                sum_latency_o[idx]          <= sum_latency_o[idx] + latency;
                sample_count_o[idx]         <= sample_count_o[idx] + 64'd1;
                if (latency < min_latency_o[idx]) min_latency_o[idx] <= latency;
                if (latency > max_latency_o[idx]) max_latency_o[idx] <= latency;
                hist_o[idx * NUM_BUCKETS + bucket]
                    <= hist_o[idx * NUM_BUCKETS + bucket] + 64'd1;

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

endmodule

`default_nettype wire
