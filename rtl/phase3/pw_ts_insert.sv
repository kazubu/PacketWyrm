// Egress hardware timestamping for PacketWyrm test packets.
//
// Sits on the MAC TX AXIS stream (MAC TX clock domain), right before the
// MAC, and overwrites the 8-byte tx_timestamp field of each PacketWyrm
// test packet with the timestamp captured at the moment the frame is
// actually departing -- so a tester measures the DUT's latency, not its
// own internal TX-FIFO queuing. (The generator's build-time stamp is
// upstream of the CDC/MAC FIFO, so multiplexing N flows onto one port
// added a per-flow queuing offset; stamping here removes it.)
//
// Pass-through (no added latency / no backpressure): handshake and all
// bytes flow straight through; only the tx_ts bytes of a matched test
// packet are muxed to the latched departure timestamp.
//
// Frame layout (little-endian AXIS, byte k in tdata[8k +: 8]); matches
// pw_flow_gen_multi: eth(12) [+VLAN 4] ethertype(2) IPv4(20) UDP(8) then
// the 28-byte test header { magic(4) ver(4) flow_id(4) seq(8) ts(8) }.
//   magic at byte 42 (+4 if VLAN); tx_ts at byte 62 (+4 if VLAN), big-endian.

`default_nettype none

module pw_ts_insert #(
    parameter int DATA_W = 64
) (
    input  wire                    clk,       // MAC TX clock
    input  wire                    rst_n,
    input  wire [63:0]             ts_now,    // free-running ts (this domain)

    input  wire [DATA_W-1:0]       s_tdata,
    input  wire [DATA_W/8-1:0]     s_tkeep,
    input  wire                    s_tvalid,
    output wire                    s_tready,
    input  wire                    s_tlast,
    input  wire                    s_tuser,

    output logic [DATA_W-1:0]      m_tdata,
    output logic [DATA_W/8-1:0]    m_tkeep,
    output logic                   m_tvalid,
    input  wire                    m_tready,
    output logic                   m_tlast,
    output logic                   m_tuser
);
    localparam logic [31:0] MAGIC = 32'hA502_7E57;

    logic [11:0] beat;                 // beat index within frame
    logic        vlan_q;
    logic [7:0]  mb [4];               // captured magic bytes
    logic        magic_ok;
    logic [63:0] ts_lat;               // departure ts latched at SOF

    wire        acc       = s_tvalid && s_tready;
    wire [11:0] base      = {beat[8:0], 3'b000};        // beat*8 = first byte index of this beat
    wire [11:0] magic_off = 12'd42 + (vlan_q ? 12'd4 : 12'd0);
    wire [11:0] ts_off    = 12'd62 + (vlan_q ? 12'd4 : 12'd0);

    // ---- pass-through handshake + sideband ----
    assign s_tready = m_tready;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign m_tkeep  = s_tkeep;
    assign m_tuser  = s_tuser;

    // ---- data: overwrite the tx_ts bytes of a matched test packet ----
    always_comb begin
        m_tdata = s_tdata;
        for (int l = 0; l < DATA_W/8; l++) begin
            automatic logic [11:0] bi  = base + 12'(l);
            automatic logic [5:0]  sel = 6'((7 - (bi - ts_off)) * 8);  // bit offset, big-endian
            if (magic_ok && bi >= ts_off && bi < ts_off + 12'd8)
                m_tdata[l*8 +: 8] = ts_lat[sel +: 8];
        end
    end

    // ---- per-beat tracking: SOF latch, VLAN, magic capture, magic_ok ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= '0; vlan_q <= 1'b0; magic_ok <= 1'b0; ts_lat <= '0;
            for (int k = 0; k < 4; k++) mb[k] <= 8'h0;
        end else if (acc) begin
            if (beat == 12'd0) begin
                ts_lat   <= ts_now;     // departure time of this frame
                vlan_q   <= 1'b0;
                magic_ok <= 1'b0;
            end
            if (beat == 12'd1)          // ethertype/VLAN tag at bytes 12-13
                vlan_q <= (s_tdata[39:32] == 8'h81 && s_tdata[47:40] == 8'h00);

            // capture the 4 magic bytes as they stream past
            for (int l = 0; l < DATA_W/8; l++) begin
                automatic logic [11:0] bi = base + 12'(l);
                for (int k = 0; k < 4; k++)
                    if (bi == magic_off + 12'(k)) mb[k] <= s_tdata[l*8 +: 8];
            end
            // one beat after the magic's last byte, latch the verdict
            if (beat == ((magic_off + 12'd3) >> 3) + 12'd1)
                magic_ok <= ({mb[0], mb[1], mb[2], mb[3]} == MAGIC);

            beat <= s_tlast ? 12'd0 : beat + 12'd1;
        end
    end

endmodule

`default_nettype wire
