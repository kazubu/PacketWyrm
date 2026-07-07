// Serializer / deserializer between the wide single-beat
// `pw_frame_t` used by the Phase 3 skeleton data plane and a 64-bit
// AXI-Stream bus that closer-to-production RTL (a 10G MAC/PCS) uses.
//
// This module is a Phase-2 stepping stone. It does not represent
// any clock-domain crossing, MAC framing, FCS, or interpacket
// gap; the production MAC handles those. What it does cover is
// the SOP / EOP / TKEEP / packing logic that production downstream
// modules will see, so a future swap from "wide single-beat" to
// "64-bit narrow AXIS" doesn't surprise anyone.

`default_nettype none

import pw_axis_pkg::*;

// Wide -> 64-bit AXIS (transmit). Holds a pw_frame_t, emits one
// 8-byte beat per clock until the frame is drained.
module pw_axis_serializer (
    input  wire           clk,
    input  wire           rst_n,

    input  pw_frame_t     frame_i,
    input  wire           frame_valid_i,
    output logic          frame_ready_o,   // accepts next frame when idle

    output logic [63:0]   m_tdata,
    output logic [7:0]    m_tkeep,
    output logic          m_tvalid,
    input  wire           m_tready,
    output logic          m_tlast
);

    typedef enum logic [1:0] { S_IDLE, S_RUN } state_e;
    state_e        state_q;
    pw_frame_t     buf_q;
    logic [11:0]   off_q;        // next byte offset to emit
    logic          last_beat;
    logic [3:0]    valid_bytes;

    assign frame_ready_o = (state_q == S_IDLE);

    function automatic logic [7:0] keep_from_count(input int n);
        case (n)
            1: return 8'b0000_0001;
            2: return 8'b0000_0011;
            3: return 8'b0000_0111;
            4: return 8'b0000_1111;
            5: return 8'b0001_1111;
            6: return 8'b0011_1111;
            7: return 8'b0111_1111;
            default: return 8'b1111_1111;
        endcase
    endfunction

    int remaining;
    always_comb begin
        m_tvalid = 1'b0;
        m_tdata  = '0;
        m_tkeep  = '0;
        m_tlast  = 1'b0;
        valid_bytes = 0;
        last_beat = 1'b0;
        remaining = 0;
        if (state_q == S_RUN) begin
            remaining = int'(buf_q.len) - int'(off_q);
            if (remaining > 8) begin
                valid_bytes = 8;
            end else begin
                valid_bytes = remaining[3:0];
                last_beat   = 1'b1;
            end
            m_tvalid = 1'b1;
            m_tkeep  = keep_from_count(int'(valid_bytes));
            m_tlast  = last_beat;
            // Pack 8 wire-order bytes into a 64-bit word using the
            // standard AXI-Stream lane convention: wire byte k in
            // tdata[k*8 +: 8], qualified by tkeep[k]. This matches the
            // production data path (pw_flow_gen_multi / pw_ts_insert)
            // and makes keep_from_count's low-lane tkeep correct on a
            // partial last beat.
            for (int k = 0; k < 8; k++) begin
                if (k < int'(valid_bytes))
                    m_tdata[k*8 +: 8] = buf_q.data[off_q + k];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            off_q   <= '0;
            buf_q   <= '0;
        end else begin
            unique case (state_q)
                S_IDLE: begin
                    if (frame_valid_i && frame_i.len > 0) begin
                        buf_q   <= frame_i;
                        off_q   <= '0;
                        state_q <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (m_tvalid && m_tready) begin
                        if (last_beat) begin
                            state_q <= S_IDLE;
                            off_q   <= '0;
                        end else begin
                            off_q <= off_q + 12'd8;
                        end
                    end
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule

// 64-bit AXIS -> wide. Accumulates beats into a pw_frame_t and
// emits it on TLAST.
module pw_axis_deserializer (
    input  wire           clk,
    input  wire           rst_n,

    input  wire [63:0]    s_tdata,
    input  wire [7:0]     s_tkeep,
    input  wire           s_tvalid,
    output logic          s_tready,
    input  wire           s_tlast,

    output pw_frame_t     frame_o,
    output logic          frame_valid_o,
    input  wire [3:0]     ingress_port_i
);

    pw_frame_t     buf_q;
    logic [11:0]   off_q;
    logic          done_q;

    assign s_tready    = 1'b1;
    assign frame_valid_o = done_q;
    assign frame_o     = buf_q;

    function automatic int popcount8(input logic [7:0] x);
        int n;
        n = 0;
        for (int i = 0; i < 8; i++) if (x[i]) n++;
        return n;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_q  <= '0;
            off_q  <= '0;
            done_q <= 1'b0;
        end else begin
            done_q <= 1'b0;
            if (s_tvalid && s_tready) begin
                int bytes_this_beat;
                bytes_this_beat = popcount8(s_tkeep);
                // Standard AXI-Stream lane convention: wire byte k rides
                // in tdata[k*8 +: 8] and is qualified by tkeep[k]
                // (mirrors the serializer above and the production path).
                for (int k = 0; k < 8; k++) begin
                    if (s_tkeep[k])
                        buf_q.data[off_q + k] <= s_tdata[k*8 +: 8];
                end
                if (s_tlast) begin
                    buf_q.len          <= PW_FRAME_LEN_W'(off_q + bytes_this_beat);
                    buf_q.ingress_port <= ingress_port_i;
                    off_q              <= '0;
                    done_q             <= 1'b1;
                end else begin
                    off_q <= off_q + 12'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
