// Unit testbench: pw_flow_gen_multi -> pw_parser_axis. Two enabled flow
// slots (distinct flow_ids / IPs) share one egress port; confirm the
// parser recovers BOTH flows interleaved, each with a monotonic sequence
// (round-robin scheduling + per-flow sequence counters).
`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_flow_gen_multi;
    localparam int SLOTS = 4;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [63:0] ts = 0;

    pw_flow_row_t f_rows [SLOTS];

    logic [63:0] td; logic [7:0] tk; logic tv, tl;

    pw_flow_gen_multi #(.EGRESS_PORT(0), .NUM_SLOTS(SLOTS), .FRAME_LEN_PAYLOAD(32)) gen (
        .clk(clk), .rst_n(rst_n), .timestamp_i(ts),
        .f_rows_i(f_rows),
        .m_tdata(td), .m_tkeep(tk), .m_tvalid(tv), .m_tready(1'b1), .m_tlast(tl)
    );

    pw_match_key_t key; logic key_valid;
    pw_parser_axis dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(td), .s_tkeep(tk), .s_tvalid(tv), .s_tready(), .s_tlast(tl),
        .ingress_port_i(4'd0), .key_o(key), .key_valid_o(key_valid)
    );

    int  g_pass = 0, g_fail = 0;
    task chk(input string n, input logic c);
        if (c) begin g_pass++; $display("[ ok ] %s", n); end
        else   begin g_fail++; $display("[FAIL] %s", n); end
    endtask

    // Per-flow_id tracking.
    int      seen_a = 0, seen_b = 0;            // flow_id 1, flow_id 3
    logic [63:0] lastseq_a, lastseq_b;
    logic    ok_a = 1, ok_b = 1;

    // Field-modifier tracking for flow_id 1 (dst IP, low 10 bits rotating).
    logic [31:0] dip_first; logic dip_seen0 = 0;
    int      dip_distinct = 0; logic dip_hi_const = 1;
    logic [31:0] dip_prev;

    // Raw-beat capture of the first emitted frame, to validate the IP csum.
    logic [7:0] cap [0:255]; int cap_n = 0; logic cap_done = 0;
    always_ff @(posedge clk) begin
        if (rst_n && tv && !cap_done) begin
            for (int k = 0; k < 8; k++) if (tk[k]) begin
                if (cap_n < 256) cap[cap_n] = td[k*8 +: 8];
                cap_n++;
            end
            if (tl) cap_done <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        ts <= ts + 1;
        if (rst_n && key_valid && key.is_test) begin
            if (key.test_flow_id == 32'd1) begin
                if (seen_a > 0 && key.test_sequence != lastseq_a + 1) ok_a = 0;
                lastseq_a = key.test_sequence; seen_a++;
                // dst IP modifier: low 10 bits should vary, high bits fixed.
                if (!dip_seen0) begin dip_seen0 <= 1; dip_first <= key.ipv4_dst; end
                else begin
                    if (key.ipv4_dst != dip_prev) dip_distinct++;
                    if ((key.ipv4_dst & 32'hFFFFFC00) != (dip_first & 32'hFFFFFC00)) dip_hi_const = 0;
                end
                dip_prev <= key.ipv4_dst;
            end else if (key.test_flow_id == 32'd3) begin
                if (seen_b > 0 && key.test_sequence != lastseq_b + 1) ok_b = 0;
                lastseq_b = key.test_sequence; seen_b++;
            end
        end
    end

    // IPv4 header checksum over captured bytes [14..33] (no VLAN): the 1's
    // complement sum of the 10 header 16-bit words must fold to 0xFFFF.
    function automatic logic ip_csum_ok();
        logic [31:0] s; s = 0;
        for (int w = 0; w < 10; w++)
            s += {cap[14 + w*2], cap[14 + w*2 + 1]};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return (s[15:0] == 16'hFFFF);
    endfunction

    // Capture the first IPv6 frame (ethertype 0x86DD) for UDP-checksum check,
    // and track the IPv6 dst low byte (byte 53) to verify the address modifier.
    logic [7:0] fbuf [0:127]; int fb_n = 0;
    logic [7:0] cap6 [0:127]; int cap6_n = 0; logic cap6_done = 0;
    int v6_seen = 0;
    logic [255:0] v6_dlo_seen = '0; int v6_dlo_distinct = 0; logic v6_dhi_const = 1'b1;
    always_ff @(posedge clk) begin
        if (rst_n && tv) begin
            for (int k = 0; k < 8; k++) if (tk[k]) begin
                if (fb_n < 128) fbuf[fb_n] = td[k*8 +: 8];
                fb_n++;
            end
            if (tl) begin
                if (fb_n >= 54 && fbuf[12] == 8'h86 && fbuf[13] == 8'hDD) begin
                    v6_seen++;
                    if (!cap6_done) begin
                        for (int i = 0; i < 128; i++) cap6[i] = fbuf[i];
                        cap6_n = fb_n; cap6_done <= 1'b1;
                    end
                    // dst addr @38..53; low byte 53 rotates, byte 52 stays fixed
                    if (!v6_dlo_seen[fbuf[53]]) begin
                        v6_dlo_seen[fbuf[53]] = 1'b1; v6_dlo_distinct++;
                    end
                    if (fbuf[52] != 8'h00) v6_dhi_const = 1'b0;   // dst[...:8] fixed
                end
                fb_n = 0;
            end
        end
    end

    // IPv6 UDP *partial* checksum over cap6: pseudo-header (src@22, dst@38,
    // ulen, nh=17) + UDP header (@54, incl csum field) + payload (@62) but
    // EXCLUDING the 8-byte tx_timestamp (bytes 82..89 = payload words 10..13).
    // The generator omits tx_ts from the checksum (pw_ts_insert folds the
    // departure stamp in at egress), so partial + ~partial folds to 0xFFFF.
    function automatic logic udp6_csum_ok();
        logic [31:0] s; logic [15:0] ulen;
        s = 0;
        ulen = {cap6[58], cap6[59]};                 // UDP length
        for (int w = 0; w < 8; w++) s += {cap6[22 + w*2], cap6[22 + w*2 + 1]};  // src
        for (int w = 0; w < 8; w++) s += {cap6[38 + w*2], cap6[38 + w*2 + 1]};  // dst
        s += {16'b0, ulen};                          // upper-layer length
        s += 32'h0000_0011;                          // next-header 17
        for (int w = 0; w < 4; w++) s += {cap6[54 + w*2], cap6[54 + w*2 + 1]};  // UDP hdr (incl csum)
        for (int w = 0; w < 16; w++)                 // 32B payload, minus tx_ts
            if (w < 10 || w > 13) s += {cap6[62 + w*2], cap6[62 + w*2 + 1]};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return (s[15:0] == 16'hFFFF);                // partial + ~partial == 0xFFFF
    endfunction

    initial begin
        for (int s = 0; s < SLOTS; s++) begin
            f_rows[s] = '0;
            f_rows[s].burst   = 16'd128;
            f_rows[s].src_mac = 48'h02_00_00_00_00_01;
            f_rows[s].dst_mac = 48'hFF_FF_FF_FF_FF_FF;
            f_rows[s].src_ipv4 = 32'h0A000001; f_rows[s].dst_ipv4 = 32'h0A000002;
            f_rows[s].udp_sp = 16'd4000; f_rows[s].udp_dp = 16'd4001;
            f_rows[s].ttl = 8'd64;
        end
        // slot 0: flow_id 1, slot 2: flow_id 3 -- both valid, egress 0, same rate.
        f_rows[0].valid=1; f_rows[0].egress=0; f_rows[0].flow_id=32'd1;
        f_rows[0].tokens_fp=32'h00200000; f_rows[0].src_ipv4=32'h0A000001;
        // dst-IP field modifier on flow_id 1: rotate the low 10 bits.
        f_rows[0].dst_ipv4=32'h0A000200; f_rows[0].dip_mod=2'd1; f_rows[0].dip_mask=32'h000003FF;
        f_rows[0].dscp=8'd10;   // IPv4 TOS = 0x28; validated via the header checksum
        // slot 2: IPv6 flow (flow_id 3) -- exercises the IPv6 frame path + UDP csum.
        f_rows[2].valid=1; f_rows[2].egress=0; f_rows[2].flow_id=32'd3;
        f_rows[2].tokens_fp=32'h00200000;
        f_rows[2].is_v6=1'b1;
        f_rows[2].ipv6_src=128'h2001_0db8_0000_0000_0000_0000_0000_0001;
        f_rows[2].ipv6_dst=128'h2001_0db8_0000_0000_0000_0000_0000_0002;
        // IPv6 dst-address modifier: rotate the low 8 bits (host portion).
        f_rows[2].dip_mod=2'd1; f_rows[2].dip_mask=32'h000000FF;
        // DSCP 46 (EF) -> IPv6 traffic class 0xB8 (byte0 0x6B, byte1 0x80).
        f_rows[2].dscp=8'd46;

        repeat (4) @(posedge clk); rst_n = 1;
        repeat (3000) @(posedge clk);

        chk("flow_id 1 seen (>=20)", seen_a >= 20);
        chk("flow_id 3 seen (>=20)", seen_b >= 20);
        chk("flow_id 1 sequence monotonic", ok_a);
        chk("flow_id 3 sequence monotonic", ok_b);
        // round-robin fairness: counts within 2x of each other
        chk("both flows roughly balanced",
            (seen_a <= 2*seen_b + 4) && (seen_b <= 2*seen_a + 4));
        // field modifier: dst IP low bits rotate, high bits fixed, csum valid
        chk("dst-ip modifier rotates", dip_distinct >= 4);
        chk("dst-ip modifier keeps high bits", dip_hi_const);
        chk("captured first frame", cap_done && cap_n >= 34);
        chk("IPv4 header checksum valid", ip_csum_ok());
        chk("IPv4 TOS = DSCP<<2", cap[15] == 8'h28);   // dscp 10 -> 0x28
        chk("IPv4 TTL emitted (64)", cap[22] == 8'd64);
        // IPv6 flow (flow_id 3 / slot 2): frames emitted as IPv6 + valid UDP csum.
        chk("IPv6 frames emitted", v6_seen >= 4);
        chk("captured IPv6 frame (94B)", cap6_done && cap6_n == 94);
        chk("IPv6 UDP checksum valid", udp6_csum_ok());
        // IPv4/IPv6 parity: IPv6 traffic class + hop limit + address modifier.
        chk("IPv6 traffic class = DSCP<<2", cap6[14] == 8'h6B && cap6[15] == 8'h80);
        chk("IPv6 hop limit emitted (64)", cap6[21] == 8'd64);
        chk("IPv6 dst-addr modifier rotates", v6_dlo_distinct >= 4);
        chk("IPv6 dst-addr modifier keeps high bits", v6_dhi_const);
        $display("flow_gen_multi: fid1=%0d fid3=%0d (%0d pass, %0d fail)", seen_a, seen_b, g_pass, g_fail);
        if (g_fail == 0) $display("ALL FLOW_GEN_MULTI SCENARIOS PASS");
        else $display("FAILED with %0d error(s)", g_fail);
        $finish;
    end

    initial begin #400000; $display("WATCHDOG TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
