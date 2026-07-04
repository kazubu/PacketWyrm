// Behavioral tb for pw_dma_slowpath: exercises the custom header insert/strip
// + the taxi async-FIFO+adapter across the two clock domains.
//   1. inject: push an H2C frame (256 b, first 8 B = {egress} header + payload);
//      expect the header stripped, payload on m_inj (64 b), egress latched.
//   2. punt: push an s_punt frame (64 b + tuser); expect an 8 B header beat
//      ({lif_id,ingress}) prepended, then the payload, on m_c2h (256 b).
`timescale 1ns / 1ps
`default_nettype none

module tb_dma_slowpath;
    localparam int XD = 256, DP = 64;

    logic axi_clk = 0, axi_rst = 1;
    logic dp_clk  = 0, dp_rst  = 1;
    always #2.0 axi_clk = ~axi_clk;   // 250 MHz
    always #3.2 dp_clk  = ~dp_clk;    // ~156.25 MHz

    // H2C in (inject source)
    logic [XD-1:0] s_h2c_tdata; logic [XD/8-1:0] s_h2c_tkeep;
    logic s_h2c_tvalid, s_h2c_tlast; wire s_h2c_tready;
    // C2H out (punt sink)
    wire [XD-1:0] m_c2h_tdata; wire [XD/8-1:0] m_c2h_tkeep;
    wire m_c2h_tvalid, m_c2h_tlast; logic m_c2h_tready;
    // inject out
    wire [DP-1:0] m_inj_tdata; wire [DP/8-1:0] m_inj_tkeep;
    wire m_inj_tvalid, m_inj_tlast; logic m_inj_tready; wire [3:0] m_inj_egress;
    // punt in
    logic [DP-1:0] s_punt_tdata; logic [DP/8-1:0] s_punt_tkeep;
    logic s_punt_tvalid, s_punt_tlast; wire s_punt_tready; logic [99:0] s_punt_tuser;

    pw_dma_slowpath dut (
        .axi_clk(axi_clk), .axi_rst(axi_rst),
        .s_h2c_tdata(s_h2c_tdata), .s_h2c_tkeep(s_h2c_tkeep),
        .s_h2c_tvalid(s_h2c_tvalid), .s_h2c_tready(s_h2c_tready), .s_h2c_tlast(s_h2c_tlast),
        .m_c2h_tdata(m_c2h_tdata), .m_c2h_tkeep(m_c2h_tkeep),
        .m_c2h_tvalid(m_c2h_tvalid), .m_c2h_tready(m_c2h_tready), .m_c2h_tlast(m_c2h_tlast),
        .dp_clk(dp_clk), .dp_rst(dp_rst),
        .m_inj_tdata(m_inj_tdata), .m_inj_tkeep(m_inj_tkeep),
        .m_inj_tvalid(m_inj_tvalid), .m_inj_tready(m_inj_tready), .m_inj_tlast(m_inj_tlast),
        .m_inj_egress(m_inj_egress),
        .s_punt_tdata(s_punt_tdata), .s_punt_tkeep(s_punt_tkeep),
        .s_punt_tvalid(s_punt_tvalid), .s_punt_tready(s_punt_tready),
        .s_punt_tlast(s_punt_tlast), .s_punt_tuser(s_punt_tuser)
    );

    int errors = 0;
    task automatic check(string n, logic cond);
        if (cond) $display("[ ok ] %s", n);
        else      begin $display("[FAIL] %s", n); errors++; end
    endtask

    // collectors
    logic [7:0] inj_bytes [$];
    logic [3:0] inj_egr_seen;
    int         inj_frames = 0;
    always @(posedge dp_clk) begin
        if (m_inj_tvalid && m_inj_tready) begin
            for (int b = 0; b < DP/8; b++)
                if (m_inj_tkeep[b]) inj_bytes.push_back(m_inj_tdata[b*8 +: 8]);
            inj_egr_seen = m_inj_egress;
            if (m_inj_tlast) inj_frames++;
        end
    end
    // Accept counter, used by the punt driver to advance beats race-free.
    int punt_accepts = 0;
    always @(posedge dp_clk) if (s_punt_tvalid && s_punt_tready) punt_accepts++;
    logic [7:0] c2h_bytes [$];
    int         c2h_frames = 0;
    always @(posedge axi_clk) begin
        if (m_c2h_tvalid && m_c2h_tready) begin
            for (int b = 0; b < XD/8; b++)
                if (m_c2h_tkeep[b]) c2h_bytes.push_back(m_c2h_tdata[b*8 +: 8]);
            if (m_c2h_tlast) c2h_frames++;
        end
    end

    initial begin
        s_h2c_tdata='0; s_h2c_tkeep='0; s_h2c_tvalid=0; s_h2c_tlast=0;
        s_punt_tdata='0; s_punt_tkeep='0; s_punt_tvalid=0; s_punt_tlast=0; s_punt_tuser='0;
        m_inj_tready=1; m_c2h_tready=1;
        repeat (20) @(posedge axi_clk);
        axi_rst=0; dp_rst=0;
        repeat (20) @(posedge axi_clk);

        // ---- Test 1: inject one frame ----
        // 256-bit beat: bytes[0]=egress(=2), bytes[1..7]=rsv, bytes[8..23]=payload 0x01..0x10
        begin
            logic [XD-1:0] d = '0;
            d[7:0] = 8'd2;                        // egress header
            for (int i = 0; i < 16; i++) d[(8+i)*8 +: 8] = 8'(i+1);  // payload
            @(posedge axi_clk);
            s_h2c_tdata = d;
            s_h2c_tkeep = {8'h0, 24'hFFFFFF};     // 24 valid bytes (8 hdr + 16 payload)
            s_h2c_tvalid = 1; s_h2c_tlast = 1;
            do @(posedge axi_clk); while (!s_h2c_tready);
            s_h2c_tvalid = 0; s_h2c_tlast = 0; s_h2c_tkeep='0;
        end
        // wait for m_inj to drain into the dp domain
        repeat (400) @(posedge dp_clk);
        check("inject: one frame emitted", inj_frames == 1);
        check("inject: egress latched = 2", inj_egr_seen == 4'd2);
        check("inject: 16 payload bytes (header stripped)", inj_bytes.size() == 16);
        if (inj_bytes.size() == 16) begin
            logic ok = 1;
            for (int i = 0; i < 16; i++) if (inj_bytes[i] != 8'(i+1)) ok = 0;
            check("inject: payload bytes correct", ok);
        end

        // ---- Test 2: punt one frame ----
        // s_punt frame: 16 bytes payload over two 64-b beats; tuser lif=0x1234, ingress=1
        s_punt_tuser = {64'd0, 4'd1, 32'h0000_1234};  // {rx_ts, ingress[3:0], lif_id[31:0]}
        begin
            // Drive beats on the negedge (mid-cycle) and advance only when the
            // always@(posedge) accept-counter confirms the beat was consumed --
            // decouples the driver from the accept edge (no data/ready race).
            int prev;
            @(negedge dp_clk);
            s_punt_tdata = {8'h08,8'h07,8'h06,8'h05,8'h04,8'h03,8'h02,8'h01};
            s_punt_tkeep = 8'hFF; s_punt_tvalid = 1; s_punt_tlast = 0;
            prev = punt_accepts; wait (punt_accepts == prev + 1);   // beat0 accepted
            @(negedge dp_clk);
            s_punt_tdata = {8'h10,8'h0F,8'h0E,8'h0D,8'h0C,8'h0B,8'h0A,8'h09};
            s_punt_tkeep = 8'hFF; s_punt_tvalid = 1; s_punt_tlast = 1;
            prev = punt_accepts; wait (punt_accepts == prev + 1);   // beat1 accepted
            @(negedge dp_clk);
            s_punt_tvalid = 0; s_punt_tlast = 0; s_punt_tkeep='0;
        end
        repeat (400) @(posedge axi_clk);
        check("punt: one frame emitted", c2h_frames == 1);
        // expect 8 (header) + 16 (payload) = 24 bytes
        check("punt: 24 bytes (8 hdr + 16 payload)", c2h_bytes.size() == 24);
        if (c2h_bytes.size() == 24) begin
            // header: lif_id[31:0] little-endian in bytes 0..3, ingress in byte 4
            logic [31:0] lif = {c2h_bytes[3],c2h_bytes[2],c2h_bytes[1],c2h_bytes[0]};
            check("punt: header lif_id = 0x1234", lif == 32'h0000_1234);
            check("punt: header ingress = 1", c2h_bytes[4] == 8'd1);
            // byte_len (bytes 5-6, LE) = the 16-byte frame the SAF measured.
            check("punt: header byte_len = 16",
                  ({c2h_bytes[6], c2h_bytes[5]}) == 16'd16);
            check("punt: payload byte[0]=0x01", c2h_bytes[8] == 8'h01);
            check("punt: payload byte[15]=0x10", c2h_bytes[23] == 8'h10);
        end

        // ---- Test 3: header-only H2C frame must be dropped, no FSM desync ----
        // A malformed/empty inject: tlast on the single header beat, no payload.
        // It must produce NO m_inj output, and the strip FSM must still parse the
        // NEXT frame's header correctly (regression for the S_HDR-tlast bug where
        // the FSM latched into S_PAY and mis-read the next header as payload).
        inj_bytes = {}; inj_frames = 0;
        begin
            logic [XD-1:0] d;
            // (a) header-only frame: egress=3, tlast on the lone header beat
            @(posedge axi_clk);
            d = '0; d[7:0] = 8'd3;
            s_h2c_tdata = d; s_h2c_tkeep = {24'h0, 8'hFF};   // 8 header bytes only
            s_h2c_tvalid = 1; s_h2c_tlast = 1;
            do @(posedge axi_clk); while (!s_h2c_tready);
            s_h2c_tvalid = 0; s_h2c_tlast = 0; s_h2c_tkeep='0;
            // (b) a normal frame right after: egress=5, 16 payload bytes 0xA0..0xAF
            @(posedge axi_clk);
            d = '0; d[7:0] = 8'd5;
            for (int i = 0; i < 16; i++) d[(8+i)*8 +: 8] = 8'(8'hA0 + i);
            s_h2c_tdata = d; s_h2c_tkeep = {8'h0, 24'hFFFFFF};
            s_h2c_tvalid = 1; s_h2c_tlast = 1;
            do @(posedge axi_clk); while (!s_h2c_tready);
            s_h2c_tvalid = 0; s_h2c_tlast = 0; s_h2c_tkeep='0;
        end
        repeat (400) @(posedge dp_clk);
        check("inject hdr-only: exactly one payload frame (empty dropped)", inj_frames == 1);
        check("inject hdr-only: next egress = 5 (no desync)", inj_egr_seen == 4'd5);
        check("inject hdr-only: 16 payload bytes", inj_bytes.size() == 16);
        if (inj_bytes.size() == 16) begin
            logic ok = 1;
            for (int i = 0; i < 16; i++) if (inj_bytes[i] != 8'(8'hA0 + i)) ok = 0;
            check("inject hdr-only: next payload correct", ok);
        end

        if (errors == 0) $display("ALL DMA SLOWPATH SCENARIOS PASS");
        else             $display("FAILED with %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT"); $finish;
    end
endmodule

`default_nettype wire
