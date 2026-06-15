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
    parameter int HDR_BYTES = 100
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

    // --- parse (one cycle after EOF; same logic as pw_parser) --------------
    pw_match_key_t key_q;
    logic          key_valid_q;
    assign key_o       = key_q;
    assign key_valid_o = key_valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic logic          ok;
        automatic logic [15:0]   etype0;
        automatic int            l3_off, ip_hlen, udp_off, pay_off;
        automatic int            flen;

        if (!rst_n) begin
            key_q <= '0; key_valid_q <= 1'b0;
        end else begin
            k = '0; ok = 1'b0; etype0 = '0;
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

                k.is_arp  = (k.ethertype == ETHERTYPE_ARP);
                k.is_ipv4 = (k.ethertype == ETHERTYPE_IPV4);
                k.is_ipv6 = (k.ethertype == ETHERTYPE_IPV6);

                if (k.is_ipv6 && flen >= l3_off + 40) begin
                    k.l3_proto = hdr[l3_off + 6];
                    for (int i = 0; i < 16; i++) k.ipv6_src[127 - i*8 -: 8] = hdr[l3_off + 8 + i];
                    for (int i = 0; i < 16; i++) k.ipv6_dst[127 - i*8 -: 8] = hdr[l3_off + 24 + i];
                    k.is_tcp = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_icmp6 = (k.l3_proto == IPV6_NH_ICMP6);
                    ip_hlen = 40;
                    if ((k.is_udp || k.is_tcp) && flen >= l3_off + ip_hlen + 4) begin
                        udp_off  = l3_off + ip_hlen;
                        k.l4_src = {hdr[udp_off], hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    if (k.is_udp && flen >= l3_off + ip_hlen + 8) begin
                        pay_off = l3_off + ip_hlen + 8;
                        if (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES) begin
                            k.test_magic    = {hdr[pay_off+0], hdr[pay_off+1], hdr[pay_off+2], hdr[pay_off+3]};
                            k.test_flow_id  = {hdr[pay_off+8], hdr[pay_off+9], hdr[pay_off+10], hdr[pay_off+11]};
                            k.test_sequence = {hdr[pay_off+12], hdr[pay_off+13], hdr[pay_off+14], hdr[pay_off+15],
                                               hdr[pay_off+16], hdr[pay_off+17], hdr[pay_off+18], hdr[pay_off+19]};
                            k.test_tx_timestamp = {hdr[pay_off+20], hdr[pay_off+21], hdr[pay_off+22], hdr[pay_off+23],
                                                   hdr[pay_off+24], hdr[pay_off+25], hdr[pay_off+26], hdr[pay_off+27]};
                            k.is_test = (k.test_magic == PW_TEST_HDR_MAGIC);
                        end
                    end
                    ok = 1'b1;
                end else if (k.is_ipv4 && flen >= l3_off + 20) begin
                    ip_hlen    = int'(hdr[l3_off][3:0]) * 4;
                    k.l3_proto = hdr[l3_off + 9];
                    k.ipv4_src = {hdr[l3_off + 12], hdr[l3_off + 13], hdr[l3_off + 14], hdr[l3_off + 15]};
                    k.ipv4_dst = {hdr[l3_off + 16], hdr[l3_off + 17], hdr[l3_off + 18], hdr[l3_off + 19]};
                    k.is_icmp = (k.l3_proto == IPV4_PROTO_ICMP);
                    k.is_tcp  = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp  = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_ospf = (k.l3_proto == IPV4_PROTO_OSPF);
                    if ((k.is_udp || k.is_tcp) && ip_hlen >= 20 && flen >= l3_off + ip_hlen + 4) begin
                        udp_off  = l3_off + ip_hlen;
                        k.l4_src = {hdr[udp_off], hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        k.udp_src = k.l4_src; k.udp_dst = k.l4_dst;
                    end
                    if (k.is_udp && ip_hlen >= 20 && flen >= l3_off + ip_hlen + 8) begin
                        pay_off = l3_off + ip_hlen + 8;
                        if (flen >= pay_off + 32 && pay_off + 32 <= HDR_BYTES) begin
                            k.test_magic    = {hdr[pay_off+0], hdr[pay_off+1], hdr[pay_off+2], hdr[pay_off+3]};
                            k.test_flow_id  = {hdr[pay_off+8], hdr[pay_off+9], hdr[pay_off+10], hdr[pay_off+11]};
                            k.test_sequence = {hdr[pay_off+12], hdr[pay_off+13], hdr[pay_off+14], hdr[pay_off+15],
                                               hdr[pay_off+16], hdr[pay_off+17], hdr[pay_off+18], hdr[pay_off+19]};
                            k.test_tx_timestamp = {hdr[pay_off+20], hdr[pay_off+21], hdr[pay_off+22], hdr[pay_off+23],
                                                   hdr[pay_off+24], hdr[pay_off+25], hdr[pay_off+26], hdr[pay_off+27]};
                            k.is_test = (k.test_magic == PW_TEST_HDR_MAGIC);
                        end
                    end
                    ok = 1'b1;
                end else if (k.ethertype != 16'h0) begin
                    ok = 1'b1;
                end
            end
            k.valid = ok;
            key_q       <= k;
            key_valid_q <= ok;
        end
    end

endmodule

`default_nettype wire
