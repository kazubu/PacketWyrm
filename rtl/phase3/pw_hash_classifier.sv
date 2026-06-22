// PacketWyrm hash exact-match classifier -- high-count payload-agnostic flows.
//
// Classifies a frame by an EXACT match on a multi-field HEADER key, scaling to
// the checker's NUM_FLOWS without the field classifier's comparator-count cap
// (and without the test-header flow_id the flow-id map needs -- so the payload
// is free). It is the "exact table" back-end of the generic classifier
// (docs/design/generic-classifier.md), the header-keyed analogue of
// pw_flowid_map.
//
// Direct-indexed hash table (1 read + 1 compare -- NOT an N-way parallel match,
// so it routes):
//   key K  = {l3_dst[127:0], l4_dst[15:0], l4_src[15:0], l3_proto[7:0]} (168b)
//            assembled from the parser's canonical fields; l3_dst is the IPv6
//            dst, or the IPv4 dst in its low 32 bits.
//   k32    = XOR-fold of K (the 6 32-bit words, K zero-padded to 192b)
//   index  = (k32 * (seed|1))[31:0] >> (32 - IDX_W)   (Dietzfelbinger
//            multiply-shift; the seed changes the collision pattern, so SW can
//            search for a collision-free placement of the configured keys)
//   mem[index] = {valid, stored_key(168b), local_flow_id}
//   hit    = valid && stored_key == K        (FULL-key verify -> exact, no
//            misclassification; the hash only chooses the bucket)
//
// SW computes the identical hash to place entries (mem[index] written by index),
// detecting/avoiding collisions via the seed. Latency key_valid_i -> valid_o is
// 2 cycles (BRAM read + result register), matching pw_classifier / the field
// classifier so the data plane reuses the same key delay.

`default_nettype none

import pw_classifier_pkg::*;

module pw_hash_classifier #(
    parameter int NUM_FLOWS = 32,
    parameter int DEPTH     = 128
) (
    input  wire                          clk,
    input  wire                          rst_n,

    input  pw_match_key_t                key_i,
    input  wire                          key_valid_i,
    input  wire [31:0]                   seed_i,        // CSR; (seed|1) is the multiplier

    // Table programming: mem[wr_index] = {wr_valid, wr_key, wr_lfid}. SW computes
    // wr_index with the same hash (over wr_key) it expects the frame to produce.
    input  wire                          wr_en,
    input  wire [$clog2(DEPTH)-1:0]      wr_index,
    input  wire                          wr_valid,
    input  wire [167:0]                  wr_key,
    input  wire [$clog2(NUM_FLOWS)-1:0]  wr_lfid,

    output logic                         valid_o,
    output logic [$clog2(NUM_FLOWS)-1:0] local_flow_id_o
);
    localparam int IDX_W = $clog2(DEPTH);
    localparam int LFW   = $clog2(NUM_FLOWS);
    localparam int KW    = 168;
    localparam int EW    = 1 + KW + LFW;            // {valid, key, lfid}

    // ---- assemble the 168-bit key from canonical fields ----
    function automatic logic [KW-1:0] assemble(input pw_match_key_t k);
        logic [127:0] l3dst;
        l3dst = k.is_ipv6 ? k.ipv6_dst : {96'b0, k.ipv4_dst};
        return {l3dst, k.l4_dst, k.l4_src, k.l3_proto};
    endfunction

    // ---- hash: XOR-fold to 32b, multiply-shift to IDX_W ----
    function automatic logic [31:0] fold32(input logic [KW-1:0] key);
        logic [191:0] kp;
        kp = {24'b0, key};                          // pad to 6 x 32
        return kp[31:0] ^ kp[63:32] ^ kp[95:64] ^ kp[127:96] ^ kp[159:128] ^ kp[191:160];
    endfunction
    function automatic logic [IDX_W-1:0] hash_index(input logic [KW-1:0] key,
                                                    input logic [31:0] seed);
        logic [31:0] k32, prod;
        k32  = fold32(key);
        prod = k32 * (seed | 32'd1);                // low 32 of the product
        return prod[31 -: IDX_W];                   // top IDX_W bits of the low 32
    endfunction

    // ---- BRAM table (inferred): write port + registered read port ----
    (* ram_style = "block" *) logic [EW-1:0] mem [DEPTH];
    initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;

    wire [IDX_W-1:0] rd_index = hash_index(assemble(key_i), seed_i);
    logic [EW-1:0]   rd_q;
    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_index] <= {wr_valid, wr_key, wr_lfid[LFW-1:0]};
        rd_q <= mem[rd_index];
    end

    // ---- stage 1: hold the computed key + valid alongside the BRAM read ----
    logic [KW-1:0] key_q;
    logic          kv_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin key_q <= '0; kv_q <= 1'b0; end
        else        begin key_q <= assemble(key_i); kv_q <= key_valid_i; end
    end

    // ---- stage 2: verify (full-key exact) + register result ----
    wire              e_valid =  rd_q[EW-1];
    wire [KW-1:0]     e_key   =  rd_q[EW-2 -: KW];
    wire [LFW-1:0]    e_lfid  =  rd_q[LFW-1:0];
    wire              hit_c   =  kv_q && e_valid && (e_key == key_q);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin valid_o <= 1'b0; local_flow_id_o <= '0; end
        else begin
            valid_o         <= hit_c;
            local_flow_id_o <= e_lfid;
        end
    end

endmodule

`default_nettype wire
