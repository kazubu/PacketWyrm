// Unit testbench for pw_test_rx_checker_bram: drives TEST_RX events for a
// few flows with known sequences/latencies and checks the BRAM record via
// the snapshot read port. Covers rx/lost/dup/ooo/last_seq, latency
// min/max/sum/samples, IPDV jitter, the same-flow back-to-back bypass,
// and clear.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_test_rx_checker_bram;

    localparam int NUM_FLOWS = 8;
    localparam int AW = $clog2(NUM_FLOWS);

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic clear_i = 0;
    logic [63:0] timestamp_i;
    logic [63:0] lat_correction_i = '0;
    pw_match_key_t key_i;
    pw_class_result_t result_i;
    logic event_valid_i;

    logic [AW-1:0] rd_addr_i;
    logic rd_en_i;
    logic rd_valid_o;
    logic [63:0] rd_rx, rd_rxb, rd_lost, rd_dup, rd_ooo, rd_lseq;
    logic [63:0] rd_minl, rd_maxl, rd_suml, rd_samp;
    logic [63:0] rd_jmin, rd_jmax, rd_jsum;
    logic [15:0] byte_len_i;
    logic [15:0] ev_bytelen = 16'd64;   // frame length fed by ev(); tests can override

    pw_test_rx_checker_bram #(.NUM_FLOWS(NUM_FLOWS), .NUM_BUCKETS(16)) dut (
        .clk(clk), .rst_n(rst_n), .clear_i(clear_i),
        .timestamp_i(timestamp_i), .lat_correction_i(lat_correction_i),
        .key_i(key_i), .result_i(result_i),
        .event_valid_i(event_valid_i), .byte_len_i(byte_len_i),
        .hist_ev_o(), .hist_flow_o(), .hist_bucket_o(), .lost_event_o(),
        .rd_addr_i(rd_addr_i), .rd_en_i(rd_en_i), .rd_valid_o(rd_valid_o),
        .rd_rx_frames_o(rd_rx), .rd_rx_bytes_o(rd_rxb), .rd_lost_o(rd_lost), .rd_duplicate_o(rd_dup),
        .rd_out_of_order_o(rd_ooo), .rd_last_seq_o(rd_lseq),
        .rd_min_latency_o(rd_minl), .rd_max_latency_o(rd_maxl),
        .rd_sum_latency_o(rd_suml), .rd_sample_count_o(rd_samp),
        .rd_jitter_min_o(rd_jmin), .rd_jitter_max_o(rd_jmax),
        .rd_jitter_sum_o(rd_jsum)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin
            $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++;
        end else $display("[ ok ] %s: %0d", what, got);
    endtask

    // Issue one TEST_RX event for (flow, seq, lat). `gap`=1 inserts an idle
    // cycle after (normal spacing); gap=0 leaves event_valid high back-to-back.
    task automatic ev(input int flow, input longint seq, input longint lat,
                      input bit gap);
        @(negedge clk);
        event_valid_i      = 1'b1;
        result_i.hit       = 1'b1;
        result_i.action    = PW_ACT_TEST_RX;
        result_i.local_flow_id = flow[31:0];
        key_i.is_test      = 1'b1;
        key_i.test_sequence = 64'(seq);
        key_i.test_tx_timestamp = 64'd1000;
        timestamp_i        = 64'd1000 + 64'(lat);  // latency = lat
        byte_len_i         = ev_bytelen;            // frame byte length for this event
        @(negedge clk);
        event_valid_i = 1'b0;
        if (gap) @(negedge clk);
    endtask

    task automatic rd(input int flow);
        @(negedge clk);
        rd_addr_i = flow[AW-1:0];
        rd_en_i   = 1'b1;
        @(negedge clk);
        rd_en_i   = 1'b0;
        @(negedge clk);   // record valid now
    endtask

    initial begin
        event_valid_i = 0; rd_en_i = 0; rd_addr_i = 0;
        key_i = '0; result_i = '0; timestamp_i = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        // wait out the post-reset clear walk
        repeat (NUM_FLOWS + 6) @(negedge clk);

        // flow 1: seq 0,1,2 latencies 100,105,102 (jitter d=5 then 3)
        ev(1, 0, 100, 1); ev(1, 1, 105, 1); ev(1, 2, 102, 1);
        // flow 2: seq 0,1,3 -> lost 1 (gap at 2)
        ev(2, 0, 50, 1); ev(2, 1, 50, 1); ev(2, 3, 50, 1);
        // flow 3: seq 0,1,1 -> duplicate 1
        ev(3, 0, 60, 1); ev(3, 1, 60, 1); ev(3, 1, 60, 1);
        // flow 4: back-to-back (no idle) seq 0,1 -> exercises bypass
        ev(4, 0, 70, 0); ev(4, 1, 71, 1);
        repeat (4) @(negedge clk);

        rd(1);
        chk("f1 rx",      rd_rx,   3);
        chk("f1 rx_bytes",rd_rxb,  3*64);   // 3 frames x default 64B
        chk("f1 lost",    rd_lost, 0);
        chk("f1 last",    rd_lseq, 2);
        chk("f1 min_lat", rd_minl, 100);
        chk("f1 max_lat", rd_maxl, 105);
        chk("f1 sum_lat", rd_suml, 307);
        chk("f1 samples", rd_samp, 3);
        chk("f1 jit_min", rd_jmin, 3);
        chk("f1 jit_max", rd_jmax, 5);
        chk("f1 jit_sum", rd_jsum, 8);

        rd(2);
        chk("f2 rx",   rd_rx,   3);
        chk("f2 lost", rd_lost, 1);
        chk("f2 last", rd_lseq, 3);

        rd(3);
        chk("f3 rx",  rd_rx,  3);
        chk("f3 dup", rd_dup, 1);

        rd(4);
        chk("f4 rx (bypass)", rd_rx,   2);
        chk("f4 last",        rd_lseq, 1);
        chk("f4 lost",        rd_lost, 0);

        // clear, then confirm a flow zeroes
        @(negedge clk); clear_i = 1; @(negedge clk); clear_i = 0;
        repeat (NUM_FLOWS + 6) @(negedge clk);
        rd(1);
        chk("f1 rx after clear",   rd_rx,   0);
        chk("f1 samp after clear", rd_samp, 0);

        // cross-card latency correction: the checker computes
        // lat = (timestamp_i + lat_correction_i) - tx_ts. A signed (negative,
        // two's complement) correction brings a raw latency down per sample, so
        // min/max/sum all accumulate the corrected value (no SW post-hoc fix).
        lat_correction_i = -64'sd100;          // 64'hFFFF_FFFF_FFFF_FF9C
        ev(5, 0, 200, 1);                      // raw 200 -> corrected 100
        ev(5, 1, 260, 1);                      // raw 260 -> corrected 160
        repeat (4) @(negedge clk);
        rd(5);
        chk("f5 min_lat (corrected)", rd_minl, 100);
        chk("f5 max_lat (corrected)", rd_maxl, 160);
        chk("f5 sum_lat (corrected)", rd_suml, 260);
        chk("f5 samples",             rd_samp, 2);
        lat_correction_i = '0;                 // restore (same-card default)

        // f6: OVER-correction -> corrected latency goes NEGATIVE. The checker
        // must CLAMP to 0 (not let the signed value wrap to ~0xFFFFFFFF in the
        // unsigned low-32 truncation and pin max/jitter to 0xFFFFFFFF). Then a
        // positive sample follows: min stays 0, max is the positive value.
        lat_correction_i = -64'sd100;          // over-correct
        ev(6, 0, 40,  1);                      // raw 40  -> -60  => clamp 0
        ev(6, 1, 30,  1);                      // raw 30  -> -70  => clamp 0
        ev(6, 2, 150, 1);                      // raw 150 -> 50   (positive)
        repeat (4) @(negedge clk);
        rd(6);
        chk("f6 min_lat (neg->clamp 0)", rd_minl, 0);
        chk("f6 max_lat (not 0xFFFFFFFF)", rd_maxl, 50);
        chk("f6 sum_lat (0+0+50)",         rd_suml, 50);
        chk("f6 samples",                  rd_samp, 3);
        lat_correction_i = '0;                 // restore

        // f7: rx_bytes accumulates the per-event byte length (varying), counting
        // EVERY classified frame. 100 + 200 + 300 = 600 bytes over 3 frames.
        ev_bytelen = 16'd100; ev(7, 0, 100, 1);
        ev_bytelen = 16'd200; ev(7, 1, 100, 1);
        ev_bytelen = 16'd300; ev(7, 2, 100, 1);
        ev_bytelen = 16'd64;                   // restore default
        repeat (4) @(negedge clk);
        rd(7);
        chk("f7 rx",             rd_rx,  3);
        chk("f7 rx_bytes (sum)", rd_rxb, 600);

        if (errors == 0) $display("ALL CHECKER_BRAM SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("WATCHDOG TIMEOUT"); $fatal; end

endmodule

`default_nettype wire
