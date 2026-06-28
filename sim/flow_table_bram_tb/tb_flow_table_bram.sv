// Unit testbench for pw_flow_table_bram: CSR write -> commit -> walk decodes
// rows into BRAM + the compact scheduling array. Verifies the BRAM read port
// returns the decoded wide row and that the scheduling descriptor (valid /
// egress / tokens / cap / cost) is correct, including encap fields.
`default_nettype none

import pw_axis_pkg::*;

module tb_flow_table_bram;
    localparam int DEPTH  = 8;
    localparam int PORTS  = 2;
    localparam int ADDR_W = 16;
    localparam int PAYLOAD = 32;
    localparam logic [15:0] WIN_BASE   = 16'h2000;
    localparam logic [15:0] COMMIT_OFF = 16'h0FFC;
    localparam logic [15:0] COMMIT_AD  = WIN_BASE + COMMIT_OFF;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [31:0]       wr_data;

    pw_flow_sched_t sched [DEPTH];
    logic [$clog2(DEPTH)-1:0] rd_addr [PORTS];
    pw_flow_row_t   rd_row [PORTS];
    logic           commit_pulse;

    pw_flow_table_bram #(
        .ADDR_W(ADDR_W), .DEPTH(DEPTH), .PORTS(PORTS),
        .FRAME_LEN_PAYLOAD(PAYLOAD), .WIN_BASE(WIN_BASE), .COMMIT_OFFSET(COMMIT_OFF)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .flow_sched_o(sched),
        .rd_addr_i(rd_addr), .rd_row_o(rd_row),
        .commit_pulse_o(commit_pulse)
    );

    int errors = 0;
    task automatic chk(string n, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s got=%0h exp=%0h", n, got, exp); errors++; end
        else $display("[ ok ] %s = %0h", n, got);
    endtask

    task automatic csr_write(input logic [ADDR_W-1:0] a, input logic [31:0] d);
        @(posedge clk); wr_en=1; wr_addr=a; wr_data=d;
        @(posedge clk); wr_en=0; wr_addr=0; wr_data=0;
    endtask

    typedef logic [255:0][7:0] row_bytes_t;
    row_bytes_t row;
    task automatic put8 (input int o, input logic [7:0]  v); row[o]=v; endtask
    task automatic put16(input int o, input logic [15:0] v); row[o]=v[7:0]; row[o+1]=v[15:8]; endtask
    task automatic put32(input int o, input logic [31:0] v);
        row[o]=v[7:0]; row[o+1]=v[15:8]; row[o+2]=v[23:16]; row[o+3]=v[31:24];
    endtask
    task automatic putmac(input int o, input logic [47:0] v); // MSB-first
        row[o]=v[47:40]; row[o+1]=v[39:32]; row[o+2]=v[31:24];
        row[o+3]=v[23:16]; row[o+4]=v[15:8]; row[o+5]=v[7:0];
    endtask
    task automatic write_row(input int idx);
        logic [15:0] base; logic [31:0] d;
        base = WIN_BASE + 16'(idx*256);
        for (int w = 0; w < 64; w++) begin
            d = {row[w*4+3], row[w*4+2], row[w*4+1], row[w*4+0]};
            csr_write(base + 16'(w*4), d);
        end
    endtask

    initial begin
        wr_en=0; wr_addr=0; wr_data=0;
        for (int p=0;p<PORTS;p++) rd_addr[p]=0;
        repeat (4) @(posedge clk); rst_n=1; @(posedge clk);

        // Build row 1: IPIP v4-in-v4 with distinctive fields.
        for (int i=0;i<256;i++) row[i]=8'h00;
        put8 (0,  8'd1);                 // enable
        put8 (90, 8'd1);                 // tx_enable -> valid
        put8 (1,  8'd1);                 // egress = 1
        put32(2,  32'd9);                // flow_id = 9
        putmac(14, 48'h02a5_0200_0002);  // dst_mac
        putmac(20, 48'h02a5_0200_0001);  // src_mac
        put8 (30, 8'd4);                 // ip_version 4 (inner v4)
        put32(31, 32'hC000_0201);        // src_ipv4 (LE on wire) -> 0xC0000201
        put32(35, 32'hC000_0202);        // dst_ipv4
        put16(41, 16'd49152);            // udp src
        put16(43, 16'd50001);            // udp dst
        put32(75, 32'h0004_0000);        // tokens_fp
        put16(79, 16'd256);              // burst
        // encap: IPIP, outer v4
        put8 (157, 8'd1);                // encap_type = IPIP
        put8 (158, 8'd4);                // outer_ip_version = 4
        put8 (160, 8'd32);               // outer_ttl
        put32(162, 32'h0A00_0001);       // outer_src_ipv4
        put32(166, 32'h0A00_0002);       // outer_dst_ipv4
        putmac(202, 48'h02bb_0000_0002); // inner dst mac
        putmac(208, 48'h02bb_0000_0001); // inner src mac
        write_row(1);
        csr_write(COMMIT_AD, 32'h1);

        // Wait for the commit walk to finish. The staging is now a 32-bit-word
        // BRAM walked one word per cycle, so the walk takes DEPTH*ROW_DW (=64)
        // words + a few pipeline cycles, not DEPTH cycles.
        repeat (DEPTH*64 + 16) @(posedge clk);

        // Scheduling descriptor for slot 1.
        chk("sched[1].valid",  sched[1].valid, 1);
        chk("sched[1].egress", sched[1].egress, 1);
        chk("sched[1].tokens", sched[1].tokens_fp, 32'h0004_0000);
        chk("sched[1].cap",    sched[1].cap, {16'd256, 16'h0});
        // cost = frame_bytes << 16. IPIP v4-in-v4, no vlan:
        //   14 + outer20 + 0 + inner20 + 8 + 32 = 94
        chk("sched[1].cost",   sched[1].cost, {16'd94, 16'h0});
        // Unwritten rows must walk in INERT (valid=0), not decode undefined
        // staging bits to a bogus live flow -- the zero-init staging contract
        // (the old pw_csr_window reset shadow to 0; the BRAM staging now zero-
        // inits explicitly). Only row 1 was written, so 0 and 2..DEPTH-1 are all
        // unwritten; check the boundaries + the descriptor AND the wide row.
        chk("sched[0].valid",        sched[0].valid, 0);          // untouched slot
        chk("sched[2].valid",        sched[2].valid, 0);
        chk("sched[DEPTH-1].valid",  sched[DEPTH-1].valid, 0);
        rd_addr[0] = 3'd2;
        @(posedge clk); @(posedge clk);
        chk("unwritten row valid=0",  rd_row[0].valid, 0);
        chk("unwritten row egress=0", rd_row[0].egress, 0);

        // BRAM read of slot 1 via port 0 (1-cycle latency).
        rd_addr[0] = 3'd1; rd_addr[1] = 3'd1;
        @(posedge clk); @(posedge clk);
        chk("row.valid",     rd_row[0].valid, 1);
        chk("row.egress",    rd_row[0].egress, 1);
        chk("row.flow_id",   rd_row[0].flow_id, 9);
        chk("row.src_ipv4",  rd_row[0].src_ipv4, 32'hC000_0201);
        chk("row.dst_ipv4",  rd_row[0].dst_ipv4, 32'hC000_0202);
        chk("row.udp_dp",    rd_row[0].udp_dp, 50001);
        chk("row.src_mac",   rd_row[0].src_mac, 48'h02a5_0200_0001);
        chk("row.is_v6",     rd_row[0].is_v6, 0);
        chk("row.encap_type",rd_row[0].encap_type, 1);
        chk("row.outer_v6",  rd_row[0].outer_v6, 0);
        chk("row.outer_ttl", rd_row[0].outer_ttl, 32);
        chk("row.outer_src", rd_row[0].outer_src_ipv4, 32'h0A00_0001);
        chk("row.inner_dmac",rd_row[0].inner_dst_mac, 48'h02bb_0000_0002);
        chk("row.inner_smac",rd_row[0].inner_src_mac, 48'h02bb_0000_0001);
        // second read port returns the same row
        chk("port1 row.flow_id", rd_row[1].flow_id, 9);

        // ---- post-reset staging guard ----
        // Row 1 is committed + valid (stale bytes now sit in the staging BRAM).
        // After a bare reset (which does NOT zero block RAM), write ONLY a
        // different row and commit: the freshly-written row must come up valid,
        // but row 1 -- not (re)written since reset -- must be INERT despite its
        // stale staging bytes (the row_written guard). This is the contract a
        // single-row tool relies on.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        // build row 3: plain IPv4/UDP, valid
        for (int i=0;i<256;i++) row[i]=8'h00;
        put8 (0,  8'd1);                 // enable
        put8 (90, 8'd1);                 // tx_enable -> valid
        put8 (1,  8'd0);                 // egress 0
        put32(2,  32'd77);               // flow_id 77
        put8 (30, 8'd4);                 // inner v4
        put32(75, 32'h0004_0000);        // tokens_fp
        put16(79, 16'd256);              // burst
        write_row(3);
        csr_write(COMMIT_AD, 32'h1);
        repeat (DEPTH*64 + 16) @(posedge clk);
        chk("post-reset row3 valid",      sched[3].valid, 1);
        chk("post-reset row3 flow_id",    sched[3].egress, 0);
        // row 1's stale staging bytes must NOT resurrect it as a live flow
        chk("post-reset row1 INERT",      sched[1].valid, 0);
        rd_addr[0] = 3'd1;
        @(posedge clk); @(posedge clk);
        chk("post-reset row1 rd_row inert", rd_row[0].valid, 0);

        if (errors == 0) $display("ALL FLOW_TABLE_BRAM SCENARIOS PASS");
        else             $display("FAILED with %0d error(s)", errors);
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule
`default_nettype wire
