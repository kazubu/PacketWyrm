// PacketWyrm flow generator (Phase 3 skeleton).
//
// Periodically emits a frame matching the configured Ethernet /
// IPv4 / UDP template, with a PacketWyrm test header carrying a
// per-flow sequence counter and the FPGA timestamp at insertion
// time. The IPv4 / UDP header checksums are left zero - the
// simulation classifier does not verify them, and Phase 2 RTL
// recomputes them in the MAC TX path.
//
// Rate control is a proper token bucket:
//   - `tokens_q` is a Q16.16 byte accumulator (16 integer +
//     16 fractional bits = 0..65535 bytes of headroom).
//   - Every cycle, `tokens_per_tick_fp_i` Q16.16 bytes are added.
//   - When `enable_i` is high and `tokens_q >= frame_bytes`, the
//     generator emits a frame and subtracts `frame_bytes` from
//     the bucket.
//   - `burst_bytes_i` caps the bucket so an idle generator does
//     not accumulate arbitrary headroom and then dump a burst at
//     line rate the instant it is enabled.
//
// Worked examples (assuming 100 MHz clock):
//   - 10 Gbps  -> 12.5 bytes/cycle  -> tokens_per_tick_fp = 12*65536 + 32768
//   - 1  Gbps  ->  1.25 byte/cycle  -> tokens_per_tick_fp = 65536 + 16384
//   - 100 Mbps -> 0.125 byte/cycle  -> tokens_per_tick_fp = 8192
//
// Phase 2 RTL recomputes the per-cycle rate from a user-facing
// bps value at config time and writes the fixed-point form here.

`default_nettype none

import pw_axis_pkg::*;

module pw_flow_gen #(
    parameter logic [31:0] GLOBAL_FLOW_ID = 32'd1,
    parameter logic [31:0] LOCAL_FLOW_ID  = 32'd0,
    parameter int          FRAME_LEN_PAYLOAD = 32      // bytes of L4 payload (>= 32 for test_hdr)
) (
    input  wire           clk,
    input  wire           rst_n,

    input  wire           enable_i,
    input  wire [31:0]    tokens_per_tick_fp_i,  // Q16.16 bytes / cycle
    input  wire [15:0]    burst_bytes_i,         // bucket cap in bytes

    input  wire [3:0]     egress_port_i,
    input  wire [47:0]    src_mac_i,
    input  wire [47:0]    dst_mac_i,
    input  wire           vlan_enable_i,
    input  wire [11:0]    vlan_id_i,
    input  wire [31:0]    src_ipv4_i,
    input  wire [31:0]    dst_ipv4_i,
    input  wire [15:0]    udp_src_port_i,
    input  wire [15:0]    udp_dst_port_i,

    input  wire [63:0]    timestamp_i,

    // skeleton AXIS-equivalent egress
    output pw_frame_t     frame_o,
    output logic          frame_valid_o,
    input  wire           frame_ready_i
);

    localparam logic [31:0] PW_TEST_HDR_MAGIC = 32'hA502_7E57;

    /* Total wire bytes per frame (IPv4 + UDP + test_hdr + extra
     * payload). Used as the token-bucket cost per emission. The
     * skeleton frame length is constant; Phase 3 production RTL
     * derives this from the configured frame_len_min/max/step. */
    function automatic int frame_bytes();
        // VLAN tag bytes only when the frame actually carries one
        // (build_frame inserts the tag only when vlan_enable_i).
        return 14 /*ETH*/ + (vlan_enable_i ? 4 : 0) + 20 /*IP*/ + 8 /*UDP*/
             + FRAME_LEN_PAYLOAD;
    endfunction

    logic [63:0]   sequence_q;
    logic [31:0]   tokens_q;        // Q16.16 bytes
    logic          fire;
    pw_frame_t     frame_build;

    wire [31:0] cap_q = {burst_bytes_i, 16'h0};
    wire [31:0] cost_q = {16'(frame_bytes()), 16'h0};
    wire        have_tokens = (tokens_q >= cost_q);
    assign      frame_valid_o = enable_i && have_tokens;
    assign      fire = frame_valid_o && frame_ready_i;

    function automatic pw_frame_t build_frame(input logic [63:0] seq,
                                              input logic [63:0] ts);
        pw_frame_t f;
        int        off;
        int        ihl_bytes;
        int        l4_pay_off;
        int        total_len;

        f = pw_frame_zero();

        // Ethernet
        f.data[0]  = dst_mac_i[47:40];
        f.data[1]  = dst_mac_i[39:32];
        f.data[2]  = dst_mac_i[31:24];
        f.data[3]  = dst_mac_i[23:16];
        f.data[4]  = dst_mac_i[15:8];
        f.data[5]  = dst_mac_i[7:0];
        f.data[6]  = src_mac_i[47:40];
        f.data[7]  = src_mac_i[39:32];
        f.data[8]  = src_mac_i[31:24];
        f.data[9]  = src_mac_i[23:16];
        f.data[10] = src_mac_i[15:8];
        f.data[11] = src_mac_i[7:0];
        off = 12;

        if (vlan_enable_i) begin
            f.data[off + 0] = 8'h81;
            f.data[off + 1] = 8'h00;
            f.data[off + 2] = {4'h0, vlan_id_i[11:8]};
            f.data[off + 3] = vlan_id_i[7:0];
            off = off + 4;
        end

        // IPv4 ethertype
        f.data[off + 0] = 8'h08;
        f.data[off + 1] = 8'h00;
        off = off + 2;

        // IPv4 header (no options) = 20 bytes
        ihl_bytes = 20;
        total_len = ihl_bytes + 8 + FRAME_LEN_PAYLOAD;
        f.data[off + 0]  = 8'h45;
        f.data[off + 1]  = 8'h00;
        f.data[off + 2]  = total_len[15:8];
        f.data[off + 3]  = total_len[7:0];
        f.data[off + 4]  = 8'h00;
        f.data[off + 5]  = 8'h00;
        f.data[off + 6]  = 8'h40;
        f.data[off + 7]  = 8'h00;
        f.data[off + 8]  = 8'h40;  // TTL = 64
        f.data[off + 9]  = 8'h11;  // UDP
        f.data[off + 10] = 8'h00;  // hdr cksum (skeleton)
        f.data[off + 11] = 8'h00;
        f.data[off + 12] = src_ipv4_i[31:24];
        f.data[off + 13] = src_ipv4_i[23:16];
        f.data[off + 14] = src_ipv4_i[15:8];
        f.data[off + 15] = src_ipv4_i[7:0];
        f.data[off + 16] = dst_ipv4_i[31:24];
        f.data[off + 17] = dst_ipv4_i[23:16];
        f.data[off + 18] = dst_ipv4_i[15:8];
        f.data[off + 19] = dst_ipv4_i[7:0];
        off = off + ihl_bytes;

        // UDP
        f.data[off + 0] = udp_src_port_i[15:8];
        f.data[off + 1] = udp_src_port_i[7:0];
        f.data[off + 2] = udp_dst_port_i[15:8];
        f.data[off + 3] = udp_dst_port_i[7:0];
        f.data[off + 4] = ((8 + FRAME_LEN_PAYLOAD) >> 8) & 8'hFF;
        f.data[off + 5] =  (8 + FRAME_LEN_PAYLOAD)       & 8'hFF;
        f.data[off + 6] = 8'h00;
        f.data[off + 7] = 8'h00;
        off = off + 8;
        l4_pay_off = off;

        // test header
        f.data[l4_pay_off + 0]  = PW_TEST_HDR_MAGIC[31:24];
        f.data[l4_pay_off + 1]  = PW_TEST_HDR_MAGIC[23:16];
        f.data[l4_pay_off + 2]  = PW_TEST_HDR_MAGIC[15:8];
        f.data[l4_pay_off + 3]  = PW_TEST_HDR_MAGIC[7:0];
        f.data[l4_pay_off + 4]  = 8'h00;       // version hi
        f.data[l4_pay_off + 5]  = 8'h01;       // version lo
        f.data[l4_pay_off + 6]  = 8'h00;
        f.data[l4_pay_off + 7]  = 8'h00;
        f.data[l4_pay_off + 8]  = GLOBAL_FLOW_ID[31:24];
        f.data[l4_pay_off + 9]  = GLOBAL_FLOW_ID[23:16];
        f.data[l4_pay_off + 10] = GLOBAL_FLOW_ID[15:8];
        f.data[l4_pay_off + 11] = GLOBAL_FLOW_ID[7:0];
        f.data[l4_pay_off + 12] = seq[63:56];
        f.data[l4_pay_off + 13] = seq[55:48];
        f.data[l4_pay_off + 14] = seq[47:40];
        f.data[l4_pay_off + 15] = seq[39:32];
        f.data[l4_pay_off + 16] = seq[31:24];
        f.data[l4_pay_off + 17] = seq[23:16];
        f.data[l4_pay_off + 18] = seq[15:8];
        f.data[l4_pay_off + 19] = seq[7:0];
        f.data[l4_pay_off + 20] = ts[63:56];
        f.data[l4_pay_off + 21] = ts[55:48];
        f.data[l4_pay_off + 22] = ts[47:40];
        f.data[l4_pay_off + 23] = ts[39:32];
        f.data[l4_pay_off + 24] = ts[31:24];
        f.data[l4_pay_off + 25] = ts[23:16];
        f.data[l4_pay_off + 26] = ts[15:8];
        f.data[l4_pay_off + 27] = ts[7:0];

        f.len          = PW_FRAME_LEN_W'(l4_pay_off + FRAME_LEN_PAYLOAD);
        f.ingress_port = egress_port_i;
        return f;
    endfunction

    always_comb frame_build   = build_frame(sequence_q, timestamp_i);
    assign      frame_o       = frame_build;

    always_ff @(posedge clk or negedge rst_n) begin
        automatic logic [32:0] sum;       // 1 extra bit for overflow
        if (!rst_n) begin
            tokens_q   <= '0;
            sequence_q <= '0;
        end else if (!enable_i) begin
            /* Drain the bucket gracefully when disabled so a re-
             * enable doesn't dump the maximum burst on cycle 1. */
            tokens_q   <= '0;
        end else begin
            sum = {1'b0, tokens_q} + {1'b0, tokens_per_tick_fp_i};
            if (fire) begin
                sequence_q <= sequence_q + 64'd1;
                /* On the cycle we emit, we *also* accumulate this
                 * cycle's tokens but then deduct the frame cost. */
                if (sum >= {1'b0, cost_q}) sum = sum - {1'b0, cost_q};
                else                         sum = '0;
            end
            if (sum > {1'b0, cap_q}) sum = {1'b0, cap_q};
            tokens_q <= sum[31:0];
        end
    end

endmodule

`default_nettype wire
