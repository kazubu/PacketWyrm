// Unit testbench for pw_hash_classifier: program table entries (computing the
// bucket with the same hash the DUT uses) + check exact header-key lookup.

`default_nettype none

import pw_classifier_pkg::*;

module tb_hash_classifier;
    localparam int NUM_FLOWS = 32;
    localparam int DEPTH = 128;
    localparam int IDX_W = $clog2(DEPTH);
    localparam int LFW   = $clog2(NUM_FLOWS);
    localparam int KW    = 168;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    pw_match_key_t            key;
    logic                     key_valid;
    logic [31:0]              seed;
    logic                     wr_en;
    logic [IDX_W-1:0]         wr_index;
    logic                     wr_valid;
    logic [KW-1:0]            wr_key;
    logic [LFW-1:0]           wr_lfid;
    logic                     valid_o;
    logic [LFW-1:0]           lfid_o;

    pw_hash_classifier #(.NUM_FLOWS(NUM_FLOWS), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .key_i(key), .key_valid_i(key_valid), .seed_i(seed),
        .wr_en(wr_en), .wr_index(wr_index), .wr_valid(wr_valid), .wr_key(wr_key),
        .wr_lfid(wr_lfid), .valid_o(valid_o), .local_flow_id_o(lfid_o)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++; end
        else $display("[ ok ] %s: %0d", what, got);
    endtask

    // mirror the DUT hash exactly
    function automatic logic [KW-1:0] mk_key(input logic [127:0] l3dst, input logic [15:0] ld,
                                             input logic [15:0] ls, input logic [7:0] proto);
        return {l3dst, ld, ls, proto};
    endfunction
    function automatic logic [IDX_W-1:0] idx_of(input logic [KW-1:0] k, input logic [31:0] sd);
        logic [191:0] kp; logic [31:0] k32, prod;
        kp = {24'b0, k};
        k32  = kp[31:0]^kp[63:32]^kp[95:64]^kp[127:96]^kp[159:128]^kp[191:160];
        prod = k32 * (sd | 32'd1);
        return prod[31 -: IDX_W];
    endfunction

    task automatic prog(input logic [KW-1:0] k, input int lf);
        @(negedge clk);
        wr_en=1; wr_index=idx_of(k, seed); wr_valid=1; wr_key=k; wr_lfid=lf[LFW-1:0];
        @(negedge clk); wr_en=0;
    endtask

    // drive an IPv4 frame key and pulse valid; result valid 2 cycles later
    task automatic lookup_v4(input logic [31:0] dst, input logic [15:0] ld,
                             input logic [15:0] ls, input logic [7:0] proto);
        @(negedge clk);
        key = '0; key.is_ipv4 = 1; key.ipv4_dst = dst; key.l4_dst = ld;
        key.l4_src = ls; key.l3_proto = proto;
        key_valid = 1; @(negedge clk); key_valid = 0; @(negedge clk);
    endtask

    logic [KW-1:0] kA, kB, kC;
    initial begin
        key='0; key_valid=0; seed=32'h9E3779B1; // golden-ratio-ish odd seed
        wr_en=0; wr_index=0; wr_valid=0; wr_key=0; wr_lfid=0;
        repeat (3) @(negedge clk); rst_n=1; @(negedge clk);

        // flow A: 192.0.2.1 / udp 50001 <- 49152, proto 17  -> slot 5
        kA = mk_key({96'b0, 32'hC000_0201}, 16'd50001, 16'd49152, 8'd17);
        // flow B: 192.0.2.2 / udp 50002                      -> slot 6
        kB = mk_key({96'b0, 32'hC000_0202}, 16'd50002, 16'd49152, 8'd17);
        prog(kA, 5);
        prog(kB, 6);

        // exact match A
        lookup_v4(32'hC000_0201, 16'd50001, 16'd49152, 8'd17);
        chk("A hit", valid_o, 1);
        chk("A lfid", lfid_o, 5);

        // exact match B
        lookup_v4(32'hC000_0202, 16'd50002, 16'd49152, 8'd17);
        chk("B hit", valid_o, 1);
        chk("B lfid", lfid_o, 6);

        // unprogrammed key -> miss (either empty bucket or verify rejects)
        lookup_v4(32'hC000_02FF, 16'd50099, 16'd49152, 8'd17);
        chk("miss", valid_o, 0);

        // same dst/ports as A but different proto -> different key -> miss
        lookup_v4(32'hC000_0201, 16'd50001, 16'd49152, 8'd6);
        chk("proto-differs miss", valid_o, 0);

        if (errors == 0) $display("ALL HASH_CLASSIFIER SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
