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
// bytes flow straight through; only the tx_ts bytes (and, for IPv6, the
// UDP checksum) of a matched test packet are muxed.
//
// Frame layout (little-endian AXIS, byte k in tdata[8k +: 8]); matches
// pw_flow_gen_multi: eth(12) [+VLAN 4] ethertype(2) L3 UDP(8) then the
// 28-byte test header { magic(4) ver(4) flow_id(4) seq(8) ts(8) }.
//   IPv4 (ethertype 0x0800, 20-byte hdr): magic@42 tx_ts@62 (+4 if VLAN).
//   IPv6 (ethertype 0x86DD, 40-byte hdr): magic@62 tx_ts@82 (+4 if VLAN),
//        UDP checksum @60 (+4 if VLAN).
//
// IPv4 UDP checksum is 0 (disabled) so overwriting tx_ts needs no fixup.
// IPv6 mandates a non-zero UDP checksum *covering* tx_ts, so overwriting
// tx_ts invalidates it. The generator emits a PARTIAL checksum that omits
// tx_ts (raw ~sum, no 0xFFFF rule -- see pw_flow_gen_multi::udp6_csum); we
// fold the departure tx_ts into it here, producing the final valid
// checksum. This works in one pass because the csum field (byte 60) leaves
// before tx_ts (byte 82): we never need the *old* tx_ts, only add the new
// (SOF-latched) one. The 0xFFFF (RFC 768) rule is applied here.
//
// Which frames to rewrite: the egress arbiter marks generator (test)
// frames with tuser=1 (s_tuser), CDC'd in alongside the data. We gate on
// the SOF-latched marker so forwarded / injected frames -- including
// genuine IPv6/UDP DUT traffic, whose checksum we must not corrupt and
// which streams its csum field before any magic we could test -- are left
// untouched. (The IPv4 tx_ts path additionally keys on the magic, as
// before, since its field follows the magic and that path is unchanged.)
// NOTE: s_tuser here is our marker, NOT the MAC's tx-error tuser; we drive
// m_tuser=0 (what the MAC saw before this marker existed).

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
    input  wire                    s_tuser,   // 1 = generator test frame (marker)

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
    logic        outer_v6_q;           // outer L3 family (= inner family if no encap)
    logic        inner_v6_q;           // inner (test header) L3 family
    logic        is_gen;               // SOF-latched s_tuser (test frame)
    logic [7:0]  mb [4];               // captured magic bytes
    logic        magic_ok;
    logic [63:0] ts_lat;               // departure ts latched at SOF
    logic [18:0] ts_addend;            // sum of the 4 tx_ts 16-bit words (SOF)
    logic [11:0] csum_beat_q;          // beat carrying the inner UDP csum field
    logic [3:0]  csum_lane_q;          // its byte lane within that beat
    logic [11:0] magic_off_q, ts_off_q;// registered inner-header offsets
    // Encap decode: outer IP proto + the byte that selects the inner family
    // (GRE protocol-type hi / EtherIP inner-Ethernet ethertype hi). Captured
    // from the outer/tunnel header region, which streams well before the inner
    // UDP csum and tx_ts -- so the derived offsets settle before they are used.
    logic [7:0]  o_proto_q;            // outer IP protocol / next-header
    logic [7:0]  gre_hi_q, eip_hi_q;   // inner-family selector bytes

    // Tunnel kind from the outer IP protocol (matches pw_flow_gen_multi).
    function automatic logic [1:0] enc_of_proto(input logic [7:0] p);
        case (p)
            8'd4, 8'd41: return 2'd1;   // IPIP (v4-in / v6-in)
            8'd47:       return 2'd2;   // GRE
            8'd97:       return 2'd3;   // EtherIP
            default:     return 2'd0;   // none (e.g. UDP 17)
        endcase
    endfunction
    function automatic logic [11:0] enc_hdr_len(input logic [1:0] et);
        case (et) 2'd2: return 12'd4; 2'd3: return 12'd16; default: return 12'd0; endcase
    endfunction

    wire        acc  = s_tvalid && s_tready;
    wire [11:0] base = {beat[8:0], 3'b000};             // beat*8 = first byte of this beat
    wire [11:0] vl   = vlan_q ? 12'd4 : 12'd0;
    wire [11:0] o3   = 12'd14 + vl;                      // outer L3 start
    // Tunnel kind + inner family decoded from the captured header bytes.
    wire [1:0]  encap_c   = enc_of_proto(o_proto_q);
    wire        inner_v6_c = (encap_c == 2'd0) ? outer_v6_q :
                             (encap_c == 2'd1) ? (o_proto_q == 8'd41) :
                             (encap_c == 2'd2) ? (gre_hi_q  == 8'h86) :
                                                 (eip_hi_q  == 8'h86);
    // Inner UDP header start: outer L3 [+ tunnel header + inner L3] (encap), or
    // just the outer/only L3 (no encap). Inner magic/tx_ts/csum derive from it.
    wire [11:0] inner_udp_c = (encap_c == 2'd0)
            ? o3 + (outer_v6_q ? 12'd40 : 12'd20)
            : o3 + (outer_v6_q ? 12'd40 : 12'd20)
                 + enc_hdr_len(encap_c) + (inner_v6_c ? 12'd40 : 12'd20);
    wire [11:0] magic_off_c = inner_udp_c + 12'd8;
    wire [11:0] ts_off_c    = inner_udp_c + 12'd28;      // magic(4)+ver(4)+fid(4)+seq(8)
    wire [11:0] csum_off_c   = inner_udp_c + 12'd6;       // UDP checksum field
    // Capture positions (depend only on VLAN + outer family, both settled early).
    wire [11:0] proto_pos = o3 + (outer_v6_q ? 12'd6  : 12'd9);
    wire [11:0] enc_start = o3 + (outer_v6_q ? 12'd40 : 12'd20);
    wire [11:0] gre_pos   = enc_start + 12'd2;           // GRE protocol-type hi
    wire [11:0] eip_pos   = enc_start + 12'd14;          // EtherIP inner ethertype hi

    wire [11:0] ts_off = ts_off_q;
    // Stamp the tx_ts: v4 inner keys on the magic (its field follows the magic);
    // v6 inner keys on the generator marker (the csum fixup must run before the
    // magic streams, so it uses the SOF marker).
    wire stamp_ok = inner_v6_q ? is_gen : magic_ok;
    // Inner UDP checksum fixup runs only for marked v6-inner generator frames.
    wire fix_csum = inner_v6_q && is_gen;

    // ---- pass-through handshake + sideband ----
    assign s_tready = m_tready;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign m_tkeep  = s_tkeep;
    assign m_tuser  = 1'b0;             // marker consumed here; MAC sees no tx-error

    // ---- finalized IPv6 UDP checksum: partial (from the stream) + tx_ts ----
    // c0 = generator's partial checksum (raw ~sum); ~c0 == the partial sum.
    // The four tx_ts 16-bit words are pre-summed once at SOF (ts_addend, see
    // below) so this is a single add + folds on the (MAC-CRC-critical) data
    // path instead of a 5-term tree.
    function automatic logic [15:0] finalize_csum(input logic [15:0]  c0,
                                                  input logic [18:0] addend);
        logic [19:0] s;
        logic [15:0] f;
        s = {4'b0, ~c0} + {1'b0, addend};                // ~c0 + sum(tx_ts words)
        s = {4'b0, s[15:0]} + {16'b0, s[19:16]};         // fold
        s = {4'b0, s[15:0]} + {16'b0, s[19:16]};         // fold again
        f = ~s[15:0];
        return (f == 16'h0000) ? 16'hFFFF : f;           // RFC 768
    endfunction

    // ---- data: overwrite tx_ts (matched) + IPv6 UDP csum (marked gen) ----
    always_comb begin
        logic [15:0] cnew;
        logic [11:0] bi;
        logic [5:0]  sel;
        logic [7:0]  c0_hi, c0_lo;
        logic        csum_here;
        m_tdata = s_tdata;
        // The 2-byte UDP csum field sits at a registered lane within one
        // registered beat (csum_beat_q / csum_lane_q): read the generator's
        // partial value via constant-index lane compares (the select is the
        // registered lane -- no beat-derived arithmetic on this MAC-CRC-
        // critical path) and finalize it with the pre-summed tx_ts addend
        // (a single add + folds).
        csum_here = fix_csum && (beat == csum_beat_q);
        c0_hi = 8'h0; c0_lo = 8'h0;
        for (int l = 0; l < DATA_W/8; l++) begin
            if (l[3:0] == csum_lane_q)          c0_hi = s_tdata[l*8 +: 8];
            if (l[3:0] == csum_lane_q + 4'd1)   c0_lo = s_tdata[l*8 +: 8];
        end
        cnew = finalize_csum({c0_hi, c0_lo}, ts_addend);
        for (int l = 0; l < DATA_W/8; l++) begin
            bi  = base + 12'(l);
            sel = 6'((7 - (bi - ts_off)) * 8);
            // tx_ts overwrite (big-endian 8 bytes at ts_off)
            if (stamp_ok && bi >= ts_off && bi < ts_off + 12'd8)
                m_tdata[l*8 +: 8] = ts_lat[sel +: 8];
            // IPv6 UDP checksum overwrite (2 bytes at the registered lane)
            if (csum_here && l[3:0] == csum_lane_q)          m_tdata[l*8 +: 8] = cnew[15:8];
            if (csum_here && l[3:0] == csum_lane_q + 4'd1)   m_tdata[l*8 +: 8] = cnew[7:0];
        end
    end

    // ---- per-beat tracking: SOF latch, header decode, magic, marker ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= '0; vlan_q <= 1'b0; outer_v6_q <= 1'b0; inner_v6_q <= 1'b0;
            is_gen <= 1'b0; magic_ok <= 1'b0; ts_lat <= '0; ts_addend <= '0;
            csum_beat_q <= 12'd7; csum_lane_q <= 4'd4;
            magic_off_q <= 12'd42; ts_off_q <= 12'd62;
            o_proto_q <= 8'd17; gre_hi_q <= 8'h0; eip_hi_q <= 8'h0;
            for (int k = 0; k < 4; k++) mb[k] <= 8'h0;
        end else if (acc) begin
            // Register the decoded inner-header offsets every beat (they settle
            // once the outer/tunnel header has streamed, well before the inner
            // csum/tx_ts beats), so the MAC-CRC data path reads stable values.
            csum_beat_q <= csum_off_c >> 3;
            csum_lane_q <= 4'(csum_off_c & 12'd7);
            magic_off_q <= magic_off_c;
            ts_off_q    <= ts_off_c;
            inner_v6_q  <= inner_v6_c;
            if (beat == 12'd0) begin
                ts_lat   <= ts_now;     // departure time of this frame
                // pre-sum the 4 tx_ts 16-bit words for the csum finalize
                ts_addend <= {3'b0, ts_now[63:48]} + {3'b0, ts_now[47:32]}
                           + {3'b0, ts_now[31:16]} + {3'b0, ts_now[15:0]};
                vlan_q     <= 1'b0;
                outer_v6_q <= 1'b0;
                is_gen     <= s_tuser;  // generator (test) frame marker
                magic_ok   <= 1'b0;
                o_proto_q  <= 8'd17;    // default = no encap until proto captured
                gre_hi_q   <= 8'h0;
                eip_hi_q   <= 8'h0;
            end
            if (beat == 12'd1) begin    // outer ethertype / VLAN tag at bytes 12-13
                automatic logic is_vlan = (s_tdata[39:32] == 8'h81 && s_tdata[47:40] == 8'h00);
                vlan_q <= is_vlan;
                if (!is_vlan)           // untagged: ethertype here decides outer IPv6
                    outer_v6_q <= (s_tdata[39:32] == 8'h86 && s_tdata[47:40] == 8'hDD);
            end
            if (beat == 12'd2 && vlan_q) // tagged: outer ethertype at bytes 16-17
                outer_v6_q <= (s_tdata[7:0] == 8'h86 && s_tdata[15:8] == 8'hDD);

            // Capture the outer IP proto + tunnel inner-family selector bytes,
            // and the 4 magic bytes, by position as they stream past.
            for (int l = 0; l < DATA_W/8; l++) begin
                automatic logic [11:0] bi = base + 12'(l);
                if (bi == proto_pos) o_proto_q <= s_tdata[l*8 +: 8];
                if (bi == gre_pos)   gre_hi_q  <= s_tdata[l*8 +: 8];
                if (bi == eip_pos)   eip_hi_q  <= s_tdata[l*8 +: 8];
                for (int k = 0; k < 4; k++)
                    if (bi == magic_off_q + 12'(k)) mb[k] <= s_tdata[l*8 +: 8];
            end
            // one beat after the magic's last byte, latch the verdict
            if (beat == ((magic_off_q + 12'd3) >> 3) + 12'd1)
                magic_ok <= ({mb[0], mb[1], mb[2], mb[3]} == MAGIC);

            beat <= s_tlast ? 12'd0 : beat + 12'd1;
        end
    end

endmodule

`default_nettype wire
