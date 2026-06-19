// PacketWyrm flow table CSR window.
//
// Decodes the byte-oriented pw_csr_window output (matching the host
// wire struct `pwfpga_flow_config` in csr.h) into the per-port
// generator inputs `pw_data_plane` exposes (one `pw_flow_gen` per
// egress port).
//
// Selection policy when multiple rows target the same egress port:
// the lowest-indexed *enabled* row wins. This is intentional and
// matches the host compiler today, which emits one TX row per
// global_flow_id and binds it to a single egress port.
//
// Wire layout per row (matches packed C struct in csr.h):
//   off  size  field
//     0    1   enable
//     1    1   egress_local_port
//     2    4   global_flow_id
//     6    4   local_flow_id
//    10    4   logical_if_id
//    14    6   dst_mac[6]
//    20    6   src_mac[6]
//    26    1   vlan_enable
//    27    2   vlan_id
//    29    1   pcp
//    30    1   ip_version
//    31    4   src_ipv4
//    35    4   dst_ipv4
//    39    1   dscp
//    40    1   ttl
//    41    2   udp_src_port
//    43    2   udp_dst_port
//    45    2   frame_len_min
//    47    2   frame_len_max
//    49    2   frame_len_step
//    51    8   rate_bps
//    59    8   rate_pps
//    67    4   burst_size
//    71    4   burst_gap_ticks
//    75    4   tokens_per_tick_fp     (Q16.16 bytes/cycle)
//    79    2   burst_bytes
//    81    2   reserved0
//    83    1   payload_mode    84  4  payload_seed
//    88    1   insert_sequence 89  1  insert_timestamp
//    90    1   tx_enable       91  1  rx_check_enable
//    -- field modifiers (mode in low 2 bits; mask selects rotated bits) --
//    92    1   src_ipv4_mod    93  4  src_ipv4_mask
//    97    1   dst_ipv4_mod    98  4  dst_ipv4_mask
//   102    1   udp_src_mod    103  2  udp_src_mask
//   105    1   udp_dst_mod    106  2  udp_dst_mask

`default_nettype none

import pw_axis_pkg::*;

module pw_flow_window #(
    parameter int                ADDR_W        = 16,
    parameter int                PORTS         = 2,
    parameter int                DEPTH         = 8,
    parameter logic [15:0]       WIN_BASE      = 16'h2000,
    parameter logic [15:0]       COMMIT_OFFSET = 16'h0FFC
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [31:0]           wr_data,

    // Full decoded flow table (one entry per row) for the multi-flow
    // generator, which round-robins all rows whose egress matches its port.
    // Registered (see flow_rows_c below): the 256-byte rows fan out widely
    // into the generators, so the decode terminates at a register instead of
    // feeding combinationally into build(); a commit takes effect one cycle
    // later (harmless -- the table is otherwise static).
    output pw_flow_row_t                  flow_rows_o [DEPTH],

    output logic                          commit_pulse_o
);

    localparam int ROW_BYTES = 256;   // 256 (was 128): IPv6 addresses (bytes 108..139)

    logic [DEPTH-1:0][ROW_BYTES*8-1:0] live_rows;

    pw_csr_window #(
        .ADDR_W        (ADDR_W),
        .DEPTH         (DEPTH),
        .ROW_BYTES     (ROW_BYTES),
        .WIN_BASE      (WIN_BASE[ADDR_W-1:0]),
        .COMMIT_OFFSET (COMMIT_OFFSET[ADDR_W-1:0])
    ) u_win (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .live_rows_o    (live_rows),
        .commit_pulse_o (commit_pulse_o)
    );

    // Per-row decoded fields.
    logic [7:0]                 row_egress     [DEPTH];
    logic [47:0]                row_src_mac    [DEPTH];
    logic [47:0]                row_dst_mac    [DEPTH];
    logic                       row_vlan_en    [DEPTH];
    logic [11:0]                row_vlan_id    [DEPTH];
    logic [31:0]                row_src_ip     [DEPTH];
    logic [31:0]                row_dst_ip     [DEPTH];
    logic [15:0]                row_udp_sp     [DEPTH];
    logic [15:0]                row_udp_dp     [DEPTH];
    logic [31:0]                row_tokens_fp  [DEPTH];
    logic [15:0]                row_burst      [DEPTH];

    // Combinational decode; registered into flow_rows_o below.
    pw_flow_row_t               flow_rows_c    [DEPTH];

    always_comb begin
        for (int r = 0; r < DEPTH; r++) begin
            logic [ROW_BYTES*8-1:0] row;
            row = live_rows[r];

            row_egress[r]    = row[1*8 +: 8];

            row_dst_mac[r]   = {row[14*8 +: 8], row[15*8 +: 8], row[16*8 +: 8],
                                row[17*8 +: 8], row[18*8 +: 8], row[19*8 +: 8]};
            row_src_mac[r]   = {row[20*8 +: 8], row[21*8 +: 8], row[22*8 +: 8],
                                row[23*8 +: 8], row[24*8 +: 8], row[25*8 +: 8]};

            row_vlan_en[r]   = row[26*8 +: 8];  // truncates to bit 0
            row_vlan_id[r]   = {row[28*8 +: 8], row[27*8 +: 8]};  // truncates to 12b

            row_src_ip[r]    = {row[34*8 +: 8], row[33*8 +: 8],
                                row[32*8 +: 8], row[31*8 +: 8]};
            row_dst_ip[r]    = {row[38*8 +: 8], row[37*8 +: 8],
                                row[36*8 +: 8], row[35*8 +: 8]};

            row_udp_sp[r]    = {row[42*8 +: 8], row[41*8 +: 8]};
            row_udp_dp[r]    = {row[44*8 +: 8], row[43*8 +: 8]};

            row_tokens_fp[r] = {row[78*8 +: 8], row[77*8 +: 8],
                                row[76*8 +: 8], row[75*8 +: 8]};
            row_burst[r]     = {row[80*8 +: 8], row[79*8 +: 8]};

            // Full row descriptor for the multi-flow generator. flow_id is
            // the wire global_flow_id at byte offset 2 (LE u32).
            flow_rows_c[r].valid     = row[0*8 +: 8] & row[90*8 +: 8];  // enable && tx_enable (bit 0)
            flow_rows_c[r].egress    = row_egress[r][3:0];
            flow_rows_c[r].flow_id   = {row[5*8 +: 8], row[4*8 +: 8],
                                        row[3*8 +: 8], row[2*8 +: 8]};
            flow_rows_c[r].tokens_fp = row_tokens_fp[r];
            flow_rows_c[r].burst     = row_burst[r];
            flow_rows_c[r].src_mac   = row_src_mac[r];
            flow_rows_c[r].dst_mac   = row_dst_mac[r];
            flow_rows_c[r].vlan_en   = row_vlan_en[r];
            flow_rows_c[r].vlan_id   = row_vlan_id[r];
            flow_rows_c[r].src_ipv4  = row_src_ip[r];
            flow_rows_c[r].dst_ipv4  = row_dst_ip[r];
            flow_rows_c[r].udp_sp    = row_udp_sp[r];
            flow_rows_c[r].udp_dp    = row_udp_dp[r];
            flow_rows_c[r].dscp      = row[39*8 +: 8];   // IPv4 TOS / IPv6 TC
            flow_rows_c[r].ttl       = row[40*8 +: 8];   // IPv4 TTL / IPv6 hop limit

            // Per-field modifiers (wire bytes 92+, just past the packed C
            // struct's rx_check_enable @91). mode in low 2 bits.
            flow_rows_c[r].sip_mod   = row[92*8 +: 2];
            flow_rows_c[r].sip_mask  = {row[96*8 +: 8], row[95*8 +: 8],
                                        row[94*8 +: 8], row[93*8 +: 8]};
            flow_rows_c[r].dip_mod   = row[97*8 +: 2];
            flow_rows_c[r].dip_mask  = {row[101*8 +: 8], row[100*8 +: 8],
                                        row[99*8 +: 8], row[98*8 +: 8]};
            flow_rows_c[r].sp_mod    = row[102*8 +: 2];
            flow_rows_c[r].sp_mask   = {row[104*8 +: 8], row[103*8 +: 8]};
            flow_rows_c[r].dp_mod    = row[105*8 +: 2];
            flow_rows_c[r].dp_mask   = {row[107*8 +: 8], row[106*8 +: 8]};

            // MAC / VLAN modifiers (bytes 140..156). MAC masks are MSB-first
            // (byte 141 = bits 47..40), matching the src/dst MAC byte order.
            flow_rows_c[r].smac_mod  = row[140*8 +: 2];
            flow_rows_c[r].smac_mask = {row[141*8 +: 8], row[142*8 +: 8], row[143*8 +: 8],
                                        row[144*8 +: 8], row[145*8 +: 8], row[146*8 +: 8]};
            flow_rows_c[r].dmac_mod  = row[147*8 +: 2];
            flow_rows_c[r].dmac_mask = {row[148*8 +: 8], row[149*8 +: 8], row[150*8 +: 8],
                                        row[151*8 +: 8], row[152*8 +: 8], row[153*8 +: 8]};
            flow_rows_c[r].vlan_mod  = row[154*8 +: 2];
            flow_rows_c[r].vlan_mask = {row[156*8 +: 8], row[155*8 +: 8]};

            // IPv6: ip_version (byte 30) == 6 -> emit an IPv6 frame using the
            // 16-byte addresses at bytes 108..139 (network order, byte 108 = MSB).
            flow_rows_c[r].is_v6     = (row[30*8 +: 8] == 8'd6);
            flow_rows_c[r].ipv6_src  = '0;
            flow_rows_c[r].ipv6_dst  = '0;
            for (int b = 0; b < 16; b++) begin
                flow_rows_c[r].ipv6_src[127 - b*8 -: 8] = row[(108+b)*8 +: 8];
                flow_rows_c[r].ipv6_dst[127 - b*8 -: 8] = row[(124+b)*8 +: 8];
            end

            // Encapsulation (wire bytes 157..201): outer L3 + tunnel header.
            // encap_type @157, outer_ip_version @158 (0/4/6), rx_expect @159,
            // outer_ttl @160, outer_dscp @161, outer_src/dst_ipv4 (LE u32) @162/166,
            // outer_ipv6_src/dst (16B, byte 170/186 = MSB) @170/186.
            flow_rows_c[r].encap_type = row[157*8 +: 2];
            flow_rows_c[r].outer_v6   = (row[158*8 +: 8] == 8'd6);
            flow_rows_c[r].rx_tunneled = row[159*8 +: 1];
            flow_rows_c[r].outer_ttl  = row[160*8 +: 8];
            flow_rows_c[r].outer_dscp = row[161*8 +: 8];
            flow_rows_c[r].outer_src_ipv4 = {row[165*8 +: 8], row[164*8 +: 8],
                                             row[163*8 +: 8], row[162*8 +: 8]};
            flow_rows_c[r].outer_dst_ipv4 = {row[169*8 +: 8], row[168*8 +: 8],
                                             row[167*8 +: 8], row[166*8 +: 8]};
            flow_rows_c[r].outer_ipv6_src = '0;
            flow_rows_c[r].outer_ipv6_dst = '0;
            for (int b = 0; b < 16; b++) begin
                flow_rows_c[r].outer_ipv6_src[127 - b*8 -: 8] = row[(170+b)*8 +: 8];
                flow_rows_c[r].outer_ipv6_dst[127 - b*8 -: 8] = row[(186+b)*8 +: 8];
            end
            // EtherIP inner-Ethernet MAC: dst @202..207, src @208..213 (MSB-first).
            flow_rows_c[r].inner_dst_mac = {row[202*8 +: 8], row[203*8 +: 8], row[204*8 +: 8],
                                            row[205*8 +: 8], row[206*8 +: 8], row[207*8 +: 8]};
            flow_rows_c[r].inner_src_mac = {row[208*8 +: 8], row[209*8 +: 8], row[210*8 +: 8],
                                            row[211*8 +: 8], row[212*8 +: 8], row[213*8 +: 8]};
        end
    end

    // Register the decoded rows: breaks the wide live_rows -> decode ->
    // generator build() combinational path (the dominant fan-out once rows
    // are 256 B). The table is static except on commit, so the extra cycle of
    // latency only delays a freshly committed table by one clock.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            for (int r = 0; r < DEPTH; r++) flow_rows_o[r] <= '0;
        else
            for (int r = 0; r < DEPTH; r++) flow_rows_o[r] <= flow_rows_c[r];
    end

    // (The legacy per-port single-flow selection outputs gen_*_o were removed:
    // the multi-flow generator consumes flow_rows_o directly, so that 32:1
    // priority mux over every field was dead logic in the data plane.)

endmodule

`default_nettype wire
