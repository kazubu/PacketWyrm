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
    // 160 captures the deepest inner test header we can decapsulate: VLAN +
    // IPv6 outer (40) + EtherIP (2) + inner Ethernet (14) + IPv6 inner (40) +
    // UDP (8) + 32-byte test header = 154 bytes.
    parameter int HDR_BYTES = 160
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
    output logic          key_valid_o
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

    // --- parse, pipelined into two stages to close timing -----------------
    // Stage A: L2/L3/L4 framing + payload offset (the frame_len-guarded
    // length checks). Stage B: test-header field extraction (the wide
    // hdr-byte mux). Splitting the ~12-level eof->key path roughly in half
    // recovers timing margin; the extra cycle is self-contained because all
    // downstream alignment (classifier latency, the data plane's key/decision
    // delay) is relative to key_valid_o.
    pw_match_key_t             keyA;
    logic                      validA;
    logic                      test_eligA;   // payload long enough for the test header
    logic [15:0]               pay_offA;      // test header start offset
    logic [HDR_BYTES-1:0][7:0] hdrA;          // snapshot of hdr for stage B

    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic logic          ok;
        automatic logic          telig;
        automatic logic [15:0]   etype0;
        automatic int            l3_off, ip_hlen, udp_off, pay_off;
        automatic int            flen;
        // Encapsulation descent: detect an outer tunnel (IPIP/GRE/EtherIP) and
        // re-base the L3/L4 parse onto the inner frame so the classifier keys on
        // the inner test flow. eff_off = inner L3 start; inner_v4/v6 = inner fam.
        automatic logic          outer_v4, outer_v6, inner_v4, inner_v6;
        automatic logic [7:0]    o_proto;
        automatic logic [1:0]    enc;        // 0 none / 1 ipip / 2 gre / 3 etherip
        automatic int            o_hlen, enc_hlen, eff_off;
        automatic logic [15:0]   gre_pt, eip_et;

        if (!rst_n) begin
            keyA <= '0; validA <= 1'b0; test_eligA <= 1'b0; pay_offA <= '0;
        end else begin
            k = '0; ok = 1'b0; telig = 1'b0; etype0 = '0;
            l3_off = 14; ip_hlen = 20; udp_off = 0; pay_off = 0;
            flen = int'(frame_len_q);

            if (eof_q && flen >= 14) begin
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

                // ---- inner (effective) L3/L4 parse, based at eff_off ----------
                k.is_ipv4 = inner_v4;
                k.is_ipv6 = inner_v6;
                if (inner_v6 && flen >= eff_off + 40) begin
                    k.l3_proto = hdr[eff_off + 6];
                    for (int i = 0; i < 16; i++) k.ipv6_src[127 - i*8 -: 8] = hdr[eff_off + 8 + i];
                    for (int i = 0; i < 16; i++) k.ipv6_dst[127 - i*8 -: 8] = hdr[eff_off + 24 + i];
                    k.is_tcp = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_icmp6 = (k.l3_proto == IPV6_NH_ICMP6);
                    ip_hlen = 40;
                    if ((k.is_udp || k.is_tcp) && flen >= eff_off + ip_hlen + 4) begin
                        udp_off  = eff_off + ip_hlen;
                        k.l4_src = {hdr[udp_off], hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    if (k.is_udp && flen >= eff_off + ip_hlen + 8) begin
                        pay_off = eff_off + ip_hlen + 8;
                        telig   = (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES);
                    end
                    ok = 1'b1;
                end else if (inner_v4 && flen >= eff_off + 20) begin
                    ip_hlen    = int'(hdr[eff_off][3:0]) * 4;
                    k.l3_proto = hdr[eff_off + 9];
                    k.ipv4_src = {hdr[eff_off + 12], hdr[eff_off + 13], hdr[eff_off + 14], hdr[eff_off + 15]};
                    k.ipv4_dst = {hdr[eff_off + 16], hdr[eff_off + 17], hdr[eff_off + 18], hdr[eff_off + 19]};
                    k.is_icmp = (k.l3_proto == IPV4_PROTO_ICMP);
                    k.is_tcp  = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp  = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_ospf = (k.l3_proto == IPV4_PROTO_OSPF);
                    if ((k.is_udp || k.is_tcp) && ip_hlen >= 20 && flen >= eff_off + ip_hlen + 4) begin
                        udp_off  = eff_off + ip_hlen;
                        k.l4_src = {hdr[udp_off], hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    if (k.is_udp && ip_hlen >= 20 && flen >= eff_off + ip_hlen + 8) begin
                        pay_off = eff_off + ip_hlen + 8;
                        telig   = (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES);
                    end
                    ok = 1'b1;
                end else if (k.ethertype != 16'h0) begin
                    ok = 1'b1;
                end
            end
            k.valid    = ok;
            keyA       <= k;
            validA     <= ok;
            test_eligA <= telig;
            pay_offA   <= pay_off[15:0];
            hdrA       <= hdr;
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
            key_q <= '0; key_valid_q <= 1'b0;
        end else begin
            k  = keyA;
            po = int'(pay_offA);
            if (test_eligA) begin
                k.test_magic    = {hdrA[po+0], hdrA[po+1], hdrA[po+2], hdrA[po+3]};
                k.test_flow_id  = {hdrA[po+8], hdrA[po+9], hdrA[po+10], hdrA[po+11]};
                k.test_sequence = {hdrA[po+12], hdrA[po+13], hdrA[po+14], hdrA[po+15],
                                   hdrA[po+16], hdrA[po+17], hdrA[po+18], hdrA[po+19]};
                k.test_tx_timestamp = {hdrA[po+20], hdrA[po+21], hdrA[po+22], hdrA[po+23],
                                       hdrA[po+24], hdrA[po+25], hdrA[po+26], hdrA[po+27]};
                k.is_test = (k.test_magic == PW_TEST_HDR_MAGIC);
            end
            key_q       <= k;
            key_valid_q <= validA;
        end
    end

endmodule

`default_nettype wire
