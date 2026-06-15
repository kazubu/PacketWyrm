// PacketWyrm multi-flow generator -- 64-bit AXIS, N flow slots per egress
// port. Generalises pw_flow_gen_axis: instead of one hardwired flow, it
// holds NUM_SLOTS independent flow templates (MAC/VLAN/IPv4/UDP + flow_id),
// each with its own sequence counter and Q16.16 token bucket, and
// round-robins eligible flows onto the single AXIS output. This lets one
// egress port carry several concurrent test flows (the single-template
// pw_flow_gen_axis could only emit one flow_id per port).
//
// Frame layout per flow matches pw_flow_gen_axis exactly: Ethernet [+VLAN]
// / IPv4 / UDP / 32-byte PacketWyrm test header (magic / version / flow_id
// / seq / timestamp). IP/UDP checksums left zero (MAC TX recomputes).
//
// Scheduling: a flow slot is eligible when enabled and its bucket holds at
// least one frame's cost. A round-robin pointer picks the next eligible
// slot at each frame boundary, so concurrent flows share the port fairly;
// each flow's average rate is still governed by its own token bucket.

`default_nettype none

module pw_flow_gen_multi #(
    parameter int NUM_SLOTS         = 8,
    parameter int FRAME_LEN_PAYLOAD = 32,    // L4 payload bytes (>=32 = test hdr)
    parameter int HDR_MAX_BYTES     = 96
) (
    input  wire           clk,
    input  wire           rst_n,

    input  wire [63:0]    timestamp_i,

    // Per-slot flow templates (slot enabled => this port generates it).
    input  wire           f_enable_i   [NUM_SLOTS],
    input  wire [31:0]    f_flow_id_i  [NUM_SLOTS],
    input  wire [31:0]    f_tokens_fp_i[NUM_SLOTS],   // Q16.16 bytes / cycle
    input  wire [15:0]    f_burst_i    [NUM_SLOTS],   // bucket cap, bytes
    input  wire [47:0]    f_src_mac_i  [NUM_SLOTS],
    input  wire [47:0]    f_dst_mac_i  [NUM_SLOTS],
    input  wire           f_vlan_en_i  [NUM_SLOTS],
    input  wire [11:0]    f_vlan_id_i  [NUM_SLOTS],
    input  wire [31:0]    f_src_ipv4_i [NUM_SLOTS],
    input  wire [31:0]    f_dst_ipv4_i [NUM_SLOTS],
    input  wire [15:0]    f_udp_sp_i   [NUM_SLOTS],
    input  wire [15:0]    f_udp_dp_i   [NUM_SLOTS],

    // 64-bit AXIS egress
    output logic [63:0]   m_tdata,
    output logic [7:0]    m_tkeep,
    output logic          m_tvalid,
    input  wire           m_tready,
    output logic          m_tlast
);
    localparam logic [31:0] PW_TEST_HDR_MAGIC = 32'hA502_7E57;
    localparam int          SELW = $clog2(NUM_SLOTS);

    function automatic int frame_bytes(input logic vlen);
        return 14 + (vlen ? 4 : 0) + 20 + 8 + FRAME_LEN_PAYLOAD;
    endfunction

    // Per-slot state.
    logic [63:0] sequence_q [NUM_SLOTS];
    logic [31:0] tokens_q   [NUM_SLOTS];   // Q16.16

    // In-flight frame (built from the selected slot at frame start).
    logic [HDR_MAX_BYTES-1:0][7:0] fb;
    logic [11:0]                   frame_len;
    logic [SELW-1:0]               sel;       // slot currently emitting
    logic                          active;
    logic [11:0]                   byte_off;

    // Per-slot eligibility (enabled and bucket covers one frame).
    logic [NUM_SLOTS-1:0] eligible;
    always_comb begin
        for (int s = 0; s < NUM_SLOTS; s++) begin
            automatic logic [31:0] cost = {16'(frame_bytes(f_vlan_en_i[s])), 16'h0};
            eligible[s] = f_enable_i[s] && (tokens_q[s] >= cost);
        end
    end

    // Round-robin pick: next eligible slot at/after rr_ptr.
    logic [SELW-1:0] rr_ptr;
    logic [SELW-1:0] pick;
    logic            pick_valid;
    always_comb begin
        pick       = '0;
        pick_valid = 1'b0;
        for (int i = NUM_SLOTS - 1; i >= 0; i--) begin
            // i counts down so the *earliest* slot in round-robin order wins
            // (offset from rr_ptr, wrapping).
            automatic int idx = (int'(rr_ptr) + i) % NUM_SLOTS;
            if (eligible[idx]) begin
                pick       = SELW'(idx);
                pick_valid = 1'b1;
            end
        end
    end

    wire start = !active && pick_valid;

    // remaining bytes / current beat
    wire [11:0] rem  = frame_len - byte_off;
    wire        last = active && (rem <= 12'd8);

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

    // Build a slot's frame into fb at frame start.
    task automatic build(input int s, input logic [63:0] seq, input logic [63:0] ts);
        int off, tl, total_len;
        for (int i = 0; i < HDR_MAX_BYTES; i++) fb[i] <= 8'h00;
        fb[0]<=f_dst_mac_i[s][47:40]; fb[1]<=f_dst_mac_i[s][39:32]; fb[2]<=f_dst_mac_i[s][31:24];
        fb[3]<=f_dst_mac_i[s][23:16]; fb[4]<=f_dst_mac_i[s][15:8];  fb[5]<=f_dst_mac_i[s][7:0];
        fb[6]<=f_src_mac_i[s][47:40]; fb[7]<=f_src_mac_i[s][39:32]; fb[8]<=f_src_mac_i[s][31:24];
        fb[9]<=f_src_mac_i[s][23:16]; fb[10]<=f_src_mac_i[s][15:8]; fb[11]<=f_src_mac_i[s][7:0];
        off = 12;
        if (f_vlan_en_i[s]) begin
            fb[off]<=8'h81; fb[off+1]<=8'h00;
            fb[off+2]<={4'h0,f_vlan_id_i[s][11:8]}; fb[off+3]<=f_vlan_id_i[s][7:0];
            off += 4;
        end
        fb[off]<=8'h08; fb[off+1]<=8'h00; off += 2;           // ethertype IPv4
        total_len = 20 + 8 + FRAME_LEN_PAYLOAD;
        fb[off+0]<=8'h45; fb[off+1]<=8'h00;
        fb[off+2]<=total_len[15:8]; fb[off+3]<=total_len[7:0];
        fb[off+4]<=8'h00; fb[off+5]<=8'h00; fb[off+6]<=8'h40; fb[off+7]<=8'h00;
        fb[off+8]<=8'h40; fb[off+9]<=8'h11; fb[off+10]<=8'h00; fb[off+11]<=8'h00;
        fb[off+12]<=f_src_ipv4_i[s][31:24]; fb[off+13]<=f_src_ipv4_i[s][23:16];
        fb[off+14]<=f_src_ipv4_i[s][15:8];  fb[off+15]<=f_src_ipv4_i[s][7:0];
        fb[off+16]<=f_dst_ipv4_i[s][31:24]; fb[off+17]<=f_dst_ipv4_i[s][23:16];
        fb[off+18]<=f_dst_ipv4_i[s][15:8];  fb[off+19]<=f_dst_ipv4_i[s][7:0];
        off += 20;
        fb[off+0]<=f_udp_sp_i[s][15:8]; fb[off+1]<=f_udp_sp_i[s][7:0];
        fb[off+2]<=f_udp_dp_i[s][15:8]; fb[off+3]<=f_udp_dp_i[s][7:0];
        tl = 8 + FRAME_LEN_PAYLOAD;
        fb[off+4]<=tl[15:8]; fb[off+5]<=tl[7:0]; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
        off += 8;
        fb[off+0]<=PW_TEST_HDR_MAGIC[31:24]; fb[off+1]<=PW_TEST_HDR_MAGIC[23:16];
        fb[off+2]<=PW_TEST_HDR_MAGIC[15:8];  fb[off+3]<=PW_TEST_HDR_MAGIC[7:0];
        fb[off+4]<=8'h00; fb[off+5]<=8'h01; fb[off+6]<=8'h00; fb[off+7]<=8'h00;
        fb[off+8]<=f_flow_id_i[s][31:24]; fb[off+9]<=f_flow_id_i[s][23:16];
        fb[off+10]<=f_flow_id_i[s][15:8]; fb[off+11]<=f_flow_id_i[s][7:0];
        fb[off+12]<=seq[63:56]; fb[off+13]<=seq[55:48]; fb[off+14]<=seq[47:40]; fb[off+15]<=seq[39:32];
        fb[off+16]<=seq[31:24]; fb[off+17]<=seq[23:16]; fb[off+18]<=seq[15:8];  fb[off+19]<=seq[7:0];
        fb[off+20]<=ts[63:56]; fb[off+21]<=ts[55:48]; fb[off+22]<=ts[47:40]; fb[off+23]<=ts[39:32];
        fb[off+24]<=ts[31:24]; fb[off+25]<=ts[23:16]; fb[off+26]<=ts[15:8];  fb[off+27]<=ts[7:0];
        frame_len <= 12'(20 + 8 + 14 + (f_vlan_en_i[s] ? 4 : 0) + (FRAME_LEN_PAYLOAD - 32) + 32);
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active   <= 1'b0;
            byte_off <= '0;
            rr_ptr   <= '0;
            sel      <= '0;
            for (int s = 0; s < NUM_SLOTS; s++) begin
                sequence_q[s] <= '0;
                tokens_q[s]   <= '0;
            end
        end else begin
            // Token buckets: accumulate per enabled slot, clamp to cap.
            for (int s = 0; s < NUM_SLOTS; s++) begin
                automatic logic [32:0] sum;
                automatic logic [31:0] cap = {f_burst_i[s], 16'h0};
                if (!f_enable_i[s]) begin
                    tokens_q[s] <= '0;
                end else begin
                    sum = {1'b0, tokens_q[s]} + {1'b0, f_tokens_fp_i[s]};
                    if (sum > {1'b0, cap}) sum = {1'b0, cap};
                    tokens_q[s] <= sum[31:0];
                end
            end

            if (!active) begin
                if (start) begin
                    // Accrue this cycle for the picked slot, clamp to cap, then
                    // deduct the frame cost. This non-blocking write to
                    // tokens_q[pick] overrides the accrual loop above (last
                    // write wins), so the bucket is not double-credited.
                    automatic logic [31:0] cost = {16'(frame_bytes(f_vlan_en_i[pick])), 16'h0};
                    automatic logic [31:0] cap  = {f_burst_i[pick], 16'h0};
                    automatic logic [32:0] acc  = {1'b0, tokens_q[pick]} + {1'b0, f_tokens_fp_i[pick]};
                    automatic logic [31:0] accv = (acc > {1'b0, cap}) ? cap : acc[31:0];
                    build(int'(pick), sequence_q[pick], timestamp_i);
                    sel      <= pick;
                    active   <= 1'b1;
                    byte_off <= '0;
                    rr_ptr   <= (pick == SELW'(NUM_SLOTS-1)) ? '0 : pick + 1'b1;
                    tokens_q[pick] <= (accv >= cost) ? (accv - cost) : '0;
                end
            end else if (m_tready) begin
                if (last) begin
                    active        <= 1'b0;
                    sequence_q[sel] <= sequence_q[sel] + 64'd1;
                end else begin
                    byte_off <= byte_off + 12'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
