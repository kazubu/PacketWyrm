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
    } pw_flow_row_t;

endpackage : pw_axis_pkg

`endif
