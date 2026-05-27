// PacketWyrm flow generator (Phase 3 skeleton).
//
// Periodically emits a frame matching the configured Ethernet /
// IPv4 / UDP template, with a PacketWyrm test header carrying a
// per-flow sequence counter and the FPGA timestamp at insertion
// time. The IPv4 / UDP header checksums are left zero - the
// simulation classifier does not verify them, and Phase 2 RTL
// recomputes them in the MAC TX path.

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
    input  wire [15:0]    gap_cycles_i,

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

    typedef enum logic [1:0] { S_IDLE, S_WAIT, S_EMIT } state_e;
    state_e        state_q;
    logic [15:0]   gap_cnt_q;
    logic [63:0]   sequence_q;

    pw_frame_t     frame_build;
    logic          fire;

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
    assign      frame_valid_o = (state_q == S_EMIT);
    assign      fire          = frame_valid_o && frame_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q    <= S_IDLE;
            gap_cnt_q  <= '0;
            sequence_q <= '0;
        end else begin
            unique case (state_q)
                S_IDLE: begin
                    if (enable_i) begin
                        state_q   <= S_EMIT;
                        gap_cnt_q <= gap_cycles_i;
                    end
                end
                S_EMIT: begin
                    if (fire) begin
                        sequence_q <= sequence_q + 64'd1;
                        if (!enable_i)             state_q <= S_IDLE;
                        else if (gap_cycles_i == 0) state_q <= S_EMIT;
                        else begin
                            gap_cnt_q <= gap_cycles_i;
                            state_q   <= S_WAIT;
                        end
                    end else if (!enable_i) begin
                        state_q <= S_IDLE;
                    end
                end
                S_WAIT: begin
                    if (!enable_i) state_q <= S_IDLE;
                    else if (gap_cnt_q == 0) state_q <= S_EMIT;
                    else gap_cnt_q <= gap_cnt_q - 16'd1;
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
