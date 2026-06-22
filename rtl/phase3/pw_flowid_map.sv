// PacketWyrm TEST_RX flow-id map -- scalable exact-match for the tester's own
// test traffic, replacing per-flow parallel classifier rules.
//
// Our generated test frames carry a flow_id in the test header. Instead of N
// parallel classifier comparators (one rule per flow -- the route-congestion
// wall that caps the flat/banked classifier at ~16 entries on the xcku3p), a
// frame's parsed test_flow_id directly indexes a small BRAM table:
//
//   lookup(test_flow_id) -> { valid, local_flow_id }
//
// gated by is_test (the parser's magic match). A hit means TEST_RX with the
// mapped checker slot; no comparators, so the test-flow count scales with the
// BRAM (MAP_DEPTH) and the checker capacity, not with routability. The parallel
// classifier then only carries the FEW non-test rules (PUNT / FORWARD / DROP),
// so it shrinks back to a small, easily-routed table.
//
// See docs/design/generic-classifier.md (Phase 3, the direct-index path).
//
// The table is programmed over a CSR write port before traffic starts (mirrors
// how the classifier/flow tables are loaded); the BRAM is initialised to 0
// (all entries invalid) at bitstream load. A registered read gives the lookup a
// 1-cycle latency.

`default_nettype none

module pw_flowid_map #(
    parameter int NUM_FLOWS = 32,      // local checker-slot index space
    parameter int MAP_DEPTH = 256      // indexable test_flow_id range [0, MAP_DEPTH)
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // CSR programming: entry[wr_addr] = {wr_valid, wr_lfid}.
    input  wire                          wr_en,
    input  wire [$clog2(MAP_DEPTH)-1:0]  wr_addr,
    input  wire                          wr_valid,
    input  wire [$clog2(NUM_FLOWS)-1:0]  wr_lfid,

    // Lookup (per frame): drive the parsed test_flow_id + is_test; the result
    // is registered (1-cycle latency).
    input  wire [31:0]                   flowid_i,
    input  wire                          is_test_i,
    input  wire                          lookup_en_i,
    output logic                         valid_o,
    output logic [$clog2(NUM_FLOWS)-1:0] local_flow_id_o
);

    localparam int AW  = $clog2(MAP_DEPTH);
    localparam int LFW = $clog2(NUM_FLOWS);
    localparam int EW  = 1 + LFW;             // {valid, local_flow_id}

    // Flat bit-vector BRAM (the inference pattern that maps to block RAM).
    (* ram_style = "block" *) logic [EW-1:0] mem [MAP_DEPTH];
    initial begin
        for (int i = 0; i < MAP_DEPTH; i++) mem[i] = '0;
    end

    logic [EW-1:0] rd_q;
    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= {wr_valid, wr_lfid};
        rd_q <= mem[flowid_i[AW-1:0]];
    end

    // Registered gating, aligned with rd_q (1-cycle read latency).
    logic in_range_q, is_test_q, lookup_en_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_range_q <= 1'b0; is_test_q <= 1'b0; lookup_en_q <= 1'b0;
        end else begin
            in_range_q  <= (flowid_i < MAP_DEPTH);
            is_test_q   <= is_test_i;
            lookup_en_q <= lookup_en_i;
        end
    end

    // A hit = a programmed (valid) entry for an in-range test flow_id.
    assign valid_o         = lookup_en_q && is_test_q && in_range_q && rd_q[EW-1];
    assign local_flow_id_o = rd_q[LFW-1:0];

endmodule

`default_nettype wire
