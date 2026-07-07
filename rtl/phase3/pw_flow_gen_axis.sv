// PacketWyrm flow generator -- 64-bit AXIS streaming version (Phase 3
// production data path). Functionally equivalent to pw_flow_gen but
// emits the frame as 64-bit AXIS beats instead of one wide pw_frame_t,
// so it routes on real silicon (the wide-bus skeleton did not).
//
// Frame layout matches pw_flow_gen exactly: Ethernet [+VLAN] / IPv4 /
// UDP / 32-byte PacketWyrm test header (magic / version / flow_id /
// seq / timestamp). IP/UDP checksums left zero (the MAC TX recomputes).
// Token-bucket rate control (Q16.16) is unchanged.

`default_nettype none

module pw_flow_gen_axis #(
    parameter logic [31:0] GLOBAL_FLOW_ID    = 32'd1,
    parameter int          FRAME_LEN_PAYLOAD = 32,    // L4 payload bytes (>=32 = test hdr)
    parameter int          HDR_MAX_BYTES     = 96      // frame buffer (>= 14+4+20+8+payload)
) (
    input  wire           clk,
    input  wire           rst_n,

    input  wire           enable_i,
    input  wire [31:0]    tokens_per_tick_fp_i,  // Q16.16 bytes / cycle
    input  wire [15:0]    burst_bytes_i,

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

    // 64-bit AXIS egress
    output logic [63:0]   m_tdata,
    output logic [7:0]    m_tkeep,
    output logic          m_tvalid,
    input  wire           m_tready,
    output logic          m_tlast
);
    localparam logic [31:0] PW_TEST_HDR_MAGIC = 32'hA502_7E57;

    function automatic int frame_bytes(input logic vlen);
        return 14 + (vlen ? 4 : 0) + 20 + 8 + FRAME_LEN_PAYLOAD;
    endfunction

    // Packed byte buffer: fb[i] is wire byte i. Built at frame start.
    logic [HDR_MAX_BYTES-1:0][7:0] fb;
    logic [11:0]                   frame_len;     // bytes this frame
    logic [63:0]                   sequence_q;
    logic [31:0]                   tokens_q;      // Q16.16

    wire [31:0] cap_q  = {burst_bytes_i, 16'h0};
    wire [31:0] cost_q = {16'(frame_bytes(vlan_enable_i)), 16'h0};
    wire        have_tokens = (tokens_q >= cost_q);

    // --- streaming FSM ------------------------------------------------------
    logic         active;          // mid-frame
    logic [11:0]  byte_off;        // next byte offset to emit
    wire          start = enable_i && have_tokens && !active;

    // remaining bytes from byte_off
    wire [11:0]   rem   = frame_len - byte_off;
    wire          last  = active && (rem <= 12'd8);

    // assemble the current 8-byte beat (little-endian on wire: byte k -> [k*8])
    always_comb begin
        m_tdata = '0;
        m_tkeep = '0;
        for (int k = 0; k < 8; k++) begin
            if (({20'b0, byte_off} + k) < {20'b0, frame_len}) begin
                m_tdata[k*8 +: 8] = fb[byte_off + k[11:0]];
                m_tkeep[k]        = 1'b1;
            end
        end
    end
    assign m_tvalid = active;
    assign m_tlast  = last;

    // --- frame builder ------------------------------------------------------
    // Build the header bytes from params + seq + ts into fb at frame start.
    task automatic build(input logic [63:0] seq, input logic [63:0] ts);
        int off; int tl; int total_len;
        for (int i = 0; i < HDR_MAX_BYTES; i++) fb[i] <= 8'h00;
        // Ethernet
        fb[0]<=dst_mac_i[47:40]; fb[1]<=dst_mac_i[39:32]; fb[2]<=dst_mac_i[31:24];
        fb[3]<=dst_mac_i[23:16]; fb[4]<=dst_mac_i[15:8];  fb[5]<=dst_mac_i[7:0];
        fb[6]<=src_mac_i[47:40]; fb[7]<=src_mac_i[39:32]; fb[8]<=src_mac_i[31:24];
        fb[9]<=src_mac_i[23:16]; fb[10]<=src_mac_i[15:8]; fb[11]<=src_mac_i[7:0];
        off = 12;
        if (vlan_enable_i) begin
            fb[off]<=8'h81; fb[off+1]<=8'h00;
            fb[off+2]<={4'h0,vlan_id_i[11:8]}; fb[off+3]<=vlan_id_i[7:0];
            off += 4;
        end
        fb[off]<=8'h08; fb[off+1]<=8'h00; off += 2;            // ethertype IPv4
        total_len = 20 + 8 + FRAME_LEN_PAYLOAD;
        fb[off+0]<=8'h45; fb[off+1]<=8'h00;
        fb[off+2]<=total_len[15:8]; fb[off+3]<=total_len[7:0];
        fb[off+4]<=8'h00; fb[off+5]<=8'h00; fb[off+6]<=8'h40; fb[off+7]<=8'h00;
        fb[off+8]<=8'h40; fb[off+9]<=8'h11; fb[off+10]<=8'h00; fb[off+11]<=8'h00;
        fb[off+12]<=src_ipv4_i[31:24]; fb[off+13]<=src_ipv4_i[23:16];
        fb[off+14]<=src_ipv4_i[15:8];  fb[off+15]<=src_ipv4_i[7:0];
        fb[off+16]<=dst_ipv4_i[31:24]; fb[off+17]<=dst_ipv4_i[23:16];
        fb[off+18]<=dst_ipv4_i[15:8];  fb[off+19]<=dst_ipv4_i[7:0];
        off += 20;
        fb[off+0]<=udp_src_port_i[15:8]; fb[off+1]<=udp_src_port_i[7:0];
        fb[off+2]<=udp_dst_port_i[15:8]; fb[off+3]<=udp_dst_port_i[7:0];
        tl = 8 + FRAME_LEN_PAYLOAD;
        fb[off+4]<=tl[15:8]; fb[off+5]<=tl[7:0]; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
        off += 8;
        // test header
        fb[off+0]<=PW_TEST_HDR_MAGIC[31:24]; fb[off+1]<=PW_TEST_HDR_MAGIC[23:16];
        fb[off+2]<=PW_TEST_HDR_MAGIC[15:8];  fb[off+3]<=PW_TEST_HDR_MAGIC[7:0];
        fb[off+4]<=8'h00; fb[off+5]<=8'h01; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
        fb[off+8]<=GLOBAL_FLOW_ID[31:24]; fb[off+9]<=GLOBAL_FLOW_ID[23:16];
        fb[off+10]<=GLOBAL_FLOW_ID[15:8]; fb[off+11]<=GLOBAL_FLOW_ID[7:0];
        fb[off+12]<=seq[63:56]; fb[off+13]<=seq[55:48]; fb[off+14]<=seq[47:40]; fb[off+15]<=seq[39:32];
        fb[off+16]<=seq[31:24]; fb[off+17]<=seq[23:16]; fb[off+18]<=seq[15:8];  fb[off+19]<=seq[7:0];
        fb[off+20]<=ts[63:56]; fb[off+21]<=ts[55:48]; fb[off+22]<=ts[47:40]; fb[off+23]<=ts[39:32];
        fb[off+24]<=ts[31:24]; fb[off+25]<=ts[23:16]; fb[off+26]<=ts[15:8];  fb[off+27]<=ts[7:0];
        frame_len <= 12'(20 + 8 + 14 + (vlan_enable_i ? 4 : 0) + (FRAME_LEN_PAYLOAD - 32) + 32);
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        automatic logic [32:0] sum;
        if (!rst_n) begin
            active <= 1'b0; byte_off <= '0; sequence_q <= '0; tokens_q <= '0;
        end else begin
            // token bucket
            if (!enable_i) begin
                tokens_q <= '0;
            end else begin
                sum = {1'b0, tokens_q} + {1'b0, tokens_per_tick_fp_i};
                if (sum > {1'b0, cap_q}) sum = {1'b0, cap_q};
                tokens_q <= sum[31:0];
            end

            if (!active) begin
                if (start) begin
                    build(sequence_q, timestamp_i);
                    active   <= 1'b1;
                    byte_off <= '0;
                    // Deduct the frame cost from this cycle's (cap-clamped)
                    // accrual. 33-bit `sum` (same pattern as pw_flow_gen /
                    // pw_flow_gen_multi): a plain 32-bit tokens_q +
                    // tokens_per_tick_fp_i wraps when the bucket is near cap
                    // and would zero the bucket instead of deducting.
                    if (sum >= {1'b0, cost_q})
                        tokens_q <= 32'(sum - {1'b0, cost_q});
                    else
                        tokens_q <= '0;
                end
            end else if (m_tready) begin
                if (last) begin
                    active     <= 1'b0;
                    sequence_q <= sequence_q + 64'd1;
                end else begin
                    byte_off <= byte_off + 12'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
