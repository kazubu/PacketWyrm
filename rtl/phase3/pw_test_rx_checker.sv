// PacketWyrm test-packet RX checker.
//
// Sees one classification event per cycle (frame_valid && action ==
// TEST_RX). Looks at the test header fields the parser already
// extracted and updates per-flow counters: rx_frames, lost (gap),
// duplicate, out_of_order, last_sequence.
//
// Counter array is parameterised: `NUM_FLOWS` flow slots indexed by
// the classifier's local_flow_id. The testbench reads them via the
// `counters_o` output (production wires them into the CSR stats
// snapshot window).

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_test_rx_checker #(
    parameter int NUM_FLOWS = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  pw_match_key_t        key_i,
    input  pw_class_result_t     result_i,
    input  wire                  event_valid_i,   // cycle is a classification event

    output logic [63:0]          rx_frames_o   [NUM_FLOWS],
    output logic [63:0]          lost_o        [NUM_FLOWS],
    output logic [63:0]          duplicate_o   [NUM_FLOWS],
    output logic [63:0]          out_of_order_o[NUM_FLOWS],
    output logic [63:0]          last_seq_o    [NUM_FLOWS]
);

    logic [63:0] expected_seq [NUM_FLOWS];
    logic        flow_seen    [NUM_FLOWS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_FLOWS; i++) begin
                rx_frames_o[i]    <= '0;
                lost_o[i]         <= '0;
                duplicate_o[i]    <= '0;
                out_of_order_o[i] <= '0;
                last_seq_o[i]     <= '0;
                expected_seq[i]   <= '0;
                flow_seen[i]      <= 1'b0;
            end
        end else if (event_valid_i &&
                     result_i.hit &&
                     result_i.action == PW_ACT_TEST_RX &&
                     key_i.is_test &&
                     result_i.local_flow_id < NUM_FLOWS) begin
            automatic int           idx = int'(result_i.local_flow_id);
            automatic logic [63:0]  rx_seq = key_i.test_sequence;

            rx_frames_o[idx] <= rx_frames_o[idx] + 64'd1;
            last_seq_o[idx]  <= rx_seq;

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

endmodule

`default_nettype wire
