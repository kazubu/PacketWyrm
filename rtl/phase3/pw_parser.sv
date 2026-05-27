// PacketWyrm frame parser.
//
// Sequential: takes a pw_frame_t at posedge clk and produces a
// registered pw_match_key_t + key_valid one cycle later.

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_parser (
    input  wire           clk,
    input  wire           rst_n,
    input  pw_frame_t     frame_i,
    input  wire           frame_valid_i,
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

    // First N header bytes pre-extracted via continuous assigns
    // into a *packed* array of bytes.
    localparam int HDR_BYTES = 100;
    logic [HDR_BYTES-1:0][7:0] hdr;

    genvar gi;
    generate
        for (gi = 0; gi < HDR_BYTES; gi++) begin : g_hdr
            assign hdr[gi] = frame_i.data[gi];
        end
    endgenerate

    pw_match_key_t key_q;
    logic          key_valid_q;

    assign key_o       = key_q;
    assign key_valid_o = key_valid_q;

    // The parsing happens entirely inside the clocked block.
    // Earlier attempts to do the parsing inside an always_comb that
    // read `hdr` did not propagate under Verilator (sensitivity was
    // missed); doing it sequentially is rock-solid.
    always_ff @(posedge clk or negedge rst_n) begin
        automatic pw_match_key_t k;
        automatic logic          ok;
        automatic logic [15:0]   etype0;
        automatic int            l3_off, ip_hlen, udp_off, pay_off;

        if (!rst_n) begin
            key_q       <= '0;
            key_valid_q <= 1'b0;
        end else begin
            k       = '0;
            ok      = 1'b0;
            etype0  = '0;
            l3_off  = 14;
            ip_hlen = 20;
            udp_off = 0;
            pay_off = 0;

            if (frame_valid_i && frame_i.len >= 14) begin
                k.ingress_port = frame_i.ingress_port;
                etype0 = {hdr[12], hdr[13]};

                if ((etype0 == ETHERTYPE_QINQ_88A8 || etype0 == ETHERTYPE_QINQ_9100)
                        && frame_i.len >= 22 &&
                        {hdr[16], hdr[17]} == ETHERTYPE_VLAN) begin
                    // Outer (S-VLAN) + inner (C-VLAN) 802.1ad
                    k.vlan_valid       = 1'b1;
                    k.vlan_id          = {hdr[14][3:0], hdr[15]};
                    k.inner_vlan_valid = 1'b1;
                    k.inner_vlan_id    = {hdr[18][3:0], hdr[19]};
                    k.ethertype        = {hdr[20], hdr[21]};
                    l3_off             = 22;
                end else if (etype0 == ETHERTYPE_VLAN && frame_i.len >= 18) begin
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

                if (k.is_ipv6 && frame_i.len >= l3_off + 40) begin
                    // IPv6 fixed header: 40 bytes. Field offsets
                    // relative to l3_off:
                    //   +6  next header (l4 protocol)
                    //   +7  hop limit
                    //   +8..23  source address
                    //   +24..39 destination address
                    automatic int i;
                    k.l3_proto = hdr[l3_off + 6];
                    for (i = 0; i < 16; i++)
                        k.ipv6_src[127 - i*8 -: 8] = hdr[l3_off + 8 + i];
                    for (i = 0; i < 16; i++)
                        k.ipv6_dst[127 - i*8 -: 8] = hdr[l3_off + 24 + i];
                    k.is_tcp    = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp    = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_icmp6  = (k.l3_proto == IPV6_NH_ICMP6);

                    ip_hlen = 40;
                    if ((k.is_udp || k.is_tcp) &&
                        frame_i.len >= l3_off + ip_hlen + 4) begin
                        udp_off  = l3_off + ip_hlen;
                        k.l4_src = {hdr[udp_off],     hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        k.udp_src = k.l4_src;
                        k.udp_dst = k.l4_dst;
                    end
                    if (k.is_udp &&
                        frame_i.len >= l3_off + ip_hlen + 8) begin
                        udp_off = l3_off + ip_hlen;
                        pay_off = udp_off + 8;
                        if (frame_i.len >= pay_off + 32 &&
                            pay_off + 32 <= HDR_BYTES) begin
                            k.test_magic = {hdr[pay_off + 0],
                                            hdr[pay_off + 1],
                                            hdr[pay_off + 2],
                                            hdr[pay_off + 3]};
                            k.test_flow_id = {hdr[pay_off + 8],
                                              hdr[pay_off + 9],
                                              hdr[pay_off + 10],
                                              hdr[pay_off + 11]};
                            k.test_sequence = {
                                hdr[pay_off + 12], hdr[pay_off + 13],
                                hdr[pay_off + 14], hdr[pay_off + 15],
                                hdr[pay_off + 16], hdr[pay_off + 17],
                                hdr[pay_off + 18], hdr[pay_off + 19]};
                            k.test_tx_timestamp = {
                                hdr[pay_off + 20], hdr[pay_off + 21],
                                hdr[pay_off + 22], hdr[pay_off + 23],
                                hdr[pay_off + 24], hdr[pay_off + 25],
                                hdr[pay_off + 26], hdr[pay_off + 27]};
                            k.is_test = (k.test_magic == PW_TEST_HDR_MAGIC);
                        end
                    end
                    ok = 1'b1;
                end else if (k.is_ipv4 && frame_i.len >= l3_off + 20) begin
                    ip_hlen     = int'(hdr[l3_off][3:0]) * 4;
                    k.l3_proto  = hdr[l3_off + 9];
                    k.ipv4_src  = {hdr[l3_off + 12], hdr[l3_off + 13],
                                   hdr[l3_off + 14], hdr[l3_off + 15]};
                    k.ipv4_dst  = {hdr[l3_off + 16], hdr[l3_off + 17],
                                   hdr[l3_off + 18], hdr[l3_off + 19]};
                    k.is_icmp   = (k.l3_proto == IPV4_PROTO_ICMP);
                    k.is_tcp    = (k.l3_proto == IPV4_PROTO_TCP);
                    k.is_udp    = (k.l3_proto == IPV4_PROTO_UDP);
                    k.is_ospf   = (k.l3_proto == IPV4_PROTO_OSPF);

                    // Both UDP and TCP have the L4 source / destination
                    // port in the first 4 bytes after the IP header.
                    if ((k.is_udp || k.is_tcp)
                            && ip_hlen >= 20
                            && frame_i.len >= l3_off + ip_hlen + 4) begin
                        udp_off  = l3_off + ip_hlen;
                        k.l4_src = {hdr[udp_off],     hdr[udp_off + 1]};
                        k.l4_dst = {hdr[udp_off + 2], hdr[udp_off + 3]};
                        // Legacy aliases (testbench transition):
                        k.udp_src = k.l4_src;
                        k.udp_dst = k.l4_dst;
                    end

                    // Extract the test header inside UDP only.
                    if (k.is_udp
                            && ip_hlen >= 20
                            && frame_i.len >= l3_off + ip_hlen + 8) begin
                        udp_off = l3_off + ip_hlen;
                        pay_off = udp_off + 8;
                        if (frame_i.len >= pay_off + 32 &&
                            pay_off + 32 <= HDR_BYTES) begin
                            k.test_magic = {hdr[pay_off + 0],
                                            hdr[pay_off + 1],
                                            hdr[pay_off + 2],
                                            hdr[pay_off + 3]};
                            k.test_flow_id = {hdr[pay_off + 8],
                                              hdr[pay_off + 9],
                                              hdr[pay_off + 10],
                                              hdr[pay_off + 11]};
                            k.test_sequence = {
                                hdr[pay_off + 12], hdr[pay_off + 13],
                                hdr[pay_off + 14], hdr[pay_off + 15],
                                hdr[pay_off + 16], hdr[pay_off + 17],
                                hdr[pay_off + 18], hdr[pay_off + 19]};
                            k.test_tx_timestamp = {
                                hdr[pay_off + 20], hdr[pay_off + 21],
                                hdr[pay_off + 22], hdr[pay_off + 23],
                                hdr[pay_off + 24], hdr[pay_off + 25],
                                hdr[pay_off + 26], hdr[pay_off + 27]};
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
