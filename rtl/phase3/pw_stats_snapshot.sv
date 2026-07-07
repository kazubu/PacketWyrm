// PacketWyrm stats snapshot window.
//
// On `trigger_i` (a write of 1 to PWFPGA_REG_STATS_SNAPSHOT_TRIGGER
// at the parent AXI-Lite slave), the live per-flow counters from
// `pw_test_rx_checker` and the live per-port counters from the
// data plane are atomically copied into a shadow byte region that
// mirrors the wire format of `struct pw_port_stats` / `struct
// pw_flow_stats` defined in backend.h.
//
// The host reads through `rd_addr_i / rd_data_o`. Addresses are
// relative to the start of the snapshot window (PWFPGA_WIN_STATS
// _SNAPSHOT). Layout:
//
//   0x000..0x07F   port 0 stats (128 B, packed pw_port_stats)
//   0x080..0x0FF   port 1 stats (...)
//   0x100..0x17F   flow 0 stats (128 B, packed pw_flow_stats)
//   0x180..0x1FF   flow 1 stats
//   ...
//
// Wire offsets within pw_flow_stats:
//      0  tx_frames           (u64)
//      8  tx_bytes            (u64)
//     16  rx_frames           (u64)
//     24  rx_bytes            (u64)
//     32  expected_sequence   (u64)
//     40  sequence_gap_count  (u64)
//     48  lost_packets_estim  (u64)
//     56  duplicate_count     (u64)
//     64  out_of_order_count  (u64)
//     72  late_packet_count   (u64)
//     80  min_latency         (u32)
//     84  max_latency         (u32)
//     88  sum_latency         (u64)
//     96  sample_count        (u64)
//    104  jitter_min          (u32)
//    108  jitter_max          (u32)
//    112  jitter_sum          (u64)
//
// Per-port rx/tx frames+bytes are produced (pw_data_plane_axis port
// counters); port_drops lands in rx_bad_frame@24; rx_fcs_error@16 counts
// MAC tuser-on-tlast errored frames; link_up_count@64/link_down_count@68/
// block_lock_loss@72 are link-health transition counts. Per-flow jitter
// (jitter_min@104/max@108/sum@112) is produced by pw_test_rx_checker
// (RFC-3393 IPDV over consecutive samples). Fields still not produced
// (oversize / undersize) are zeroed in the snapshot.

`default_nettype none

module pw_stats_snapshot #(
    parameter int PORTS         = 2,
    parameter int NUM_FLOWS     = 8,
    parameter int PORT_STRIDE   = 128,
    parameter int FLOW_STRIDE   = 128,
    parameter int FLOW_BASE     = 256   // PWFPGA_FLOW_STATS_BASE = 0x100
) (
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       trigger_i,

    input  wire [31:0]                port_drops_i [PORTS],
    input  wire [47:0]                rx_frames_i  [PORTS],
    input  wire [47:0]                rx_bytes_i   [PORTS],
    input  wire [47:0]                tx_frames_i  [PORTS],
    input  wire [47:0]                tx_bytes_i   [PORTS],
    input  wire [47:0]                rx_fcs_err_i [PORTS],
    input  wire [31:0]                link_up_cnt_i    [PORTS],
    input  wire [31:0]                link_down_cnt_i  [PORTS],
    input  wire [31:0]                block_lock_loss_i[PORTS],
    // Unmatched-frame counter + last-unmatched capture (per-port block bytes
    // 76..87). port_drops_i above = real drops (SAF overflow); rx_unmatched is
    // informational (classifier no-match) and is NOT a drop.
    input  wire [31:0]                rx_unmatched_i       [PORTS],
    input  wire [31:0]                last_unmatched_ctx_i [PORTS],
    input  wire [31:0]                last_unmatched_fid_i [PORTS],

    // Per-flow stats are BRAM-backed in the data plane and read one flow at a
    // time. The snapshot drives flow_rd_addr_o and the merged record arrives
    // FLOW_RD_LAT cycles later; on trigger it walks 0..NUM_FLOWS-1 into the
    // shadow. All fields are scalars (the record for flow_rd_addr_o).
    output logic [$clog2(NUM_FLOWS)-1:0] flow_rd_addr_o,
    input  wire [63:0]                flow_rx_i,
    input  wire [63:0]                flow_lost_i,
    input  wire [63:0]                flow_dup_i,
    input  wire [63:0]                flow_ooo_i,
    input  wire [63:0]                flow_last_seq_i,
    input  wire [63:0]                flow_min_lat_i,
    input  wire [63:0]                flow_max_lat_i,
    input  wire [63:0]                flow_sum_lat_i,
    input  wire [63:0]                flow_samples_i,
    input  wire [47:0]                flow_tx_i,
    input  wire [63:0]                flow_tx_bytes_i,
    input  wire [63:0]                flow_rx_bytes_i,
    input  wire [31:0]                flow_jit_min_i,
    input  wire [31:0]                flow_jit_max_i,
    input  wire [63:0]                flow_jit_sum_i,

    input  wire [15:0]                rd_addr_i,
    output logic [31:0]               rd_data_o
);

    // flow_rd_addr_o -> flow_*_i latency (data plane: 1 checker read + 1 merge
    // register). The walk captures the record for the address issued this many
    // cycles earlier.
    localparam int FLOW_RD_LAT = 2;
    localparam int AW = $clog2(NUM_FLOWS);

    // Packed byte arrays so the read mux can use byte-aligned indexing
    // without unpacked-array gotchas.
    logic [PORTS-1:0]    [PORT_STRIDE*8-1:0] shadow_port;
    logic [NUM_FLOWS-1:0][FLOW_STRIDE*8-1:0] shadow_flow;

    // Helper functions: write little-endian fields into a row.
    function automatic logic [FLOW_STRIDE*8-1:0]
        put_u64(input logic [FLOW_STRIDE*8-1:0] row, input int off,
                input logic [63:0] v);
        logic [FLOW_STRIDE*8-1:0] o;
        o = row;
        o[off*8 +: 64] = v;
        return o;
    endfunction

    function automatic logic [FLOW_STRIDE*8-1:0]
        put_u32(input logic [FLOW_STRIDE*8-1:0] row, input int off,
                input logic [31:0] v);
        logic [FLOW_STRIDE*8-1:0] o;
        o = row;
        o[off*8 +: 32] = v;
        return o;
    endfunction

    function automatic logic [PORT_STRIDE*8-1:0]
        put_u32_port(input logic [PORT_STRIDE*8-1:0] row, input int off,
                     input logic [31:0] v);
        logic [PORT_STRIDE*8-1:0] o;
        o = row;
        o[off*8 +: 32] = v;
        return o;
    endfunction

    // Flow-block walk: on trigger, issue addresses 0..NUM_FLOWS-1 (one/cycle)
    // and capture each merged record FLOW_RD_LAT cycles later. The port block
    // latches atomically on the trigger (small FF arrays).
    logic        walking;
    logic [15:0] wcnt;

    always_comb begin
        flow_rd_addr_o = (walking && wcnt < NUM_FLOWS) ? wcnt[AW-1:0] : '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_port <= '0;
            shadow_flow <= '0;
            walking <= 1'b0;
            wcnt    <= '0;
        end else if (trigger_i) begin
            for (int p = 0; p < PORTS; p++) begin
                logic [PORT_STRIDE*8-1:0] pr;
                pr = '0;
                // pw_port_stats layout: rx_frames@0, rx_bytes@8, rx_fcs_error@16,
                // rx_bad_frame@24 (= real drops: SAF overflow), ..., tx_frames@48,
                // tx_bytes@56, link counters @64/68/72, rx_unmatched@76,
                // last_unmatched_ctx@80, last_unmatched_flowid@84. 48-bit -> u64.
                pr = put_u64(pr,  0, {16'h0, rx_frames_i[p]});
                pr = put_u64(pr,  8, {16'h0, rx_bytes_i[p]});
                pr = put_u64(pr, 16, {16'h0, rx_fcs_err_i[p]});  // rx_fcs_error
                pr = put_u32_port(pr, 24, port_drops_i[p]);   // rx_bad_frame slot
                pr = put_u64(pr, 48, {16'h0, tx_frames_i[p]});
                pr = put_u64(pr, 56, {16'h0, tx_bytes_i[p]});
                pr = put_u32_port(pr, 64, link_up_cnt_i[p]);     // link_up_count
                pr = put_u32_port(pr, 68, link_down_cnt_i[p]);   // link_down_count
                pr = put_u32_port(pr, 72, block_lock_loss_i[p]); // block_lock_loss
                pr = put_u32_port(pr, 76, rx_unmatched_i[p]);       // rx_unmatched
                pr = put_u32_port(pr, 80, last_unmatched_ctx_i[p]); // last_unmatched_ctx
                pr = put_u32_port(pr, 84, last_unmatched_fid_i[p]); // last_unmatched_flowid
                shadow_port[p] <= pr;
            end
            walking <= 1'b1;
            wcnt    <= '0;
        end else if (walking) begin
            if (wcnt >= FLOW_RD_LAT) begin
                logic [FLOW_STRIDE*8-1:0] fr;
                fr = '0;
                fr = put_u64(fr,   0, {16'h0, flow_tx_i});    // tx_frames (emitted)
                fr = put_u64(fr,   8, flow_tx_bytes_i);       // tx_bytes (emitted)
                fr = put_u64(fr,  16, flow_rx_i);             // rx_frames
                fr = put_u64(fr,  24, flow_rx_bytes_i);       // rx_bytes
                fr = put_u64(fr,  32, flow_last_seq_i);       // last_sequence (last received)
                fr = put_u64(fr,  48, flow_lost_i);           // lost_packets_estimated
                fr = put_u64(fr,  56, flow_dup_i);            // duplicate_count
                fr = put_u64(fr,  64, flow_ooo_i);            // out_of_order_count
                fr = put_u32(fr,  80, flow_min_lat_i[31:0]);  // min_latency
                fr = put_u32(fr,  84, flow_max_lat_i[31:0]);  // max_latency
                fr = put_u64(fr,  88, flow_sum_lat_i);        // sum_latency
                fr = put_u64(fr,  96, flow_samples_i);        // sample_count
                fr = put_u32(fr, 104, flow_jit_min_i);        // jitter_min
                fr = put_u32(fr, 108, flow_jit_max_i);        // jitter_max
                fr = put_u64(fr, 112, flow_jit_sum_i);        // jitter_sum
                shadow_flow[(wcnt - FLOW_RD_LAT)] <= fr;
            end
            if (wcnt == 16'(NUM_FLOWS - 1 + FLOW_RD_LAT)) walking <= 1'b0;
            wcnt <= wcnt + 16'd1;
        end
    end

    // Read mux. Returns the dword starting at the requested byte
    // offset, little-endian. Out-of-range addresses return 0.
    always_comb begin
        logic [15:0] off;
        logic [15:0] flow_idx;
        logic [15:0] flow_off;
        logic [15:0] port_idx;
        logic [15:0] port_off;
        off       = rd_addr_i & 16'hFFFC;   // dword-align
        flow_idx  = '0;
        flow_off  = '0;
        port_idx  = '0;
        port_off  = '0;
        rd_data_o = 32'h0;
        if (off < FLOW_BASE) begin
            port_idx = off / PORT_STRIDE;
            port_off = off - port_idx * PORT_STRIDE;
            if (port_idx < PORTS && port_off + 4 <= PORT_STRIDE) begin
                rd_data_o = shadow_port[port_idx][port_off*8 +: 32];
            end
        end else begin
            flow_idx = (off - FLOW_BASE) / FLOW_STRIDE;
            flow_off = (off - FLOW_BASE) - flow_idx * FLOW_STRIDE;
            if (flow_idx < NUM_FLOWS && flow_off + 4 <= FLOW_STRIDE) begin
                rd_data_o = shadow_flow[flow_idx][flow_off*8 +: 32];
            end
        end
    end

endmodule

`default_nettype wire
