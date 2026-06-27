// Unit testbench for pw_hash_classifier: program table entries (computing the
// bucket with the same hash the DUT uses) + check wide masked-key lookup,
// including a key mask that excludes a randomized field.

`default_nettype none

import pw_classifier_pkg::*;

module tb_hash_classifier;
    localparam int NUM_FLOWS = 32;
    localparam int DEPTH = 128;
    localparam int IDX_W = $clog2(DEPTH);
    localparam int LFW   = $clog2(NUM_FLOWS);
    localparam int KW    = 11;
    localparam int KB    = KW * 32;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    pw_match_key_t            key;
    logic                     key_valid;
    logic [31:0]              seed;
    logic [KB-1:0]            mask;
    logic                     wr_en;
    logic [IDX_W-1:0]         wr_index;
    logic                     wr_valid;
    logic [KB-1:0]            wr_key;
    logic [LFW-1:0]           wr_lfid;
    logic                     valid_o;
    logic [LFW-1:0]           lfid_o;

    pw_hash_classifier #(.NUM_FLOWS(NUM_FLOWS), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .key_i(key), .key_valid_i(key_valid), .seed_i(seed),
        .mask_i(mask), .wr_en(wr_en), .wr_index(wr_index), .wr_valid(wr_valid),
        .wr_key(wr_key), .wr_lfid(wr_lfid), .valid_o(valid_o), .local_flow_id_o(lfid_o)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++; end
        else $display("[ ok ] %s: %0d", what, got);
    endtask

    // build the 11-word key (matches the DUT assemble) for a v4 5-tuple
    function automatic logic [KB-1:0] mk_v4(input logic [31:0] dst, input logic [31:0] src,
                                            input logic [15:0] ld, input logic [15:0] ls,
                                            input logic [7:0] proto);
        logic [31:0] w [KW];
        w[0]=dst; w[1]=0; w[2]=0; w[3]=0;
        w[4]=src; w[5]=0; w[6]=0; w[7]=0;
        w[8]={ls, ld};
        w[9]={3'b0,1'b0,12'b0, 16'h0800};      // ethertype IPv4, no vlan
        w[10]={24'b0, proto};
        return {w[10],w[9],w[8],w[7],w[6],w[5],w[4],w[3],w[2],w[1],w[0]};
    endfunction
    function automatic logic [IDX_W-1:0] idx_of(input logic [KB-1:0] mk, input logic [31:0] sd);
        logic [31:0] k32, prod; k32=0;
        for (int i=0;i<KW;i++) k32 ^= mk[i*32 +: 32];
        prod = k32 * (sd | 32'd1);
        return prod[31 -: IDX_W];
    endfunction

    task automatic prog(input logic [KB-1:0] k, input int lf);  // k already masked
        @(negedge clk);
        wr_en=1; wr_index=idx_of(k, seed); wr_valid=1; wr_key=k; wr_lfid=lf[LFW-1:0];
        @(negedge clk); wr_en=0;
    endtask
    task automatic lookup(input logic [31:0] dst, input logic [31:0] src,
                          input logic [15:0] ld, input logic [15:0] ls, input logic [7:0] proto);
        @(negedge clk);
        key='0; key.is_ipv4=1; key.ipv4_dst=dst; key.ipv4_src=src;
        key.l4_dst=ld; key.l4_src=ls; key.l3_proto=proto; key.ethertype=16'h0800;
        key_valid=1; @(negedge clk); key_valid=0;
        @(negedge clk); @(negedge clk); @(negedge clk);   // latency 4 (k32 fold register stage added)
    endtask

    logic [KB-1:0] kA, kB;
    initial begin
        key='0; key_valid=0; seed=32'h9E3779B1; mask='1;   // full mask = exact 5-tuple
        wr_en=0; wr_index=0; wr_valid=0; wr_key=0; wr_lfid=0;
        repeat (3) @(negedge clk); rst_n=1; @(negedge clk);

        // --- exact full 5-tuple ---
        kA = mk_v4(32'hC000_0202, 32'hC000_0201, 16'd50001, 16'd49152, 8'd17);
        prog(kA, 5);
        lookup(32'hC000_0202, 32'hC000_0201, 16'd50001, 16'd49152, 8'd17);
        chk("exact hit", valid_o, 1);
        chk("exact lfid", lfid_o, 5);
        // different SRC IP -> different key -> miss (src IP is in the key now)
        lookup(32'hC000_0202, 32'hC000_02FF, 16'd50001, 16'd49152, 8'd17);
        chk("src-ip differs miss", valid_o, 0);

        // --- key mask: exclude src port (word8 high 16) + src IP (words 4..7) ---
        // so flows differing only in src port / src IP still classify.
        @(negedge clk);
        mask = '1;
        mask[8*32+16 +: 16] = 16'h0000;        // mask out l4_src (word8 [31:16])
        for (int i=4;i<8;i++) mask[i*32 +: 32] = 32'h0; // mask out l3_src
        @(negedge clk);
        kB = mk_v4(32'hC000_0203, 32'h0, 16'd50002, 16'd0, 8'd17) & mask; // src masked off
        prog(kB, 9);
        // lookup with ARBITRARY src ip + src port -> still hits (masked out)
        lookup(32'hC000_0203, 32'hDEAD_BEEF, 16'd50002, 16'hAAAA, 8'd17);
        chk("masked src hit", valid_o, 1);
        chk("masked src lfid", lfid_o, 9);
        // but a different dst port still misses (dst port is kept)
        lookup(32'hC000_0203, 32'hDEAD_BEEF, 16'd59999, 16'hAAAA, 8'd17);
        chk("masked dst-port differs miss", valid_o, 0);

        if (errors == 0) $display("ALL HASH_CLASSIFIER SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
