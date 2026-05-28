// Behavioral reference parser for cocotb unit testing.
//
// Implements the same parsing specification as rtl/phase3/pw_parser.sv
// using only Icarus-compatible constructs (no `automatic` in always blocks,
// no packed struct ports). Exposes flat individual output signals so Python
// test code can assert on them directly.
//
// Interface:
//   din_flat[1023:0]  — up to 128 header bytes, byte N at bits [8N+7:8N]
//   din_len           — total frame length in bytes
//   din_port          — ingress port index
//   din_valid         — pulse: present din for one cycle
//   outputs           — registered, valid one cycle after din_valid

`timescale 1ns/1ps
`default_nettype none

module pw_parser_beh (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [1023:0] din_flat,
    input  wire [10:0]   din_len,
    input  wire [3:0]    din_port,
    input  wire          din_valid,

    output reg           key_valid,
    output reg           is_test,
    output reg           is_arp,
    output reg           is_ipv4,
    output reg           is_ipv6,
    output reg           is_tcp,
    output reg           is_udp,
    output reg           is_icmp,
    output reg           is_icmp6,
    output reg           is_ospf,
    output reg  [3:0]    ingress_port,
    output reg  [15:0]   ethertype,
    output reg           vlan_valid,
    output reg  [11:0]   vlan_id,
    output reg  [7:0]    l3_proto,
    output reg  [31:0]   ipv4_src,
    output reg  [31:0]   ipv4_dst,
    output reg  [15:0]   l4_src,
    output reg  [15:0]   l4_dst,
    output reg  [31:0]   test_magic,
    output reg  [31:0]   test_flow_id,
    output reg  [63:0]   test_sequence,
    output reg  [63:0]   test_tx_ts
);

    localparam [31:0] PW_TEST_MAGIC  = 32'hA502_7E57;
    localparam [15:0] ET_VLAN        = 16'h8100;
    localparam [15:0] ET_QINQ_88A8   = 16'h88A8;
    localparam [15:0] ET_QINQ_9100   = 16'h9100;
    localparam [15:0] ET_IPV4        = 16'h0800;
    localparam [15:0] ET_IPV6        = 16'h86DD;
    localparam [15:0] ET_ARP         = 16'h0806;
    localparam [7:0]  PROTO_ICMP     = 8'd1;
    localparam [7:0]  PROTO_TCP      = 8'd6;
    localparam [7:0]  PROTO_UDP      = 8'd17;
    localparam [7:0]  PROTO_OSPF     = 8'd89;
    localparam [7:0]  PROTO_ICMP6    = 8'd58;

    // Helper function: extract byte N from the flat input.
    function [7:0] byte_at;
        input [1023:0] flat;
        input integer  n;
        byte_at = flat[n*8 +: 8];
    endfunction

    always @(posedge clk or negedge rst_n) begin
        // Local working registers — not automatic, but only written from
        // one path, so they behave identically to automatic vars here.
        reg [15:0] etype0;
        reg [6:0]  l3_off;
        reg [6:0]  ip_hlen;
        reg [6:0]  udp_off;
        reg [6:0]  pay_off;
        reg [7:0]  ihl_nibble;

        if (!rst_n) begin
            key_valid    <= 1'b0;
            is_test      <= 1'b0;
            is_arp       <= 1'b0;
            is_ipv4      <= 1'b0;
            is_ipv6      <= 1'b0;
            is_tcp       <= 1'b0;
            is_udp       <= 1'b0;
            is_icmp      <= 1'b0;
            is_icmp6     <= 1'b0;
            is_ospf      <= 1'b0;
            ingress_port <= 4'b0;
            ethertype    <= 16'b0;
            vlan_valid   <= 1'b0;
            vlan_id      <= 12'b0;
            l3_proto     <= 8'b0;
            ipv4_src     <= 32'b0;
            ipv4_dst     <= 32'b0;
            l4_src       <= 16'b0;
            l4_dst       <= 16'b0;
            test_magic   <= 32'b0;
            test_flow_id <= 32'b0;
            test_sequence <= 64'b0;
            test_tx_ts   <= 64'b0;
        end else begin
            // Clear all outputs by default.
            key_valid    <= 1'b0;
            is_test      <= 1'b0;
            is_arp       <= 1'b0;
            is_ipv4      <= 1'b0;
            is_ipv6      <= 1'b0;
            is_tcp       <= 1'b0;
            is_udp       <= 1'b0;
            is_icmp      <= 1'b0;
            is_icmp6     <= 1'b0;
            is_ospf      <= 1'b0;
            ingress_port <= 4'b0;
            ethertype    <= 16'b0;
            vlan_valid   <= 1'b0;
            vlan_id      <= 12'b0;
            l3_proto     <= 8'b0;
            ipv4_src     <= 32'b0;
            ipv4_dst     <= 32'b0;
            l4_src       <= 16'b0;
            l4_dst       <= 16'b0;
            test_magic   <= 32'b0;
            test_flow_id <= 32'b0;
            test_sequence <= 64'b0;
            test_tx_ts   <= 64'b0;

            if (din_valid && din_len >= 11'd14) begin
                ingress_port <= din_port;
                etype0        = {byte_at(din_flat, 12), byte_at(din_flat, 13)};
                l3_off        = 7'd14;
                vlan_valid   <= 1'b0;

                // VLAN / QinQ tag decode
                if ((etype0 == ET_QINQ_88A8 || etype0 == ET_QINQ_9100) &&
                    din_len >= 11'd22 &&
                    {byte_at(din_flat, 16), byte_at(din_flat, 17)} == ET_VLAN) begin
                    vlan_valid  <= 1'b1;
                    vlan_id     <= {din_flat[14*8+:4], din_flat[15*8+:8]};
                    etype0       = {byte_at(din_flat, 20), byte_at(din_flat, 21)};
                    l3_off       = 7'd22;
                end else if (etype0 == ET_VLAN && din_len >= 11'd18) begin
                    vlan_valid  <= 1'b1;
                    vlan_id     <= {din_flat[14*8+:4], din_flat[15*8+:8]};
                    etype0       = {byte_at(din_flat, 16), byte_at(din_flat, 17)};
                    l3_off       = 7'd18;
                end

                ethertype <= etype0;
                is_arp    <= (etype0 == ET_ARP);
                is_ipv4   <= (etype0 == ET_IPV4);
                is_ipv6   <= (etype0 == ET_IPV6);

                // IPv4
                if (etype0 == ET_IPV4 && din_len >= l3_off + 7'd20) begin
                    ihl_nibble  = byte_at(din_flat, l3_off) & 8'hF;
                    ip_hlen     = {1'b0, ihl_nibble[5:0], 2'b0};  // *4
                    l3_proto   <= byte_at(din_flat, l3_off + 7'd9);
                    ipv4_src   <= {byte_at(din_flat, l3_off + 7'd12),
                                   byte_at(din_flat, l3_off + 7'd13),
                                   byte_at(din_flat, l3_off + 7'd14),
                                   byte_at(din_flat, l3_off + 7'd15)};
                    ipv4_dst   <= {byte_at(din_flat, l3_off + 7'd16),
                                   byte_at(din_flat, l3_off + 7'd17),
                                   byte_at(din_flat, l3_off + 7'd18),
                                   byte_at(din_flat, l3_off + 7'd19)};
                    is_icmp    <= (byte_at(din_flat, l3_off + 7'd9) == PROTO_ICMP);
                    is_tcp     <= (byte_at(din_flat, l3_off + 7'd9) == PROTO_TCP);
                    is_udp     <= (byte_at(din_flat, l3_off + 7'd9) == PROTO_UDP);
                    is_ospf    <= (byte_at(din_flat, l3_off + 7'd9) == PROTO_OSPF);

                    // L4 ports (TCP or UDP)
                    if ((byte_at(din_flat, l3_off + 7'd9) == PROTO_TCP ||
                         byte_at(din_flat, l3_off + 7'd9) == PROTO_UDP) &&
                        din_len >= l3_off + ip_hlen + 7'd4) begin
                        udp_off = l3_off + ip_hlen;
                        l4_src <= {byte_at(din_flat, udp_off),
                                   byte_at(din_flat, udp_off + 7'd1)};
                        l4_dst <= {byte_at(din_flat, udp_off + 7'd2),
                                   byte_at(din_flat, udp_off + 7'd3)};
                    end

                    // PacketWyrm test header inside UDP payload
                    if (byte_at(din_flat, l3_off + 7'd9) == PROTO_UDP &&
                        din_len >= l3_off + ip_hlen + 7'd8) begin
                        udp_off = l3_off + ip_hlen;
                        pay_off = udp_off + 7'd8;
                        if (din_len >= pay_off + 7'd32 && {1'b0, pay_off} + 8'd32 <= 8'd128) begin
                            test_magic   <= {byte_at(din_flat, pay_off),
                                             byte_at(din_flat, pay_off + 7'd1),
                                             byte_at(din_flat, pay_off + 7'd2),
                                             byte_at(din_flat, pay_off + 7'd3)};
                            test_flow_id <= {byte_at(din_flat, pay_off + 7'd8),
                                             byte_at(din_flat, pay_off + 7'd9),
                                             byte_at(din_flat, pay_off + 7'd10),
                                             byte_at(din_flat, pay_off + 7'd11)};
                            test_sequence <= {byte_at(din_flat, pay_off + 7'd12),
                                              byte_at(din_flat, pay_off + 7'd13),
                                              byte_at(din_flat, pay_off + 7'd14),
                                              byte_at(din_flat, pay_off + 7'd15),
                                              byte_at(din_flat, pay_off + 7'd16),
                                              byte_at(din_flat, pay_off + 7'd17),
                                              byte_at(din_flat, pay_off + 7'd18),
                                              byte_at(din_flat, pay_off + 7'd19)};
                            test_tx_ts   <= {byte_at(din_flat, pay_off + 7'd20),
                                             byte_at(din_flat, pay_off + 7'd21),
                                             byte_at(din_flat, pay_off + 7'd22),
                                             byte_at(din_flat, pay_off + 7'd23),
                                             byte_at(din_flat, pay_off + 7'd24),
                                             byte_at(din_flat, pay_off + 7'd25),
                                             byte_at(din_flat, pay_off + 7'd26),
                                             byte_at(din_flat, pay_off + 7'd27)};
                            is_test <= ({byte_at(din_flat, pay_off),
                                         byte_at(din_flat, pay_off + 7'd1),
                                         byte_at(din_flat, pay_off + 7'd2),
                                         byte_at(din_flat, pay_off + 7'd3)} == PW_TEST_MAGIC);
                        end
                    end
                    key_valid <= 1'b1;
                end

                // IPv6
                else if (etype0 == ET_IPV6 && din_len >= l3_off + 7'd40) begin
                    l3_proto  <= byte_at(din_flat, l3_off + 7'd6);
                    ip_hlen    = 7'd40;
                    is_tcp    <= (byte_at(din_flat, l3_off + 7'd6) == PROTO_TCP);
                    is_udp    <= (byte_at(din_flat, l3_off + 7'd6) == PROTO_UDP);
                    is_icmp6  <= (byte_at(din_flat, l3_off + 7'd6) == PROTO_ICMP6);

                    if ((byte_at(din_flat, l3_off + 7'd6) == PROTO_TCP ||
                         byte_at(din_flat, l3_off + 7'd6) == PROTO_UDP) &&
                        din_len >= l3_off + ip_hlen + 7'd4) begin
                        udp_off = l3_off + ip_hlen;
                        l4_src <= {byte_at(din_flat, udp_off),
                                   byte_at(din_flat, udp_off + 7'd1)};
                        l4_dst <= {byte_at(din_flat, udp_off + 7'd2),
                                   byte_at(din_flat, udp_off + 7'd3)};
                    end
                    key_valid <= 1'b1;
                end

                // ARP
                else if (etype0 == ET_ARP) begin
                    key_valid <= 1'b1;
                end
            end  // din_valid
        end
    end

endmodule

`default_nettype wire
