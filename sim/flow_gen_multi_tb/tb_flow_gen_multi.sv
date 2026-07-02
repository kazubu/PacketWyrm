// Unit testbench: pw_flow_gen_multi -> pw_parser_axis. Two enabled flow
// slots (distinct flow_ids / IPs) share one egress port; confirm the
// parser recovers BOTH flows interleaved, each with a monotonic sequence
// (round-robin scheduling + per-flow sequence counters).
`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module tb_flow_gen_multi;
    localparam int SLOTS = 5;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [63:0] ts = 0;

    pw_flow_row_t f_rows [SLOTS];

    logic [63:0] td; logic [7:0] tk; logic tv, tl, tstamp;

    // Model the BRAM-backed flow table: compact scheduling array (comb) + a
    // 1-cycle registered row read on the generator's rd_addr_o.
    pw_flow_sched_t f_sched [SLOTS];
    always_comb for (int s = 0; s < SLOTS; s++) begin
        automatic int test_pl = (f_rows[s].frame_template == 2'd0) ? 32 : 0;
        automatic int minl    = pw_frame_bytes(f_rows[s], test_pl);
        automatic int cfgm    = int'(f_rows[s].frame_len_min);
        f_sched[s] = '0;
        f_sched[s].valid     = f_rows[s].valid;
        f_sched[s].egress    = f_rows[s].egress;
        f_sched[s].tokens_fp = f_rows[s].tokens_fp;
        f_sched[s].cap       = {f_rows[s].burst, 16'h0};
        // Mirror pw_flow_table_bram: cost meters by max(frame_len_min, min_legal),
        // and min_legal is template-aware (raw templates have no 32B test region).
        f_sched[s].cost      = {16'((cfgm > minl) ? cfgm : minl), 16'h0};
        f_sched[s].len_min   = f_rows[s].frame_len_min;
        f_sched[s].len_max   = f_rows[s].frame_len_max;
        f_sched[s].len_step  = f_rows[s].frame_len_step;
        f_sched[s].ovh       = 12'(pw_frame_bytes(f_rows[s], 0));
        f_sched[s].frame_template = f_rows[s].frame_template;
    end
    logic [$clog2(SLOTS)-1:0] rd_addr;
    pw_flow_row_t             rd_row;
    logic [47:0]              gtxc [SLOTS];
    always_ff @(posedge clk) rd_row <= f_rows[rd_addr];

    pw_flow_gen_multi #(.EGRESS_PORT(0), .NUM_SLOTS(SLOTS), .FRAME_LEN_PAYLOAD(32)) gen (
        .clk(clk), .rst_n(rst_n), .timestamp_i(ts),
        .flow_sched_i(f_sched), .rd_addr_o(rd_addr), .rd_row_i(rd_row),
        .stats_clear_i(1'b0), .tx_count_o(gtxc),
        .m_tdata(td), .m_tkeep(tk), .m_tvalid(tv), .m_tready(1'b1), .m_tlast(tl),
        .m_tstampable(tstamp)
    );

    pw_match_key_t key; logic key_valid;
    pw_parser_axis dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(td), .s_tkeep(tk), .s_tvalid(tv), .s_tready(), .s_tlast(tl),
        .ingress_port_i(4'd0), .rx_wire_ts_i(64'd0),
        .key_o(key), .key_valid_o(key_valid), .rx_wire_ts_o(), .window_o(), .base_o()
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
    logic [7:0] capt [0:127]; int capt_n = 0; logic capt_done = 0; int tcp_seen = 0;
    int v6_seen = 0;
    logic [255:0] v6_dlo_seen = '0; int v6_dlo_distinct = 0; logic v6_dhi_const = 1'b1;
    // MAC modifier (IPv4 frames): src MAC low byte @11 rotates, byte @10 fixed.
    logic [255:0] smac_lo_seen = '0; int smac_lo_distinct = 0; logic smac_hi_const = 1'b1;
    // VLAN modifier (VLAN-tagged frames): VID low byte @15 rotates.
    logic [255:0] vid_lo_seen = '0; int vid_lo_distinct = 0;
    // Variable-length flow (flow_id 7): count frames at each swept length, and
    // confirm the IPv4 total_len field + header checksum track the real length.
    int len7_128 = 0, len7_192 = 0, len7_256 = 0, len7_other = 0;
    logic len7_totlen_ok = 1'b1, len7_csum_ok = 1'b1;
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
                // IPv4 TCP frame (proto byte @23 == 6): capture the first one.
                if (fb_n >= 54 && fbuf[12] == 8'h08 && fbuf[13] == 8'h00 && fbuf[23] == 8'd6) begin
                    tcp_seen++;
                    if (!capt_done) begin
                        for (int i = 0; i < 128; i++) capt[i] = fbuf[i];
                        capt_n = fb_n; capt_done <= 1'b1;
                    end
                end
                // IPv4 (untagged) frame: track src MAC modifier (bytes 6..11)
                if (fb_n >= 34 && fbuf[12] == 8'h08 && fbuf[13] == 8'h00) begin
                    if (!smac_lo_seen[fbuf[11]]) begin
                        smac_lo_seen[fbuf[11]] = 1'b1; smac_lo_distinct++;
                    end
                    if (fbuf[10] != 8'h00) smac_hi_const = 1'b0;  // src_mac[...:8] fixed
                end
                // VLAN-tagged frame: track VLAN-ID modifier (TCI low byte @15)
                if (fb_n >= 18 && fbuf[12] == 8'h81 && fbuf[13] == 8'h00) begin
                    if (!vid_lo_seen[fbuf[15]]) begin
                        vid_lo_seen[fbuf[15]] = 1'b1; vid_lo_distinct++;
                    end
                end
                // Variable-length flow_id 7 (IPv4 untagged): test-header flow_id
                // is at byte 50 (eth14+ip20+udp8=42, magic@42, flow_id@50).
                if (fbuf[12] == 8'h08 && fbuf[13] == 8'h00 &&
                    fbuf[50] == 8'd0 && fbuf[51] == 8'd0 && fbuf[52] == 8'd0 && fbuf[53] == 8'd7) begin
                    case (fb_n)
                        128:     len7_128++;
                        192:     len7_192++;
                        256:     len7_256++;
                        default: len7_other++;
                    endcase
                    if ({fbuf[16], fbuf[17]} != 16'(fb_n - 14)) len7_totlen_ok = 1'b0;
                    begin  // IPv4 header checksum over fbuf[14..33] must fold to 0xFFFF
                        automatic logic [31:0] cs = 0;
                        for (int w = 0; w < 10; w++) cs += {fbuf[14 + w*2], fbuf[14 + w*2 + 1]};
                        cs = (cs & 32'hFFFF) + (cs >> 16);
                        cs = (cs & 32'hFFFF) + (cs >> 16);
                        if (cs[15:0] != 16'hFFFF) len7_csum_ok = 1'b0;
                    end
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

    // Exact-rate measurement (final scenario): SOF-to-SOF cycle interval for a
    // single low-rate flow. tv rises at each frame start (it drops in the gap
    // between frames at low rate), so a tv rising edge marks an SOF.
    logic       tv_prev = 1'b0;
    logic       rate_phase = 1'b0;
    int         rate_cyc = 0, last_sof = -1, n_gaps = 0;
    int         gaps [0:7];
    always_ff @(posedge clk) begin
        if (!rate_phase) begin
            tv_prev <= 1'b0;
        end else begin
            rate_cyc <= rate_cyc + 1;
            if (tv && !tv_prev) begin                 // SOF
                if (last_sof >= 0 && n_gaps < 8) begin
                    gaps[n_gaps] <= rate_cyc - last_sof;
                    n_gaps <= n_gaps + 1;
                end
                last_sof <= rate_cyc;
            end
            tv_prev <= tv;
        end
    end

    // Back-to-back measurement (cap=1 line-rate scenario): min SOF-to-SOF gap for
    // a single high-rate flow with a 1-frame bucket. With the active-slot pipeline
    // priming, this is (emit beats + ~1) cycles -- NOT emit + ~5 (the old drain
    // bubble). tready is always 1 here, so the gap is the generator's own limit.
    logic br_phase = 1'b0, btv_prev = 1'b0, br_armed = 1'b0;
    int   br_cyc = 0, br_last = -1, br_min = 9999, br_max = 0, br_sum = 0, br_n = 0;
    always_ff @(posedge clk) begin
        if (br_phase) begin
            br_cyc <= br_cyc + 1;
            if (!tv) br_armed <= 1'b1;   // align to a real frame boundary first
            if (br_armed && tv && !btv_prev) begin
                if (br_last >= 0) begin
                    automatic int g = br_cyc - br_last;
                    if (g < br_min) br_min <= g;
                    if (g > br_max) br_max <= g;
                    br_sum <= br_sum + g;
                    br_n <= br_n + 1;
                end
                br_last <= br_cyc;
            end
            btv_prev <= tv;
        end
    end

    // --- raw frame-template capture (final scenario) --------------------------
    // During raw_phase, accumulate each frame and file the first of each template
    // by a discriminator: L2RAW by ethertype 0x88B5, L3RAW/L4RAW by src IP byte
    // (0x11 vs 0x22), TEST by the magic. Also latch m_tstampable at each SOF.
    logic raw_phase = 1'b0;
    logic [7:0] rbuf [0:127]; int rb_n = 0; logic rb_ts;
    logic [7:0] l2f [0:127]; int l2f_n = 0; logic l2f_done = 0; logic l2f_ts = 1;
    logic [7:0] l3f [0:127]; int l3f_n = 0; logic l3f_done = 0; logic l3f_ts = 1;
    logic [7:0] l4f [0:127]; int l4f_n = 0; logic l4f_done = 0; logic l4f_ts = 1;
    logic [7:0] tsf [0:127]; int tsf_n = 0; logic tsf_done = 0; logic tsf_ts = 0;
    always_ff @(posedge clk) begin
        if (rst_n && raw_phase && tv) begin
            if (rb_n == 0) rb_ts <= tstamp;              // SOF marker sample
            for (int k = 0; k < 8; k++) if (tk[k]) begin
                if (rb_n < 128) rbuf[rb_n] = td[k*8 +: 8];
                rb_n++;
            end
            if (tl) begin
                // L2RAW: ethertype 0x88B5
                if (rbuf[12]==8'h88 && rbuf[13]==8'hB5 && !l2f_done) begin
                    for (int i=0;i<128;i++) l2f[i]=rbuf[i];
                    l2f_n=rb_n; l2f_done<=1'b1; l2f_ts<=rb_ts;
                end
                // IPv4 (0x0800) frames: L3RAW (src IP ..11) vs L4RAW (src IP ..22)
                // vs TEST (magic @42). src IP byte @29.
                if (rbuf[12]==8'h08 && rbuf[13]==8'h00) begin
                    if (rbuf[29]==8'h11 && !l3f_done) begin
                        for (int i=0;i<128;i++) l3f[i]=rbuf[i];
                        l3f_n=rb_n; l3f_done<=1'b1; l3f_ts<=rb_ts;
                    end
                    if (rbuf[29]==8'h22 && !l4f_done) begin
                        for (int i=0;i<128;i++) l4f[i]=rbuf[i];
                        l4f_n=rb_n; l4f_done<=1'b1; l4f_ts<=rb_ts;
                    end
                    if (rbuf[42]==8'hA5 && rbuf[43]==8'h02 && rbuf[44]==8'h7E && rbuf[45]==8'h57
                        && !tsf_done) begin
                        for (int i=0;i<128;i++) tsf[i]=rbuf[i];
                        tsf_n=rb_n; tsf_done<=1'b1; tsf_ts<=rb_ts;
                    end
                end
                rb_n = 0;
            end
        end
    end

    // IPv4 header checksum over an arbitrary captured buffer [14..33].
    function automatic logic ipcsum_ok(input logic [7:0] b [0:127]);
        logic [31:0] s; s = 0;
        for (int w = 0; w < 10; w++) s += {b[14 + w*2], b[14 + w*2 + 1]};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return (s[15:0] == 16'hFFFF);
    endfunction

    // INDEPENDENT IPv4 TCP checksum reference (different arithmetic than the DUT's
    // l4_psum_*): pseudo-header (sip@26, dip@30, proto 6, tcp_len) + the 20-byte
    // TCP header @34 (incl the emitted csum field @50) + the test region @54,
    // EXCLUDING the 8-byte tx_ts. Folds to 0xFFFF iff the emitted partial csum is
    // correct (the stamper would later fold tx_ts at egress). No-encap layout.
    function automatic logic tcp_csum_ok();
        logic [31:0] s; logic [15:0] tcp_len; int test_off;
        s = 0;
        tcp_len = {capt[16], capt[17]} - 16'd20;     // IPv4 total_len - IP hdr
        for (int w = 0; w < 2; w++) s += {capt[26 + w*2], capt[26 + w*2 + 1]};  // sip
        for (int w = 0; w < 2; w++) s += {capt[30 + w*2], capt[30 + w*2 + 1]};  // dip
        s += 32'h0000_0006;                          // pseudo: proto = TCP
        s += {16'b0, tcp_len};                       // pseudo: TCP segment length
        for (int w = 0; w < 10; w++) s += {capt[34 + w*2], capt[34 + w*2 + 1]};  // TCP hdr (incl csum)
        test_off = 54;                               // test region (no encap)
        for (int w = 0; w < 16; w++)                 // 32B test region, minus tx_ts words 10..13
            if (w < 10 || w > 13) s += {capt[test_off + w*2], capt[test_off + w*2 + 1]};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        return (s[15:0] == 16'hFFFF);
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
        // src-MAC modifier: rotate the low byte (src_mac base ...:00:01, byte 10 = 0x00).
        f_rows[0].smac_mod=2'd1; f_rows[0].smac_mask=48'h0000_0000_00FF;
        // slot 1: VLAN-tagged IPv4 flow (flow_id 5) with a VLAN-ID modifier.
        f_rows[1].valid=1; f_rows[1].egress=0; f_rows[1].flow_id=32'd5;
        f_rows[1].tokens_fp=32'h00200000;
        f_rows[1].vlan_en=1'b1; f_rows[1].vlan_id=12'h064;
        f_rows[1].vlan_mod=2'd1; f_rows[1].vlan_mask=16'h00FF;
        // slot 2: IPv6 flow (flow_id 3) -- exercises the IPv6 frame path + UDP csum.
        f_rows[2].valid=1; f_rows[2].egress=0; f_rows[2].flow_id=32'd3;
        f_rows[2].tokens_fp=32'h00200000;
        f_rows[2].is_v6=1'b1;
        f_rows[2].ipv6_src=128'h2001_0db8_0000_0000_0000_0000_0000_0001;
        f_rows[2].ipv6_dst=128'h2001_0db8_0000_0000_0000_0000_0000_0002;
        // IPv6 src+dst modifiers: FULL 128-bit RANDOM rotation. Each 32-bit lane
        // is scrambled with a distinct lane salt, and src/dst use distinct field
        // salts (SALT_SIP=0, SALT_DIP!=0) -- so the four lanes differ AND src !=
        // dst even with the same mask. Exercises mod128 + the field/lane salts.
        f_rows[2].sip_mod=2'd2; f_rows[2].sip_mask=32'hFFFFFFFF; f_rows[2].sip_mask_hi={96{1'b1}};
        f_rows[2].dip_mod=2'd2; f_rows[2].dip_mask=32'hFFFFFFFF; f_rows[2].dip_mask_hi={96{1'b1}};
        // DSCP 46 (EF) -> IPv6 traffic class 0xB8 (byte0 0x6B, byte1 0x80).
        f_rows[2].dscp=8'd46;
        // slot 3: variable frame length sweep (flow_id 7) -- 128 -> 256 by 64,
        // i.e. lengths {128,192,256} repeating. Exercises the frame-length
        // generator (payload pad + length-field/checksum tracking).
        f_rows[3].valid=1; f_rows[3].egress=0; f_rows[3].flow_id=32'd7;
        f_rows[3].tokens_fp=32'h00200000;
        f_rows[3].src_ipv4=32'h0A000007; f_rows[3].dst_ipv4=32'h0A000008;
        f_rows[3].frame_len_min=16'd128; f_rows[3].frame_len_max=16'd256;
        f_rows[3].frame_len_step=16'd64;
        // slot 4: IPv4 TCP flow (flow_id 9) -- stateless SYN segment generation.
        // Low rate so it doesn't starve the metered flows above; just enough to
        // capture one frame + verify the TCP header layout + L4 checksum.
        f_rows[4].valid=1; f_rows[4].egress=0; f_rows[4].flow_id=32'd9;
        f_rows[4].tokens_fp=32'h00080000;
        f_rows[4].src_ipv4=32'h0A000009; f_rows[4].dst_ipv4=32'h0A00000A;
        f_rows[4].udp_sp=16'd40000; f_rows[4].udp_dp=16'd80;
        f_rows[4].l4_proto=8'd6; f_rows[4].tcp_flags=8'h02;   // TCP, SYN

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
        chk("IPv6 dst-addr modifier rotates (low lane)", v6_dlo_distinct >= 4);
        // Full 128-bit RANDOM rotation. The four dst lanes (32-bit words @38/42/
        // 46/50) are scrambled with distinct lane salts -> all differ; src (@22)
        // uses a distinct field salt from dst -> src != dst even with the same
        // mask. Proves mod128's field/lane salting (a salt-constant change would
        // break these). xorshift is a bijection, so distinct salted inputs give
        // distinct outputs deterministically.
        chk("IPv6 random: 4 dst lanes differ (lane salt)",
            ({cap6[38],cap6[39],cap6[40],cap6[41]} != {cap6[42],cap6[43],cap6[44],cap6[45]}) &&
            ({cap6[42],cap6[43],cap6[44],cap6[45]} != {cap6[46],cap6[47],cap6[48],cap6[49]}) &&
            ({cap6[46],cap6[47],cap6[48],cap6[49]} != {cap6[50],cap6[51],cap6[52],cap6[53]}) &&
            ({cap6[38],cap6[39],cap6[40],cap6[41]} != {cap6[50],cap6[51],cap6[52],cap6[53]}));
        chk("IPv6 random: src != dst (field salt)",
            {cap6[22],cap6[23],cap6[24],cap6[25]} != {cap6[38],cap6[39],cap6[40],cap6[41]});
        // IPv4 TCP flow (flow_id 9 / slot 4): stateless SYN segment generation.
        chk("IPv4 TCP frames emitted", tcp_seen >= 2);
        chk("captured IPv4 TCP frame", capt_done && capt_n >= 86);
        chk("IPv4 TCP proto byte = 6", capt[23] == 8'd6);
        chk("TCP data offset 5 | flags SYN", capt[46] == 8'h50 && capt[47] == 8'h02);
        chk("TCP window 0xFFFF", capt[48] == 8'hFF && capt[49] == 8'hFF);
        chk("IPv4 TCP L4 checksum valid (independent ref)", tcp_csum_ok());
        // MAC modifier (slot 0 src MAC low byte) + VLAN modifier (slot 1 VID).
        chk("src-MAC modifier rotates low byte", smac_lo_distinct >= 4);
        chk("src-MAC modifier keeps high bytes", smac_hi_const);
        chk("VLAN-ID modifier rotates", vid_lo_distinct >= 4);
        // Variable frame length (flow_id 7): sweep 128 -> 256 by 64.
        chk("var-len emits 128B frames", len7_128 >= 2);
        chk("var-len emits 192B frames", len7_192 >= 2);
        chk("var-len emits 256B frames", len7_256 >= 2);
        chk("var-len has no off-grid lengths", len7_other == 0);
        chk("var-len IPv4 total_len tracks frame", len7_totlen_ok);
        chk("var-len IPv4 header checksum valid", len7_csum_ok);

        // ---- exact low-rate interval: pins the token-bucket pipeline equivalence ----
        // One flow, accrual = exactly 1.0 byte/cycle (tokens_fp = 1<<16). The
        // token bucket conserves: over one period accrual*interval == cost (one
        // deduct), so the steady-state SOF-to-SOF interval = cost/tokens_fp =
        // pw_frame_bytes(row,32) cycles, CONSTANT (refill-limited, emit << period).
        // The registered-operand deduct must reproduce this exactly: a 1-tick
        // error would shift the interval or make it jitter.
        begin
            automatic int expw;
            for (int s = 0; s < SLOTS; s++) f_rows[s] = '0;
            f_rows[0].valid=1; f_rows[0].egress=0; f_rows[0].flow_id=32'd9;
            f_rows[0].src_mac=48'h02_00_00_00_00_01; f_rows[0].dst_mac=48'hFF_FF_FF_FF_FF_FF;
            f_rows[0].src_ipv4=32'h0A000001; f_rows[0].dst_ipv4=32'h0A000002;
            f_rows[0].udp_sp=16'd4000; f_rows[0].udp_dp=16'd4001; f_rows[0].ttl=8'd64;
            f_rows[0].burst=16'd256;                 // cap = 256<<16 > cost
            f_rows[0].tokens_fp=32'h0001_0000;       // 1.0 byte/cycle
            f_rows[0].frame_len_min=16'd64; f_rows[0].frame_len_max=16'd64; f_rows[0].frame_len_step=16'd1;
            expw = pw_frame_bytes(f_rows[0], 32);    // cost in bytes = 74 (v4: 14+20+8+32)
            // clean reset so buckets/pipeline start empty for a deterministic measurement
            rst_n=0; repeat (4) @(posedge clk); rst_n=1;
            repeat (400) @(posedge clk);             // warm-up to steady state
            rate_phase = 1'b1;
            repeat (700) @(posedge clk);             // ~9 frames at expw-cycle spacing
            rate_phase = 1'b0;
            chk("low-rate: >=5 intervals measured", n_gaps >= 5);   // checks read gaps[1..4]
            // Token-bucket conservation: over one period accrual*interval == cost
            // (one deduct), so the steady-state interval = cost/tokens_fp = expw
            // cycles EXACTLY. The pipelined deduct must reproduce this (it folds
            // the start-cycle accrual in, like the un-pipelined path); a 1-tick
            // error -- e.g. registering the raw bucket and dropping one accrual --
            // would shift this to expw+1 and run the flow ~1.35% slow.
            chk("low-rate interval == cost/tokens_fp (exact)",
                gaps[1]==expw && gaps[2]==expw && gaps[3]==expw);
            chk("low-rate interval constant (no jitter)",
                gaps[1]==gaps[2] && gaps[2]==gaps[3] && gaps[3]==gaps[4]);
            $display("flow_gen_multi: low-rate expw=%0d gaps={%0d,%0d,%0d,%0d,%0d}",
                     expw, gaps[0], gaps[1], gaps[2], gaps[3], gaps[4]);
        end

        // ---- cap=1 line rate: pipeline stays primed, no per-frame drain bubble ----
        // One 74 B flow (10 emit beats), bucket = 1 frame (burst=1), refill rate
        // far above line so tokens are ready the instant a frame ends. The active
        // slot is kept eligible through its emit, so pick_valid_qq stays high and
        // the next frame launches ~1 cycle after the last -> min SOF-to-SOF gap
        // ~= 11 (10 + 1), NOT ~15 (10 + ~5 drain). Guards the priming fix.
        begin
            for (int s = 0; s < SLOTS; s++) f_rows[s] = '0;
            f_rows[0].valid=1; f_rows[0].egress=0; f_rows[0].flow_id=32'd9;
            f_rows[0].src_mac=48'h02_00_00_00_00_01; f_rows[0].dst_mac=48'hFF_FF_FF_FF_FF_FF;
            f_rows[0].src_ipv4=32'h0A000001; f_rows[0].dst_ipv4=32'h0A000002;
            f_rows[0].udp_sp=16'd4000; f_rows[0].udp_dp=16'd4001; f_rows[0].ttl=8'd64;
            f_rows[0].burst=16'd74;                   // cap = exactly 1 frame (74 B)
            f_rows[0].tokens_fp=32'h0040_0000;        // 64 B/cyc -- far above line
            f_rows[0].frame_len_min=16'd74; f_rows[0].frame_len_max=16'd74; f_rows[0].frame_len_step=16'd1;
            rst_n=0; repeat (4) @(posedge clk); rst_n=1;
            repeat (200) @(posedge clk);              // warm to steady state
            br_phase = 1'b1;
            repeat (400) @(posedge clk);
            br_phase = 1'b0;
            chk("cap=1: back-to-back gaps measured", br_n >= 5);
            // 74 B = 10 emit beats, so a real SOF-to-SOF gap is >= 10 (sanity).
            chk("cap=1 gap >= emit beats (sanity)", br_min >= 10);
            // 10 emit beats + ~1-cycle turnaround. The old drain bubble was ~5,
            // giving ~15. Average must sit near 11, not near 15.
            chk("cap=1 single flow reaches ~line rate (avg gap <= 12)",
                (br_sum / br_n) <= 12);
            $display("flow_gen_multi: cap=1 SOF-to-SOF gap min=%0d max=%0d avg=%0d (n=%0d)",
                     br_min, br_max, br_sum / br_n, br_n);
        end

        // ---- frame templates: raw payload + true 64-byte frames ----
        // Four slots at 64-byte fixed length, one per template. Verify each
        // emits a real 64-byte frame with the right layers, a zero payload (no
        // test header for the raw ones), and that m_tstampable is 0 for raw / 1
        // for TEST (so egress pw_ts_insert leaves the raw frames untouched).
        begin
            for (int s = 0; s < SLOTS; s++) begin
                f_rows[s] = '0;
                f_rows[s].src_mac=48'h02_00_00_00_00_01; f_rows[s].dst_mac=48'hFF_FF_FF_FF_FF_FF;
                f_rows[s].udp_sp=16'd4000; f_rows[s].udp_dp=16'd4001; f_rows[s].ttl=8'd64;
                f_rows[s].burst=16'd256; f_rows[s].tokens_fp=32'h0004_0000;  // 4 B/cyc
                f_rows[s].frame_len_min=16'd64; f_rows[s].frame_len_max=16'd64;
                f_rows[s].frame_len_step=16'd1; f_rows[s].egress=0;
            end
            // slot 0: L2RAW (ethertype 0x88B5)
            f_rows[0].valid=1; f_rows[0].flow_id=32'h0100;
            f_rows[0].frame_template=2'd3; f_rows[0].l2_ethertype=16'h88B5;
            // slot 1: L3RAW v4 (src IP ..11), proto = UDP (17) in the IP header
            f_rows[1].valid=1; f_rows[1].flow_id=32'h0101;
            f_rows[1].frame_template=2'd2;
            f_rows[1].src_ipv4=32'h0A000011; f_rows[1].dst_ipv4=32'h0A0000FF;
            // slot 2: L4RAW v4 UDP (src IP ..22), full headers, raw payload
            f_rows[2].valid=1; f_rows[2].flow_id=32'h0102;
            f_rows[2].frame_template=2'd1;
            f_rows[2].src_ipv4=32'h0A000022; f_rows[2].dst_ipv4=32'h0A0000FE;
            // slot 3: TEST (positive control -- must be stampable)
            f_rows[3].valid=1; f_rows[3].flow_id=32'h0055;
            f_rows[3].frame_template=2'd0;
            f_rows[3].src_ipv4=32'h0A000033; f_rows[3].dst_ipv4=32'h0A0000FD;

            rst_n=0; repeat (4) @(posedge clk); rst_n=1;
            raw_phase = 1'b1;
            repeat (2000) @(posedge clk);
            raw_phase = 1'b0;

            // L2RAW: 64B, ethertype 0x88B5, 50B zero payload, not stampable.
            chk("L2RAW captured 64B", l2f_done && l2f_n == 64);
            chk("L2RAW ethertype 0x88B5", l2f[12]==8'h88 && l2f[13]==8'hB5);
            begin automatic logic z=1; for (int i=14;i<64;i++) if (l2f[i]!=8'h00) z=0;
                  chk("L2RAW payload all zero", z); end
            chk("L2RAW not stampable (tuser=0)", l2f_ts == 1'b0);
            // L3RAW: 64B, IPv4, total_len 50, proto 17, valid csum, no L4/test
            // header (30B zero payload after the 20B IP header).
            chk("L3RAW captured 64B", l3f_done && l3f_n == 64);
            chk("L3RAW ethertype IPv4", l3f[12]==8'h08 && l3f[13]==8'h00);
            chk("L3RAW IP total_len = 50", {l3f[16],l3f[17]} == 16'd50);
            chk("L3RAW IP proto = 17", l3f[23] == 8'd17);
            chk("L3RAW IP header checksum valid", ipcsum_ok(l3f));
            begin automatic logic z=1; for (int i=34;i<64;i++) if (l3f[i]!=8'h00) z=0;
                  chk("L3RAW payload (post-IP) all zero", z); end
            chk("L3RAW not stampable (tuser=0)", l3f_ts == 1'b0);
            // L4RAW: 64B, IPv4/UDP, UDP length 30, no magic, 22B zero payload.
            chk("L4RAW captured 64B", l4f_done && l4f_n == 64);
            chk("L4RAW IP total_len = 50", {l4f[16],l4f[17]} == 16'd50);
            chk("L4RAW UDP length = 30", {l4f[38],l4f[39]} == 16'd30);
            chk("L4RAW IP header checksum valid", ipcsum_ok(l4f));
            chk("L4RAW has NO test-header magic",
                !(l4f[42]==8'hA5 && l4f[43]==8'h02 && l4f[44]==8'h7E && l4f[45]==8'h57));
            begin automatic logic z=1; for (int i=42;i<64;i++) if (l4f[i]!=8'h00) z=0;
                  chk("L4RAW payload (post-UDP) all zero", z); end
            chk("L4RAW not stampable (tuser=0)", l4f_ts == 1'b0);
            // TEST positive control: stampable.
            chk("TEST frame captured", tsf_done);
            chk("TEST frame IS stampable (tuser=1)", tsf_ts == 1'b1);
            $display("templates: l2=%0d l3=%0d l4=%0d test=%0d (ts l2=%0b l3=%0b l4=%0b test=%0b)",
                     l2f_n, l3f_n, l4f_n, tsf_n, l2f_ts, l3f_ts, l4f_ts, tsf_ts);
        end

        $display("flow_gen_multi: fid1=%0d fid3=%0d len7={128:%0d,192:%0d,256:%0d} (%0d pass, %0d fail)",
                 seen_a, seen_b, len7_128, len7_192, len7_256, g_pass, g_fail);
        if (g_fail == 0) $display("ALL FLOW_GEN_MULTI SCENARIOS PASS");
        else $display("FAILED with %0d error(s)", g_fail);
        $finish;
    end

    initial begin #400000; $display("WATCHDOG TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
