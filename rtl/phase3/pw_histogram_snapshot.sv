// PacketWyrm per-flow histogram snapshot.
//
// Shares the snapshot trigger with `pw_stats_snapshot` and stores
// the per-flow latency histogram bucket array (from
// pw_test_rx_checker) in a shadow byte region whose layout
// matches the host's expectation:
//
//   PWFPGA_WIN_HISTOGRAM + lfid * PWFPGA_FLOW_HIST_STRIDE  (512 B)
//
// Buckets are 64 bits each and live little-endian. The bucket
// count (NUM_BUCKETS) is parameterised; the host reports up to
// `PWFPGA_FLOW_HIST_STRIDE / 8` = 64 buckets.

`default_nettype none

module pw_histogram_snapshot #(
    parameter int NUM_FLOWS   = 8,
    parameter int NUM_BUCKETS = 16,
    parameter int HIST_STRIDE = 512   // bytes per flow
) (
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       trigger_i,

    // Flattened histogram input: NUM_FLOWS * NUM_BUCKETS u64s,
    // matching the `flow_hist [PW_NUM_FLOWS * PW_NUM_BUCKETS]`
    // port on pw_data_plane.
    input  wire [63:0]                hist_i [NUM_FLOWS * NUM_BUCKETS],

    input  wire [15:0]                rd_addr_i,
    output logic [31:0]               rd_data_o
);

    logic [NUM_FLOWS-1:0][HIST_STRIDE*8-1:0] shadow;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow <= '0;
        end else if (trigger_i) begin
            for (int f = 0; f < NUM_FLOWS; f++) begin
                logic [HIST_STRIDE*8-1:0] row;
                row = '0;
                for (int b = 0; b < NUM_BUCKETS; b++) begin
                    row[b*64 +: 64] = hist_i[f * NUM_BUCKETS + b];
                end
                shadow[f] <= row;
            end
        end
    end

    always_comb begin
        logic [15:0] off;
        logic [15:0] flow_idx;
        logic [15:0] flow_off;
        off       = rd_addr_i & 16'hFFFC;
        flow_idx  = '0;
        flow_off  = '0;
        rd_data_o = 32'h0;
        flow_idx = off / HIST_STRIDE;
        flow_off = off - flow_idx * HIST_STRIDE;
        if (flow_idx < NUM_FLOWS && flow_off + 4 <= HIST_STRIDE) begin
            rd_data_o = shadow[flow_idx][flow_off*8 +: 32];
        end
    end

endmodule

`default_nettype wire
