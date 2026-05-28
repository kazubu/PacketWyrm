// PacketWyrm classifier table CSR window.
//
// Adapts the byte-oriented pw_csr_window output (matching the host
// wire struct `pwfpga_classifier_entry` in csr.h) to the typed
// `pw_classifier_table_t` that pw_data_plane consumes.
//
// Wire layout per row (matches the packed C struct in csr.h):
//   key  @ 0..39   (pwfpga_match_key, little-endian)
//   mask @ 40..79  (same shape; non-zero means "match this field")
//   logical_if_id  @ 80..83 (LE u32)
//   local_flow_id  @ 84..87 (LE u32)
//   action         @ 88     (uint8_t, enum pwfpga_action)
//   priority       @ 89     (uint8_t, lower wins)
//   flags          @ 90..91 (LE u16; bit 0 = ENABLE)
//
// Fields in pw_match_key_t that the wire struct does not carry
// (IPv6 addresses, the protocol-class flags, MAC addresses, the
// test sequence/timestamp) come from the parser, not the table,
// and stay zero in the table entry.

`default_nettype none

import pw_classifier_pkg::*;

module pw_classifier_window #(
    parameter int                ADDR_W        = 16,
    parameter logic [15:0]       WIN_BASE      = 16'h1000,
    parameter logic [15:0]       COMMIT_OFFSET = 16'h0FFC
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [31:0]           wr_data,

    output pw_classifier_table_t cls_table_o,
    output logic                 commit_pulse_o
);

    localparam int DEPTH     = PW_CLASSIFIER_ENTRIES;  // 8
    localparam int ROW_BYTES = 128;

    logic [DEPTH-1:0][ROW_BYTES*8-1:0] live_rows;

    pw_csr_window #(
        .ADDR_W       (ADDR_W),
        .DEPTH        (DEPTH),
        .ROW_BYTES    (ROW_BYTES),
        .WIN_BASE     (WIN_BASE[ADDR_W-1:0]),
        .COMMIT_OFFSET(COMMIT_OFFSET[ADDR_W-1:0])
    ) u_win (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .live_rows_o    (live_rows),
        .commit_pulse_o (commit_pulse_o)
    );

    // Decode the byte view into a typed table. Verilator-safe:
    // procedural code in a single always_comb against a packed
    // bit array; no continuous assigns into unpacked elements.
    always_comb begin
        for (int r = 0; r < DEPTH; r++) begin
            logic [ROW_BYTES*8-1:0] row;
            logic [15:0]            flags;
            int                     ko;   // key   byte offset within row
            int                     mo;   // mask  byte offset within row
            row = live_rows[r];
            ko  = 0;
            mo  = 40;
            flags = {row[91*8 +: 8], row[90*8 +: 8]};

            cls_table_o[r]               = '0;
            cls_table_o[r].enable        = flags[0];
            cls_table_o[r].action        = pw_action_e'(row[88*8 +: 8]);
            cls_table_o[r].priority_     = row[89*8 +: 8];
            cls_table_o[r].egress_port   = '0;  // not in wire struct yet
            cls_table_o[r].local_flow_id = {row[(84+3)*8 +: 8], row[(84+2)*8 +: 8],
                                            row[(84+1)*8 +: 8], row[(84+0)*8 +: 8]};
            cls_table_o[r].logical_if_id = {row[(80+3)*8 +: 8], row[(80+2)*8 +: 8],
                                            row[(80+1)*8 +: 8], row[(80+0)*8 +: 8]};

            // Key fields the wire struct carries.
            cls_table_o[r].key.ethertype = {row[(ko+1)*8 +: 8], row[(ko+0)*8 +: 8]};
            cls_table_o[r].key.vlan_id   = {row[(ko+3)*8 +: 8], row[(ko+2)*8 +: 8]} [11:0];
            cls_table_o[r].key.l3_proto  = row[(ko+5)*8 +: 8];
            cls_table_o[r].key.ingress_port = row[(ko+6)*8 +: 8] [3:0];
            cls_table_o[r].key.l4_src    = {row[(ko+9)*8 +: 8], row[(ko+8)*8 +: 8]};
            cls_table_o[r].key.l4_dst    = {row[(ko+11)*8 +: 8], row[(ko+10)*8 +: 8]};
            cls_table_o[r].key.udp_src   = cls_table_o[r].key.l4_src;
            cls_table_o[r].key.udp_dst   = cls_table_o[r].key.l4_dst;
            cls_table_o[r].key.ipv4_src  = {row[(ko+15)*8 +: 8], row[(ko+14)*8 +: 8],
                                            row[(ko+13)*8 +: 8], row[(ko+12)*8 +: 8]};
            cls_table_o[r].key.ipv4_dst  = {row[(ko+19)*8 +: 8], row[(ko+18)*8 +: 8],
                                            row[(ko+17)*8 +: 8], row[(ko+16)*8 +: 8]};
            cls_table_o[r].key.test_magic = {row[(ko+35)*8 +: 8], row[(ko+34)*8 +: 8],
                                             row[(ko+33)*8 +: 8], row[(ko+32)*8 +: 8]};
            cls_table_o[r].key.test_flow_id = {row[(ko+39)*8 +: 8], row[(ko+38)*8 +: 8],
                                               row[(ko+37)*8 +: 8], row[(ko+36)*8 +: 8]};

            // Mask: each per-field bit becomes set if any byte of the
            // corresponding wire-mask field is non-zero.
            cls_table_o[r].mask.match_ethertype    =
                |{row[(mo+1)*8 +: 8], row[(mo+0)*8 +: 8]};
            cls_table_o[r].mask.match_vlan_id      =
                |{row[(mo+3)*8 +: 8], row[(mo+2)*8 +: 8]};
            cls_table_o[r].mask.match_l3_proto     = |row[(mo+5)*8 +: 8];
            cls_table_o[r].mask.match_ingress_port = |row[(mo+6)*8 +: 8];
            cls_table_o[r].mask.match_l4_src       =
                |{row[(mo+9)*8 +: 8], row[(mo+8)*8 +: 8]};
            cls_table_o[r].mask.match_l4_dst       =
                |{row[(mo+11)*8 +: 8], row[(mo+10)*8 +: 8]};
            cls_table_o[r].mask.match_udp_src      = cls_table_o[r].mask.match_l4_src;
            cls_table_o[r].mask.match_udp_dst      = cls_table_o[r].mask.match_l4_dst;
            cls_table_o[r].mask.match_ipv4_src     =
                |{row[(mo+15)*8 +: 8], row[(mo+14)*8 +: 8],
                  row[(mo+13)*8 +: 8], row[(mo+12)*8 +: 8]};
            cls_table_o[r].mask.match_ipv4_dst     =
                |{row[(mo+19)*8 +: 8], row[(mo+18)*8 +: 8],
                  row[(mo+17)*8 +: 8], row[(mo+16)*8 +: 8]};
            cls_table_o[r].mask.match_is_test      =
                |{row[(mo+35)*8 +: 8], row[(mo+34)*8 +: 8],
                  row[(mo+33)*8 +: 8], row[(mo+32)*8 +: 8]};
            cls_table_o[r].mask.match_flow_id      =
                |{row[(mo+39)*8 +: 8], row[(mo+38)*8 +: 8],
                  row[(mo+37)*8 +: 8], row[(mo+36)*8 +: 8]};
            // IPv6 / inner-VLAN / protocol-class match bits are not
            // configurable from the current wire struct; they stay 0.
        end
    end

endmodule

`default_nettype wire
