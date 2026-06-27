// PacketWyrm hash exact-match classifier -- high-count payload-agnostic flows.
//
// Classifies a frame by an EXACT, MASKED match on a WIDE multi-field header key,
// scaling to the checker's NUM_FLOWS without the field classifier's comparator
// cap (and without the test-header flow_id the flow-id map needs -- so the
// payload is free). It is the "exact table" back-end of the generic classifier
// (docs/design/generic-classifier.md), the header-keyed analogue of
// pw_flowid_map.
//
// Key = 11 field-aligned 32-bit words (so HW/SW build them identically, no
// bit-straddling): l3_dst (words 0..3, IPv4 dst in word0), l3_src (4..7),
// {l4_src,l4_dst} (8), {vlan,ethertype} (9), {0,l3_proto} (10).
//
// A GLOBAL key mask (one per card, applied BEFORE hashing) selects which bits
// participate: masked = word & mask. Masking out a field excludes it from the
// key; masking out the bits a generator modifier randomizes lets the flow still
// classify. (The mask must be global -- the lookup masks the frame key to find
// the bucket before it can read any per-entry state.)
//
// Direct-indexed BRAM hash table (1 read + 1 masked-key verify, NOT an N-way
// parallel match, so it routes):
//   k32   = XOR-fold of the 11 masked words
//   index = (k32 * (seed|1))[31:0] >> (32 - IDX_W)   (Dietzfelbinger multiply-
//           shift; the seed changes the collision pattern, so SW can place the
//           configured keys collision-free)
//   mem[index] = {valid, stored_key(11 words), local_flow_id}
//   hit    = valid && stored_key == masked_frame_key   (exact, no misclassify;
//            SW stores the already-masked key, HW masks the frame key)
//
// Latency is 4 clocks measured from the cycle key_i/key_valid_i are presented
// to the cycle valid_o/local_flow_id_o are valid: cycle 0 captures the masked
// key (mkey_q1 = assemble+mask), cycle 1 registers the XOR-fold (k32_q) and
// carries the key (key_q1b), cycle 2 reads the BRAM at the multiply-shifted
// index (rd_q) + holds the key (key_q), cycle 3 verifies + registers the result.
// The two register stages split the dp_clk path
// key->assemble->mask | ->fold | ->multiply->BRAM-address into three short hops
// (fold and multiply no longer share a cone -- that combined cone was the
// dp_clk-critical path). The data plane delays the field classifier + flow-id map
// results so all three classification paths stay aligned (at 4 from key_valid) at
// the precedence mux.

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
    input  wire [31:0]                   seed_i,        // (seed|1) is the multiplier
    input  wire [351:0]                  mask_i,        // global key mask (11 words)

    // Table programming: mem[wr_index] = {wr_valid, wr_key, wr_lfid}. wr_key is
    // the already-masked key; SW computes wr_index with the same hash.
    input  wire                          wr_en,
    input  wire [$clog2(DEPTH)-1:0]      wr_index,
    input  wire                          wr_valid,
    input  wire [351:0]                  wr_key,
    input  wire [$clog2(NUM_FLOWS)-1:0]  wr_lfid,

    output logic                         valid_o,
    output logic [$clog2(NUM_FLOWS)-1:0] local_flow_id_o
);
    localparam int IDX_W = $clog2(DEPTH);
    localparam int LFW   = $clog2(NUM_FLOWS);
    localparam int KW    = 11;                 // key words
    localparam int KB    = KW * 32;            // 352
    localparam int EW    = 1 + KB + LFW;        // {valid, key, lfid}

    // ---- assemble the 11 field-aligned key words from canonical fields ----
    function automatic logic [KB-1:0] assemble(input pw_match_key_t k);
        logic [127:0] l3dst, l3src;
        logic [31:0]  w [KW];
        l3dst = k.is_ipv6 ? k.ipv6_dst : {96'b0, k.ipv4_dst};
        l3src = k.is_ipv6 ? k.ipv6_src : {96'b0, k.ipv4_src};
        w[0]  = l3dst[31:0];   w[1] = l3dst[63:32];  w[2] = l3dst[95:64];  w[3] = l3dst[127:96];
        w[4]  = l3src[31:0];   w[5] = l3src[63:32];  w[6] = l3src[95:64];  w[7] = l3src[127:96];
        w[8]  = {k.l4_src, k.l4_dst};
        w[9]  = {3'b0, k.inner_vlan_valid, k.vlan_id[11:0], k.ethertype};
        w[10] = {24'b0, k.l3_proto};
        return {w[10], w[9], w[8], w[7], w[6], w[5], w[4], w[3], w[2], w[1], w[0]};
    endfunction

    // ---- hash split into two pipelineable halves ----
    // fold: XOR-fold the 11 masked words to 32b (a shallow XOR tree).
    function automatic logic [31:0] fold(input logic [KB-1:0] mkey);
        logic [31:0] k32;
        k32 = 32'b0;
        for (int i = 0; i < KW; i++) k32 ^= mkey[i*32 +: 32];
        return k32;
    endfunction
    // mulshift: Dietzfelbinger multiply-shift to IDX_W bits (the 32x32 DSP).
    function automatic logic [IDX_W-1:0] mulshift(input logic [31:0] k32,
                                                  input logic [31:0] seed);
        logic [31:0] prod;
        prod = k32 * (seed | 32'd1);
        return prod[31 -: IDX_W];
    endfunction

    wire [KB-1:0] mkey_c = assemble(key_i) & mask_i;   // masked frame key (combinational)

    // ---- stage 1: register the masked key (assemble[is_ipv6 mux] + mask land
    // here). RESET-LESS pure data pipeline reg, gated downstream by kv1 (which IS
    // reset), so its reset value is don't-care; init '0 = GSR/power-up only. ----
    logic [KB-1:0] mkey_q1 = '0;
    logic          kv1;
    always_ff @(posedge clk) mkey_q1 <= mkey_c;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) kv1 <= 1'b0; else kv1 <= key_valid_i;
    end

    // ---- stage 1b: register the XOR-fold result (k32_q) on its OWN cycle, and
    // carry the full masked key (key_q1b) + valid (kv1b) alongside. This is the
    // dp_clk timing fix: previously fold+multiply+BRAM-address were one combinational
    // cone (mkey_q1 -> XOR-fold -> 32x32 multiply -> BRAM ADDR) and that was THE
    // dp_clk-critical path (post-route WNS went negative on a full resynth). Splitting
    // the fold off into its own register leaves stage 1b = just the shallow XOR tree
    // and stage 2 = just multiply->BRAM-address, both comfortably short; it also gives
    // the multiply a clean registered A operand (k32_q) so the DSP can pack its input
    // register (clears the DPIR-2 / SYNTH-10 hints). Costs one cycle of latency
    // (3->4); the data plane realigns the field classifier + flow-id map by +1 to
    // match. k32_q / key_q1b are RESET-LESS data pipeline regs (gated by kv1b).
    logic [31:0]   k32_q  = '0;
    logic [KB-1:0] key_q1b = '0;
    logic          kv1b;
    always_ff @(posedge clk) begin k32_q <= fold(mkey_q1); key_q1b <= mkey_q1; end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) kv1b <= 1'b0; else kv1b <= kv1;
    end

    // ---- BRAM table: write port + registered read port (stage 2). The read
    // address is now just the multiply-shift of the registered fold (no fold in
    // this cone), so the path k32_q -> multiply -> BRAM ADDR is short. ----
    (* ram_style = "block" *) logic [EW-1:0] mem [DEPTH];
    initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;

    wire [IDX_W-1:0] rd_index = mulshift(k32_q, seed_i);
    logic [EW-1:0]   rd_q;
    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_index] <= {wr_valid, wr_key, wr_lfid[LFW-1:0]};
        rd_q <= mem[rd_index];
    end

    // ---- stage 2: hold the masked key + valid alongside the BRAM read ----
    logic [KB-1:0] key_q;
    logic          kv_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin key_q <= '0; kv_q <= 1'b0; end
        else        begin key_q <= key_q1b; kv_q <= kv1b; end
    end

    // ---- stage 3: masked-key verify + register result ----
    wire           e_valid = rd_q[EW-1];
    wire [KB-1:0]  e_key   = rd_q[EW-2 -: KB];
    wire [LFW-1:0] e_lfid  = rd_q[LFW-1:0];
    wire           hit_c   = kv_q && e_valid && (e_key == key_q);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin valid_o <= 1'b0; local_flow_id_o <= '0; end
        else begin
            valid_o         <= hit_c;
            local_flow_id_o <= e_lfid;
        end
    end

endmodule

`default_nettype wire
