// Unit testbench for pw_slice_match: program {offset, mask, value} over a
// known header window and check the masked big-endian compare + base+offset.

`default_nettype none

module tb_slice_match;

    localparam int HDR_BYTES = 160;

    logic [HDR_BYTES*8-1:0] window;
    logic [15:0] base, offset;
    logic [31:0] mask, value;
    logic        match;

    pw_slice_match #(.HDR_BYTES(HDR_BYTES)) dut (
        .window_i(window), .base_i(base), .offset_i(offset),
        .mask_i(mask), .value_i(value), .match_o(match)
    );

    int errors = 0;
    task automatic chk(string what, logic got, logic exp);
        if (got !== exp) begin
            $display("[FAIL] %s: got=%b exp=%b", what, got, exp); errors++;
        end else $display("[ ok ] %s: %b", what, got);
    endtask

    task automatic setb(input int idx, input logic [7:0] v);
        window[idx*8 +: 8] = v;
    endtask

    initial begin
        window = '0;
        // udp_dst = 50001 = 0xC351 at byte 36..37; flow_id = 7 at 40..43.
        setb(36, 8'hC3); setb(37, 8'h51);
        setb(40, 8'h00); setb(41, 8'h00); setb(42, 8'h00); setb(43, 8'h07);
        #1;

        // exact 2-byte field at 36 (mask high half)
        base = 0; offset = 36; mask = 32'hFFFF_0000; value = 32'hC351_0000; #1;
        chk("udp_dst match", match, 1'b1);
        value = 32'hC352_0000; #1;
        chk("udp_dst wrong", match, 1'b0);

        // base + offset address the same field
        base = 16'd4; offset = 16'd32; mask = 32'hFFFF_0000; value = 32'hC351_0000; #1;
        chk("base+offset", match, 1'b1);

        // 4-byte flow_id field at 40
        base = 0; offset = 40; mask = 32'hFFFF_FFFF; value = 32'h0000_0007; #1;
        chk("flow_id match", match, 1'b1);
        value = 32'h0000_0008; #1;
        chk("flow_id wrong", match, 1'b0);

        // partial mask (only top byte of the udp field)
        offset = 36; mask = 32'hFF00_0000; value = 32'hC300_0000; #1;
        chk("partial mask", match, 1'b1);

        // mask 0 = don't care -> always match
        mask = 32'h0; value = 32'hDEAD_BEEF; #1;
        chk("mask0 wildcard", match, 1'b1);

        // out-of-window offset reads 0
        offset = 16'd400; mask = 32'hFFFF_FFFF; value = 32'h0; #1;
        chk("oob reads zero", match, 1'b1);
        value = 32'h1; #1;
        chk("oob nonzero no match", match, 1'b0);

        if (errors == 0) $display("ALL SLICE_MATCH SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end

endmodule

`default_nettype wire
