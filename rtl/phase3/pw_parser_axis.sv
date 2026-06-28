// PacketWyrm frame parser -- 64-bit AXIS streaming version.
//
// Captures the first HDR_BYTES header bytes of each frame from a 64-bit
// AXIS stream into a packed byte buffer, then runs the same parse as
// pw_parser at end-of-frame to produce a registered pw_match_key_t +
// key_valid pulse. No wide frame bus -- the rest of the payload just
// streams past uncaptured.

`default_nettype none

import pw_classifier_pkg::*;

module pw_parser_axis #(
    // 176 captures the deepest inner test header we can decapsulate: VLAN +
    // IPv6 outer (40) + EtherIP (2) + inner Ethernet (14) + IPv6 inner (40) +
    // TCP (20) + 32-byte test header = 166 bytes. (TCP's 20-byte L4 is the worst
    // case; the deepest UDP header is 154.) Matches the production HDR_BYTES that
    // pw_data_plane_axis passes -- keep the two in step so a standalone/direct
    // instantiation captures the same depth.
    parameter int HDR_BYTES = 176
) (
    input  wire           clk,
    input  wire           rst_n,

    // 64-bit AXIS ingress
    input  wire [63:0]    s_tdata,
    input  wire [7:0]     s_tkeep,
    input  wire           s_tvalid,
    output wire           s_tready,
    input  wire           s_tlast,
    input  wire [3:0]     ingress_port_i,

    output pw_match_key_t key_o,
    output logic          key_valid_o,

    // Captured header byte-window + inner-frame base offset, aligned with
    // key_valid_o, for the generic slice classifier (pw_slice_classifier).
    // window_o[b] is frame byte b (post-capture); base_o = inner L3 start so
    // slice offsets are relative to the decapsulated inner frame.
    output logic [HDR_BYTES-1:0][7:0] window_o,
    output logic [15:0]               base_o
);
    localparam logic [31:0] PW_TEST_HDR_MAGIC   = 32'hA502_7E57;
    localparam logic [15:0] ETHERTYPE_VLAN      = 16'h8100;
    localparam logic [15:0] ETHERTYPE_QINQ_88A8 = 16'h88A8;
    localparam logic [15:0] ETHERTYPE_QINQ_9100 = 16'h9100;
    localparam logic [15:0] ETHERTYPE_IPV4      = 16'h0800;
    localparam logic [15:0] ETHERTYPE_IPV6      = 16'h86DD;
    localparam logic [15:0] ETHERTYPE_ARP       = 16'h0806;
    localparam logic [7:0]  IPV4_PROTO_ICMP     = 8'd1;
    localparam logic [7:0]  IPV4_PROTO_TCP      = 8'd6;
    localparam logic [7:0]  IPV4_PROTO_UDP      = 8'd17;
    localparam logic [7:0]  IPV4_PROTO_OSPF     = 8'd89;
    localparam logic [7:0]  IPV6_NH_ICMP6       = 8'd58;

    assign s_tready = 1'b1;  // checker path never backpressures

    // --- capture header bytes from the stream ------------------------------
    logic [HDR_BYTES-1:0][7:0] hdr;
    logic [15:0]               byte_off;     // bytes captured so far this frame
    logic [15:0]               frame_len_q;  // total bytes of the frame just ended
    logic [3:0]                ingress_q;
    logic                      eof_q;        // parse trigger (1 cycle after tlast)

    function automatic int popk(input logic [7:0] kp);
        int n; n = 0;
        for (int i = 0; i < 8; i++) if (kp[i]) n++;
        return n;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_off <= '0; frame_len_q <= '0; eof_q <= 1'b0; ingress_q <= '0;
        end else begin
            eof_q <= 1'b0;
            if (s_tvalid && s_tready) begin
                for (int k = 0; k < 8; k++) begin
                    if (s_tkeep[k] && ((byte_off + k[15:0]) < HDR_BYTES[15:0]))
                        hdr[byte_off + k[15:0]] <= s_tdata[k*8 +: 8];
                end
                if (s_tlast) begin
                    frame_len_q <= byte_off + 16'(popk(s_tkeep));
                    ingress_q   <= ingress_port_i;
                    eof_q       <= 1'b1;
                    byte_off    <= '0;
                end else begin
                    byte_off <= byte_off + 16'(popk(s_tkeep));
                end
            end
        end
    end

    // --- parse, pipelined into THREE stages to close dp_clk timing ----------
    // Stage A : L2 framing + encap descent -> eff_off + inner family + L2 key.
    // Stage A2: inner (effective) L3/L4 parse at eff_off -> full key + pay_off.
    // Stage B : test-header field extraction at the payload offset.
    // The encap descent (variable eff_off over the 160-byte header + the
    // flen-guarded length checks) made the old single Stage A ~18 logic levels
    // -- the dp_clk-critical path; splitting the descent (A) from the inner
    // parse (A2) roughly halves it. The extra cycle is self-contained: all
    // downstream alignment (classifier latency, the data plane's SAF decision
    // delay) is relative to key_valid_o.
    pw_match_key_t             keyA;       // L2 fields + is_ipv4/is_ipv6 (inner)
    logic                      validA;     // frame processed (eof_q && len ok)
    logic [15:0]               eff_offA;   // inner L3 start
    logic                      inner_v4A, inner_v6A;
    logic [15:0]               flenA;      // frame_len carried to Stage A2
    logic [HDR_BYTES-1:0][7:0] hdrA;       // header snapshot carried forward

    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic logic [15:0]   etype0;
        automatic int            l3_off, flen;
        // Encapsulation descent: detect an outer tunnel (IPIP/GRE/EtherIP) and
        // re-base the L3/L4 parse onto the inner frame so the classifier keys on
        // the inner test flow. eff_off = inner L3 start; inner_v4/v6 = inner fam.
        // (The inner L3/L4 parse itself runs in Stage A2 off the registered
        // eff_off, breaking the long descent->parse path.)
        automatic logic          outer_v4, outer_v6, inner_v4, inner_v6;
        automatic logic [7:0]    o_proto;
        automatic logic [1:0]    enc;        // 0 none / 1 ipip / 2 gre / 3 etherip
        automatic int            o_hlen, enc_hlen, eff_off;
        automatic logic [15:0]   gre_pt, eip_et;
        automatic logic          proc;       // frame processed -> Stage A2 parses

        if (!rst_n) begin
            keyA <= '0; validA <= 1'b0; eff_offA <= '0;
            inner_v4A <= 1'b0; inner_v6A <= 1'b0; flenA <= '0;
        end else begin
            k = '0; etype0 = '0; proc = 1'b0;
            l3_off = 14; eff_off = 14; o_proto = '0; enc = 2'd0;
            o_hlen = 20; enc_hlen = 0; outer_v4 = 1'b0; outer_v6 = 1'b0;
            inner_v4 = 1'b0; inner_v6 = 1'b0; gre_pt = '0; eip_et = '0;
            flen = int'(frame_len_q);

            if (eof_q && flen >= 14) begin
                proc = 1'b1;
                k.ingress_port = ingress_q;
                etype0 = {hdr[12], hdr[13]};

                if ((etype0 == ETHERTYPE_QINQ_88A8 || etype0 == ETHERTYPE_QINQ_9100)
                        && flen >= 22 && {hdr[16], hdr[17]} == ETHERTYPE_VLAN) begin
                    k.vlan_valid       = 1'b1;
                    k.vlan_id          = {hdr[14][3:0], hdr[15]};
                    k.inner_vlan_valid = 1'b1;
                    k.inner_vlan_id    = {hdr[18][3:0], hdr[19]};
                    k.ethertype        = {hdr[20], hdr[21]};
                    l3_off             = 22;
                end else if (etype0 == ETHERTYPE_VLAN && flen >= 18) begin
                    k.vlan_valid = 1'b1;
                    k.vlan_id    = {hdr[14][3:0], hdr[15]};
                    k.ethertype  = {hdr[16], hdr[17]};
                    l3_off       = 18;
                end else begin
                    k.ethertype  = etype0;
                    l3_off       = 14;
                end

                k.is_arp = (k.ethertype == ETHERTYPE_ARP);
                outer_v4 = (k.ethertype == ETHERTYPE_IPV4);
                outer_v6 = (k.ethertype == ETHERTYPE_IPV6);

                // ---- encapsulation descent (auto-decap to the inner frame) ----
                // PacketWyrm's RX measures the inner test flow, so when the outer
                // IP carries a recognized tunnel we re-base the L3/L4 parse onto
                // the inner frame. Non-encap traffic keeps eff_off = l3_off and
                // its outer family, so its parse is bit-for-bit unchanged.
                o_proto = 8'h0; enc = 2'd0; o_hlen = 20; eff_off = l3_off;
                inner_v4 = outer_v4; inner_v6 = outer_v6;
                if (outer_v6 && flen >= l3_off + 40) begin o_proto = hdr[l3_off + 6]; o_hlen = 40; end
                else if (outer_v4 && flen >= l3_off + 20) begin o_proto = hdr[l3_off + 9]; o_hlen = int'(hdr[l3_off][3:0]) * 4; end
                case (o_proto)
                    8'd4, 8'd41: enc = 2'd1;   // IPIP (v4-in / v6-in)
                    8'd47:       enc = 2'd2;   // GRE
                    8'd97:       enc = 2'd3;   // EtherIP
                    default:     enc = 2'd0;
                endcase
                enc_hlen = (enc == 2'd2) ? 4 : (enc == 2'd3) ? 16 : 0;
                if (enc != 2'd0 && (outer_v4 || outer_v6) && o_hlen >= 20) begin
                    eff_off = l3_off + o_hlen + enc_hlen;
                    gre_pt  = {hdr[l3_off + o_hlen + 2],  hdr[l3_off + o_hlen + 3]};
                    eip_et  = {hdr[l3_off + o_hlen + 14], hdr[l3_off + o_hlen + 15]};
                    unique case (enc)
                        2'd1:    begin inner_v6 = (o_proto == 8'd41); inner_v4 = (o_proto == 8'd4); end
                        2'd2:    begin inner_v4 = (gre_pt == ETHERTYPE_IPV4); inner_v6 = (gre_pt == ETHERTYPE_IPV6); end
                        default: begin inner_v4 = (eip_et == ETHERTYPE_IPV4); inner_v6 = (eip_et == ETHERTYPE_IPV6); end
                    endcase
                end

                // Inner family decided; the inner L3/L4 parse runs in Stage A2.
                k.is_ipv4 = inner_v4;
                k.is_ipv6 = inner_v6;
            end
            keyA       <= k;
            validA     <= proc;
            eff_offA   <= eff_off[15:0];
            inner_v4A  <= inner_v4;
            inner_v6A  <= inner_v6;
            flenA      <= frame_len_q;
            hdrA       <= hdr;
        end
    end

    // Stage A2: inner (effective) L3/L4 parse at the registered eff_off.
    pw_match_key_t             keyA2;
    logic                      validA2;
    logic                      test_eligA2;
    logic [15:0]               pay_offA2;
    logic [15:0]               eff_offA2;   // inner base carried to Stage B
    logic [HDR_BYTES-1:0][7:0] hdrA2;

    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic int            eff, flen, ip_hlen, udp_off, pay_off;
        automatic logic          telig, ok;
        if (!rst_n) begin
            keyA2 <= '0; validA2 <= 1'b0; test_eligA2 <= 1'b0; pay_offA2 <= '0; eff_offA2 <= '0;
        end else begin
            k = keyA; ok = 1'b0; telig = 1'b0; ip_hlen = 20; udp_off = 0; pay_off = 0;
            eff = int'(eff_offA); flen = int'(flenA);
            if (validA) begin
                if (inner_v6A && flen >= eff + 40) begin
                    k.l3_proto = hdrA[eff + 6];
                    for (int i = 0; i < 16; i++) k.ipv6_src[127 - i*8 -: 8] = hdrA[eff + 8 + i];
                    for (int i = 0; i < 16; i++) k.ipv6_dst[127 - i*8 -: 8] = hdrA[eff + 24 + i];
                    k.is_tcp = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_icmp6 = (k.l3_proto == IPV6_NH_ICMP6);
                    ip_hlen = 40;
                    if ((k.is_udp || k.is_tcp) && flen >= eff + ip_hlen + 4) begin
                        udp_off  = eff + ip_hlen;
                        k.l4_src = {hdrA[udp_off], hdrA[udp_off + 1]};
                        k.l4_dst = {hdrA[udp_off + 2], hdrA[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    // Test header sits after the L4 header: UDP +8, TCP +20.
                    if ((k.is_udp || k.is_tcp) && flen >= eff + ip_hlen + (k.is_tcp ? 20 : 8)) begin
                        pay_off = eff + ip_hlen + (k.is_tcp ? 20 : 8);
                        telig   = (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES);
                    end
                    ok = 1'b1;
                end else if (inner_v4A && flen >= eff + 20) begin
                    ip_hlen    = int'(hdrA[eff][3:0]) * 4;
                    k.l3_proto = hdrA[eff + 9];
                    k.ipv4_src = {hdrA[eff + 12], hdrA[eff + 13], hdrA[eff + 14], hdrA[eff + 15]};
                    k.ipv4_dst = {hdrA[eff + 16], hdrA[eff + 17], hdrA[eff + 18], hdrA[eff + 19]};
                    k.is_icmp = (k.l3_proto == IPV4_PROTO_ICMP);
                    k.is_tcp  = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp  = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_ospf = (k.l3_proto == IPV4_PROTO_OSPF);
                    if ((k.is_udp || k.is_tcp) && ip_hlen >= 20 && flen >= eff + ip_hlen + 4) begin
                        udp_off  = eff + ip_hlen;
                        k.l4_src = {hdrA[udp_off], hdrA[udp_off + 1]};
                        k.l4_dst = {hdrA[udp_off + 2], hdrA[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    if ((k.is_udp || k.is_tcp) && ip_hlen >= 20 && flen >= eff + ip_hlen + (k.is_tcp ? 20 : 8)) begin
                        pay_off = eff + ip_hlen + (k.is_tcp ? 20 : 8);
                        telig   = (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES);
                    end
                    ok = 1'b1;
                end else if (k.ethertype != 16'h0) begin
                    ok = 1'b1;
                end
            end
            k.valid     = ok;
            keyA2       <= k;
            validA2     <= ok;
            test_eligA2 <= telig;
            pay_offA2   <= pay_off[15:0];
            eff_offA2   <= eff_offA;
            hdrA2       <= hdrA;
        end
    end

    // Stage B: extract the test header at the registered offset, finalise key.
    pw_match_key_t key_q;
    logic          key_valid_q;
    assign key_o       = key_q;
    assign key_valid_o = key_valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic int            po;
        if (!rst_n) begin
            key_q <= '0; key_valid_q <= 1'b0; window_o <= '0; base_o <= '0;
        end else begin
            k  = keyA2;
            po = int'(pay_offA2);
            window_o <= hdrA2;
            base_o   <= eff_offA2;
            if (test_eligA2) begin
                k.test_magic    = {hdrA2[po+0], hdrA2[po+1], hdrA2[po+2], hdrA2[po+3]};
                k.test_flow_id  = {hdrA2[po+8], hdrA2[po+9], hdrA2[po+10], hdrA2[po+11]};
                k.test_sequence = {hdrA2[po+12], hdrA2[po+13], hdrA2[po+14], hdrA2[po+15],
                                   hdrA2[po+16], hdrA2[po+17], hdrA2[po+18], hdrA2[po+19]};
                k.test_tx_timestamp = {hdrA2[po+20], hdrA2[po+21], hdrA2[po+22], hdrA2[po+23],
                                       hdrA2[po+24], hdrA2[po+25], hdrA2[po+26], hdrA2[po+27]};
                k.is_test = (k.test_magic == PW_TEST_HDR_MAGIC);
            end
            key_q       <= k;
            key_valid_q <= validA2;
        end
    end

endmodule

`default_nettype wire
