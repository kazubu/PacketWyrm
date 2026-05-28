// Behavioral reference classifier for cocotb unit testing.
//
// Exposes a flat interface: each table entry is encoded in a 96-bit
// vector so Python can drive the table without constructing packed
// structs.
//
// Entry encoding (96 bits, big-endian field ordering):
//   [95]      enable
//   [94:92]   action (0=DROP, 1=TEST_RX, 2=PUNT, 4=FORWARD)
//   [91:84]   priority (lower wins)
//   [83:52]   local_flow_id
//   [51:36]   l4_dst
//   [35:28]   l3_proto
//   [27]      mask_l4_dst
//   [26]      mask_l3_proto
//   [25]      mask_is_test
//   [24]      mask_flow_id
//   [23:0]    reserved / zero
//
// Key encoding (flat individual signals): most fields from pw_parser_beh.
//
// Result: combinational (no clock dependency beyond key inputs).

`timescale 1ns/1ps
`default_nettype none

module pw_classifier_beh #(
    parameter integer ENTRIES = 4
) (
    // Table: one 96-bit entry per row
    input  wire [95:0] entry [0:3],

    // Key inputs (from parser)
    input  wire        key_valid,
    input  wire        key_is_test,
    input  wire [15:0] key_l4_dst,
    input  wire [7:0]  key_l3_proto,
    input  wire [31:0] key_flow_id,

    // Result (combinational)
    output reg         res_hit,
    output reg  [2:0]  res_action,
    output reg  [31:0] res_flow_id,
    output reg  [7:0]  res_priority
);

    // Decode helpers
    function entry_enable;  input [95:0] e; entry_enable = e[95];    endfunction
    function [2:0] entry_action;  input [95:0] e; entry_action = e[94:92]; endfunction
    function [7:0] entry_prio;    input [95:0] e; entry_prio  = e[91:84]; endfunction
    function [31:0] entry_fid;    input [95:0] e; entry_fid   = e[83:52]; endfunction
    function [15:0] entry_l4dst;  input [95:0] e; entry_l4dst = e[51:36]; endfunction
    function [7:0]  entry_l3p;    input [95:0] e; entry_l3p   = e[35:28]; endfunction
    function entry_mk_l4dst;      input [95:0] e; entry_mk_l4dst = e[27]; endfunction
    function entry_mk_l3p;        input [95:0] e; entry_mk_l3p   = e[26]; endfunction
    function entry_mk_test;       input [95:0] e; entry_mk_test  = e[25]; endfunction
    function entry_mk_fid;        input [95:0] e; entry_mk_fid   = e[24]; endfunction

    function entry_matches;
        input [95:0] e;
        input        valid;
        input        is_test;
        input [15:0] l4_dst;
        input [7:0]  l3_proto;
        input [31:0] flow_id;
        reg m_l4dst, m_l3p, m_test, m_fid;
        begin
            if (!valid || !entry_enable(e)) begin
                entry_matches = 1'b0;
            end else begin
                m_l4dst = ~entry_mk_l4dst(e) | (l4_dst   == entry_l4dst(e));
                m_l3p   = ~entry_mk_l3p(e)   | (l3_proto == entry_l3p(e));
                m_test  = ~entry_mk_test(e)   | is_test;
                m_fid   = ~entry_mk_fid(e)    | (flow_id  == entry_fid(e));
                entry_matches = m_l4dst & m_l3p & m_test & m_fid;
            end
        end
    endfunction

    integer i;
    always @(*) begin
        res_hit      = 1'b0;
        res_action   = 3'd0;
        res_flow_id  = 32'd0;
        res_priority = 8'hFF;

        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (entry_matches(entry[i], key_valid, key_is_test,
                              key_l4_dst, key_l3_proto, key_flow_id)) begin
                if (!res_hit || entry_prio(entry[i]) < res_priority) begin
                    res_hit      = 1'b1;
                    res_action   = entry_action(entry[i]);
                    res_flow_id  = entry_fid(entry[i]);
                    res_priority = entry_prio(entry[i]);
                end
            end
        end
    end

endmodule

`default_nettype wire
