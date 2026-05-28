// Behavioral flow generator for cocotb unit testing.
//
// Implements the token-bucket rate control and frame construction logic
// from rtl/phase3/pw_flow_gen.sv using only Icarus-compatible constructs.
// Output frame exposed as a flat 1024-bit signal (byte N at bits [8N+7:8N]).
//
// Action (PW_TEST_HDR) test header layout at UDP payload offset 0:
//   +0..3   magic  (0xA502_7E57)
//   +4..7   version/flags (0x0001_0000)
//   +8..11  global_flow_id (big-endian)
//  +12..19  sequence (big-endian u64)
//  +20..27  tx_timestamp (big-endian u64)

`timescale 1ns/1ps
`default_nettype none

module pw_flow_gen_beh #(
    parameter [31:0] GLOBAL_FLOW_ID    = 32'd1,
    parameter [31:0] LOCAL_FLOW_ID     = 32'd0,
    parameter integer FRAME_LEN_PAYLOAD = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    // Rate control
    input  wire        enable,
    input  wire [31:0] tokens_fp,   // Q16.16 bytes/cycle
    input  wire [15:0] burst_bytes,

    // Frame header template
    input  wire [3:0]  egress_port,
    input  wire [47:0] src_mac,
    input  wire [47:0] dst_mac,
    input  wire        vlan_en,
    input  wire [11:0] vlan_id,
    input  wire [31:0] src_ip,
    input  wire [31:0] dst_ip,
    input  wire [15:0] udp_sport,
    input  wire [15:0] udp_dport,
    input  wire [63:0] timestamp,

    // Output frame
    output reg [1023:0] frame_flat,
    output reg [10:0]   frame_len,
    output reg          frame_valid
);

    // Total bytes per frame (Eth + [VLAN] + IP + UDP + payload)
    // Matches the formula in pw_flow_gen.sv frame_bytes() function.
    function [10:0] total_frame_bytes;
        input v_en;
        total_frame_bytes = 11'd14 + (v_en ? 11'd4 : 11'd0) +
                            11'd20 + 11'd8 + FRAME_LEN_PAYLOAD[10:0];
    endfunction

    // Token bucket state
    reg [63:0] sequence_q;
    reg [32:0] tokens_q;   // extra bit for addition overflow

    wire [32:0] cap     = {burst_bytes, 17'h0};   // burst_bytes Q16.16
    wire [32:0] cost    = {total_frame_bytes(vlan_en), 16'h0};
    wire [32:0] tok_sum = tokens_q + {1'b0, tokens_fp};
    wire        have_tok = (tokens_q >= cost);

    // Build frame bytes into frame_flat combinatorially from sequence/ts
    // (updated one cycle after emission; Verilator/Icarus differ slightly
    // but the test only checks values after stable state).
    //
    // We encode byte N at flat bits [8N+7:8N].

    function [1023:0] build_frame;
        input [63:0] seq;
        input [63:0] ts;
        input v_en;
        reg [1023:0] f;
        integer off;
        integer total;
        begin
            f = 1024'h0;
            // dst MAC
            f[0*8+:8] = dst_mac[47:40]; f[1*8+:8] = dst_mac[39:32];
            f[2*8+:8] = dst_mac[31:24]; f[3*8+:8] = dst_mac[23:16];
            f[4*8+:8] = dst_mac[15:8];  f[5*8+:8] = dst_mac[7:0];
            // src MAC
            f[6*8+:8] = src_mac[47:40]; f[7*8+:8] = src_mac[39:32];
            f[8*8+:8] = src_mac[31:24]; f[9*8+:8] = src_mac[23:16];
            f[10*8+:8] = src_mac[15:8]; f[11*8+:8] = src_mac[7:0];
            off = 12;
            if (v_en) begin
                f[off*8+:8] = 8'h81; f[(off+1)*8+:8] = 8'h00;
                f[(off+2)*8+:8] = {4'h0, vlan_id[11:8]};
                f[(off+3)*8+:8] = vlan_id[7:0];
                off = off + 4;
            end
            // IPv4 ethertype
            f[off*8+:8] = 8'h08; f[(off+1)*8+:8] = 8'h00;
            off = off + 2;
            // IPv4 header
            total = 20 + 8 + FRAME_LEN_PAYLOAD;
            f[off*8+:8]     = 8'h45; f[(off+1)*8+:8] = 8'h00;
            f[(off+2)*8+:8] = total[15:8]; f[(off+3)*8+:8] = total[7:0];
            f[(off+4)*8+:8] = 8'h00; f[(off+5)*8+:8] = 8'h00;
            f[(off+6)*8+:8] = 8'h40; f[(off+7)*8+:8] = 8'h00;
            f[(off+8)*8+:8] = 8'h40;  // TTL=64
            f[(off+9)*8+:8] = 8'h11;  // UDP
            f[(off+10)*8+:8]= 8'h00; f[(off+11)*8+:8] = 8'h00;  // cksum
            f[(off+12)*8+:8]= src_ip[31:24]; f[(off+13)*8+:8]= src_ip[23:16];
            f[(off+14)*8+:8]= src_ip[15:8];  f[(off+15)*8+:8]= src_ip[7:0];
            f[(off+16)*8+:8]= dst_ip[31:24]; f[(off+17)*8+:8]= dst_ip[23:16];
            f[(off+18)*8+:8]= dst_ip[15:8];  f[(off+19)*8+:8]= dst_ip[7:0];
            off = off + 20;
            // UDP header
            f[off*8+:8]     = udp_sport[15:8]; f[(off+1)*8+:8] = udp_sport[7:0];
            f[(off+2)*8+:8] = udp_dport[15:8]; f[(off+3)*8+:8] = udp_dport[7:0];
            f[(off+4)*8+:8] = 8'h00; f[(off+5)*8+:8] = 8'h00;  // len
            f[(off+6)*8+:8] = 8'h00; f[(off+7)*8+:8] = 8'h00;  // cksum
            off = off + 8;
            // PacketWyrm test header
            f[off*8+:8]     = 8'hA5; f[(off+1)*8+:8] = 8'h02;
            f[(off+2)*8+:8] = 8'h7E; f[(off+3)*8+:8] = 8'h57;
            f[(off+4)*8+:8] = 8'h00; f[(off+5)*8+:8] = 8'h01;  // version
            f[(off+6)*8+:8] = 8'h00; f[(off+7)*8+:8] = 8'h00;
            f[(off+8)*8+:8] = GLOBAL_FLOW_ID[31:24];
            f[(off+9)*8+:8] = GLOBAL_FLOW_ID[23:16];
            f[(off+10)*8+:8]= GLOBAL_FLOW_ID[15:8];
            f[(off+11)*8+:8]= GLOBAL_FLOW_ID[7:0];
            f[(off+12)*8+:8]= seq[63:56]; f[(off+13)*8+:8]= seq[55:48];
            f[(off+14)*8+:8]= seq[47:40]; f[(off+15)*8+:8]= seq[39:32];
            f[(off+16)*8+:8]= seq[31:24]; f[(off+17)*8+:8]= seq[23:16];
            f[(off+18)*8+:8]= seq[15:8];  f[(off+19)*8+:8]= seq[7:0];
            f[(off+20)*8+:8]= ts[63:56];  f[(off+21)*8+:8]= ts[55:48];
            f[(off+22)*8+:8]= ts[47:40];  f[(off+23)*8+:8]= ts[39:32];
            f[(off+24)*8+:8]= ts[31:24];  f[(off+25)*8+:8]= ts[23:16];
            f[(off+26)*8+:8]= ts[15:8];   f[(off+27)*8+:8]= ts[7:0];
            build_frame = f;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sequence_q <= 64'd0;
            tokens_q   <= 33'd0;
            frame_valid <= 1'b0;
            frame_flat  <= 1024'd0;
            frame_len   <= 11'd0;
        end else begin
            frame_valid <= 1'b0;
            if (!enable) begin
                tokens_q <= 33'd0;
            end else begin
                // Accumulate tokens
                if (tok_sum > cap)
                    tokens_q <= cap;
                else
                    tokens_q <= tok_sum;
                // Emit frame when enough tokens
                if (have_tok) begin
                    frame_flat  <= build_frame(sequence_q, timestamp, vlan_en);
                    frame_len   <= total_frame_bytes(vlan_en);
                    frame_valid <= 1'b1;
                    tokens_q    <= tok_sum - cost;
                    sequence_q  <= sequence_q + 64'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
