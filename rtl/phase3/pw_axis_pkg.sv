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

    // Compact per-slot SCHEDULING descriptor. The flow table keeps an array
    // of these in flip-flops (one per slot, all slots visible every cycle) so
    // the generator's eligibility / round-robin pick / token bucket can run
    // without reading the wide row. The wide frame-content fields live in a
    // BRAM read only for the picked slot (see pw_flow_table_bram). cost/cap are
    // Q16.16 (frame_bytes<<16 / burst<<16), precomputed at table-commit time.
    typedef struct packed {
        logic        valid;       // enable && tx_enable
        logic [3:0]  egress;      // egress local port this flow drives
        logic [31:0] tokens_fp;   // Q16.16 bytes/cycle (token refill rate)
        logic [31:0] cap;         // token-bucket cap, Q16.16 (burst<<16)
        logic [31:0] cost;        // one frame's token cost, Q16.16 (bytes<<16)
        // Variable frame length: the generator sweeps the emitted total L2
        // frame length len_min -> len_max by len_step (wrapping). RFC2544 uses
        // a fixed size (min==max); a min<max range gives IMIX/staircase sizing.
        // Held in the (FF) scheduling descriptor so the per-slot sweep needs no
        // BRAM read. 0 / sub-minimum values clamp to the minimum legal frame.
        logic [15:0] len_min;
        logic [15:0] len_max;
        logic [15:0] len_step;
        logic [11:0] ovh;         // header overhead bytes (0-payload frame); the
                                  // generator derives L4 payload = frame_len - ovh
    } pw_flow_sched_t;

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
        // Variable total L2 frame length: emitted length sweeps min->max by
        // step (wrapping). min==max gives a fixed size (RFC2544). The L4 payload
        // is (frame_len - headers); the pad beyond the 32-byte test header is
        // zero, so it adds nothing to the UDP checksum (only the length fields
        // change). Sub-minimum values clamp to the smallest legal frame.
        logic [15:0] frame_len_min;
        logic [15:0] frame_len_max;
        logic [15:0] frame_len_step;
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
        // Full 128-bit IPv6 address modifiers: sip_mask/dip_mask hold address
        // bits [31:0] (also the IPv4 mask); these *_mask_hi hold bits [127:32].
        // The full v6 mask = {*_mask_hi, *_mask}. Zero (default) = low-32-only
        // (back-compatible with the original v6 host-ID rotation).
        logic [95:0] sip_mask_hi;
        logic [95:0] dip_mask_hi;
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
        // Encapsulation: wrap the inner frame in an outer L3 + tunnel header.
        // encap_type 0=none/1=ipip/2=gre/3=etherip; outer_v6 selects the outer
        // L3 family (independent of is_v6). rx_tunneled is informational.
        logic [1:0]   encap_type;
        logic         outer_v6;
        logic         rx_tunneled;
        logic [7:0]   outer_ttl;
        logic [7:0]   outer_dscp;
        logic [31:0]  outer_src_ipv4;
        logic [31:0]  outer_dst_ipv4;
        logic [127:0] outer_ipv6_src;
        logic [127:0] outer_ipv6_dst;
        // EtherIP inner-Ethernet MAC (compiler fills from inner_l2 or the flow
        // MAC). Not modified by the field modifiers.
        logic [47:0]  inner_src_mac;
        logic [47:0]  inner_dst_mac;
    } pw_flow_row_t;

    parameter int PW_FLOW_ROW_BYTES = 256;   // wire stride (struct pwfpga_flow_config)

    // Decode one 256-byte flow-table wire row (byte k in row[k*8 +: 8]) into the
    // generator's pw_flow_row_t. Single source of truth shared by the legacy
    // pw_flow_window decode and the BRAM-backed pw_flow_table_bram commit walk.
    function automatic pw_flow_row_t pw_decode_flow_row(input logic [PW_FLOW_ROW_BYTES*8-1:0] row);
        pw_flow_row_t f;
        f = '0;
        f.valid     = row[0*8 +: 8] & row[90*8 +: 8];      // enable && tx_enable
        f.egress    = row[1*8 +: 4];
        f.flow_id   = {row[5*8 +: 8], row[4*8 +: 8], row[3*8 +: 8], row[2*8 +: 8]};
        f.tokens_fp = {row[78*8 +: 8], row[77*8 +: 8], row[76*8 +: 8], row[75*8 +: 8]};
        f.burst     = {row[80*8 +: 8], row[79*8 +: 8]};
        f.src_mac   = {row[20*8 +: 8], row[21*8 +: 8], row[22*8 +: 8],
                       row[23*8 +: 8], row[24*8 +: 8], row[25*8 +: 8]};
        f.dst_mac   = {row[14*8 +: 8], row[15*8 +: 8], row[16*8 +: 8],
                       row[17*8 +: 8], row[18*8 +: 8], row[19*8 +: 8]};
        f.vlan_en   = row[26*8 +: 1];
        f.vlan_id   = {row[28*8 +: 4], row[27*8 +: 8]};
        f.src_ipv4  = {row[34*8 +: 8], row[33*8 +: 8], row[32*8 +: 8], row[31*8 +: 8]};
        f.dst_ipv4  = {row[38*8 +: 8], row[37*8 +: 8], row[36*8 +: 8], row[35*8 +: 8]};
        f.udp_sp    = {row[42*8 +: 8], row[41*8 +: 8]};
        f.udp_dp    = {row[44*8 +: 8], row[43*8 +: 8]};
        f.dscp      = row[39*8 +: 8];
        f.ttl       = row[40*8 +: 8];
        f.frame_len_min  = {row[46*8 +: 8], row[45*8 +: 8]};
        f.frame_len_max  = {row[48*8 +: 8], row[47*8 +: 8]};
        f.frame_len_step = {row[50*8 +: 8], row[49*8 +: 8]};
        f.sip_mod   = row[92*8 +: 2];
        f.sip_mask  = {row[96*8 +: 8], row[95*8 +: 8], row[94*8 +: 8], row[93*8 +: 8]};
        f.dip_mod   = row[97*8 +: 2];
        f.dip_mask  = {row[101*8 +: 8], row[100*8 +: 8], row[99*8 +: 8], row[98*8 +: 8]};
        f.sp_mod    = row[102*8 +: 2];
        f.sp_mask   = {row[104*8 +: 8], row[103*8 +: 8]};
        f.dp_mod    = row[105*8 +: 2];
        f.dp_mask   = {row[107*8 +: 8], row[106*8 +: 8]};
        f.smac_mod  = row[140*8 +: 2];
        f.smac_mask = {row[141*8 +: 8], row[142*8 +: 8], row[143*8 +: 8],
                       row[144*8 +: 8], row[145*8 +: 8], row[146*8 +: 8]};
        f.dmac_mod  = row[147*8 +: 2];
        f.dmac_mask = {row[148*8 +: 8], row[149*8 +: 8], row[150*8 +: 8],
                       row[151*8 +: 8], row[152*8 +: 8], row[153*8 +: 8]};
        f.vlan_mod  = row[154*8 +: 2];
        f.vlan_mask = {row[156*8 +: 8], row[155*8 +: 8]};
        f.is_v6     = (row[30*8 +: 8] == 8'd6);
        for (int b = 0; b < 16; b++) begin
            f.ipv6_src[127 - b*8 -: 8] = row[(108+b)*8 +: 8];
            f.ipv6_dst[127 - b*8 -: 8] = row[(124+b)*8 +: 8];
        end
        f.encap_type    = row[157*8 +: 2];
        f.outer_v6      = (row[158*8 +: 8] == 8'd6);
        f.rx_tunneled   = row[159*8 +: 1];
        f.outer_ttl     = row[160*8 +: 8];
        f.outer_dscp    = row[161*8 +: 8];
        f.outer_src_ipv4 = {row[165*8 +: 8], row[164*8 +: 8], row[163*8 +: 8], row[162*8 +: 8]};
        f.outer_dst_ipv4 = {row[169*8 +: 8], row[168*8 +: 8], row[167*8 +: 8], row[166*8 +: 8]};
        for (int b = 0; b < 16; b++) begin
            f.outer_ipv6_src[127 - b*8 -: 8] = row[(170+b)*8 +: 8];
            f.outer_ipv6_dst[127 - b*8 -: 8] = row[(186+b)*8 +: 8];
        end
        f.inner_dst_mac = {row[202*8 +: 8], row[203*8 +: 8], row[204*8 +: 8],
                           row[205*8 +: 8], row[206*8 +: 8], row[207*8 +: 8]};
        f.inner_src_mac = {row[208*8 +: 8], row[209*8 +: 8], row[210*8 +: 8],
                           row[211*8 +: 8], row[212*8 +: 8], row[213*8 +: 8]};
        // IPv6 mask high 96 bits (address [127:32]); little-endian like sip_mask
        // (low byte = address bit 32). Bytes 214..225 (src), 226..237 (dst).
        for (int b = 0; b < 12; b++) begin
            f.sip_mask_hi[b*8 +: 8] = row[(214+b)*8 +: 8];
            f.dip_mask_hi[b*8 +: 8] = row[(226+b)*8 +: 8];
        end
        return f;
    endfunction

    // On-wire frame length (bytes) of a decoded row, accounting for VLAN, inner
    // L3 family, and any encapsulation. FRAME_LEN_PAYLOAD is the L4 payload.
    // Mirrors pw_flow_gen_multi's frame_bytes_row (the generator's token cost).
    function automatic int pw_frame_bytes(input pw_flow_row_t r, input int payload);
        int inner, enc_hdr;
        inner = (r.is_v6 ? 40 : 20) + 8 + payload;
        case (r.encap_type)
            2'd2:    enc_hdr = 4;
            2'd3:    enc_hdr = 16;
            default: enc_hdr = 0;
        endcase
        if (r.encap_type == 2'd0)
            return 14 + (r.vlan_en ? 4 : 0) + inner;
        else
            return 14 + (r.vlan_en ? 4 : 0) + (r.outer_v6 ? 40 : 20) + enc_hdr + inner;
    endfunction

endpackage : pw_axis_pkg

`endif
