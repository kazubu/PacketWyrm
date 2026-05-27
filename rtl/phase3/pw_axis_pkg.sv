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

endpackage : pw_axis_pkg

`endif
