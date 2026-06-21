// PacketWyrm generic classifier slice-match unit.
//
// One programmable {offset, mask, value} matcher over the parser's captured
// header byte window. Extracts a 32-bit big-endian (network-order) lane at a
// byte offset, masks it, and compares to a programmed value:
//
//   ext        = bytes[offset .. offset+3]   (byte offset -> MSB-first)
//   match_o    = (ext & mask) == (value & mask)
//
// Width is encoded in the mask (a 2-byte field at offset O -> mask 0xFFFF_0000,
// value = field << 16), so no separate width field is needed. A mask of 0
// matches unconditionally (the slice is "don't care" / unused).
//
// `NSLICE` of these are shared across all flows (see docs/design/
// generic-classifier.md): the expensive byte extract + masked compare happens
// once per unit, not replicated per flow. Offsets are relative to the inner
// (decapsulated) frame base the parser provides, so matching is protocol- and
// encap-agnostic and reprogrammable in software.

`default_nettype none

module pw_slice_match #(
    parameter int HDR_BYTES = 160          // captured header window depth
) (
    input  wire [HDR_BYTES*8-1:0] window_i,   // byte b at window_i[b*8 +: 8]
    input  wire [15:0]            base_i,     // inner-frame base byte offset
    input  wire [15:0]            offset_i,   // field offset within the inner frame
    input  wire [31:0]            mask_i,
    input  wire [31:0]            value_i,
    output logic                  match_o
);

    // Absolute byte offset of the field within the captured window.
    wire [15:0] off = base_i + offset_i;

    // Extract 4 bytes big-endian (network order: first byte is the MSB).
    // Out-of-window bytes read as 0 (a mask that needs them simply won't match).
    function automatic logic [7:0] byte_at(input logic [15:0] b);
        return (b < HDR_BYTES) ? window_i[b*8 +: 8] : 8'h00;
    endfunction

    wire [31:0] ext = { byte_at(off),
                        byte_at(off + 16'd1),
                        byte_at(off + 16'd2),
                        byte_at(off + 16'd3) };

    assign match_o = ((ext & mask_i) == (value_i & mask_i));

endmodule

`default_nettype wire
