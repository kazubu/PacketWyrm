// PacketWyrm Phase 3 packet bus.
//
// For the skeleton data plane we carry an entire frame as a single
// wide transaction. The byte payload is a packed array of bytes so
// consumers can use `f.data[12]` as natural byte indexing. That
// sidesteps two problems we hit: the simulator mishandles
// runtime bit-slicing of wide packed vectors, and it cannot pass
// unpacked structs through ports cleanly. Phase 2/3 production RTL
// narrows the bus to 64 bits at 156.25 MHz with proper SOP/EOP.

`ifndef PW_AXIS_PKG_SV
`define PW_AXIS_PKG_SV

package pw_axis_pkg;

    parameter int PW_FRAME_MAX_BYTES = 1536;
    parameter int PW_FRAME_LEN_W     = $clog2(PW_FRAME_MAX_BYTES + 1);

    typedef logic [7:0] pw_byte_t;
    typedef pw_byte_t [PW_FRAME_MAX_BYTES-1:0] pw_frame_data_t;

    typedef struct packed {
        pw_frame_data_t              data;
        logic [PW_FRAME_LEN_W-1:0]   len;
        logic [3:0]                  ingress_port;
    } pw_frame_t;

    function automatic pw_frame_t pw_frame_zero();
        pw_frame_t f;
        f      = '0;
        return f;
    endfunction

    // One generator flow slot, decoded from a flow-window row. The
    // multi-flow generator (pw_flow_gen_multi) holds an array of these per
    // egress port and round-robins the ones whose egress matches.
    typedef struct packed {
        logic        valid;       // enable && tx_enable
        logic [3:0]  egress;      // egress local port this flow drives
        logic [31:0] flow_id;     // emitted test-header flow_id
        logic [31:0] tokens_fp;   // Q16.16 bytes/cycle
        logic [15:0] burst;       // token-bucket cap, bytes
        logic [47:0] src_mac;
        logic [47:0] dst_mac;
        logic        vlan_en;
        logic [11:0] vlan_id;
        logic [31:0] src_ipv4;
        logic [31:0] dst_ipv4;
        logic [15:0] udp_sp;
        logic [15:0] udp_dp;
        logic [7:0]  dscp;      // 6-bit DSCP in [7:2]; emitted as IPv4 TOS /
                                // IPv6 traffic class (no effect on UDP csum).
        logic [7:0]  ttl;       // IPv4 TTL / IPv6 hop limit.
        // Per-field modifiers (commercial-gen "field modifier"): vary the
        // masked bits of a header field per emitted frame so one slot looks
        // like many flows to the DUT. mode: 0=static, 1=increment, 2=random.
        // Rotated bits are driven by the slot's per-frame sequence number
        // (increment = seq, random = scrambled seq) -> no extra per-slot
        // state. The test header (magic/flow_id/seq/ts) is NOT modified, so
        // RX loss/latency measurement is unaffected; the IPv4/IPv6 checksums
        // are recomputed from the modified addresses. The src/dst address
        // modifiers apply to the flow's active family: the 32-bit IPv4 address
        // for v4 flows, or the low 32 bits of the IPv6 address for v6 flows
        // (the host/interface-ID portion -- enough for DUT hashing / ECMP).
        logic [1:0]  sip_mod;   logic [31:0] sip_mask;
        logic [1:0]  dip_mod;   logic [31:0] dip_mask;
        logic [1:0]  sp_mod;    logic [15:0] sp_mask;
        logic [1:0]  dp_mod;    logic [15:0] dp_mask;
        // MAC / VLAN modifiers (same scheme; not in any checksum -- the
        // generator just rewrites the Ethernet header bytes).
        logic [1:0]  smac_mod;  logic [47:0] smac_mask;
        logic [1:0]  dmac_mod;  logic [47:0] dmac_mask;
        logic [1:0]  vlan_mod;  logic [15:0] vlan_mask;   // low 12 bits used
        // IPv6: when is_v6, the slot emits an IPv6/UDP frame (0x86DD, 40-byte
        // header, correct non-zero UDP checksum) using these addresses.
        logic         is_v6;
        logic [127:0] ipv6_src;
        logic [127:0] ipv6_dst;
    } pw_flow_row_t;

endpackage : pw_axis_pkg

`endif
