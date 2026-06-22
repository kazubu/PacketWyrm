// Unit testbench for pw_field_classifier: program comparators (canonical-field
// and UDF) + rules and check classification of TEST_RX / PUNT.

`default_nettype none

import pw_classifier_pkg::*;

module tb_field_classifier;
    localparam int HDR_BYTES = 160;
    localparam int SLICE_WIN = 48;
    localparam int NCMP  = 12;
    localparam int NUDF  = 2;
    localparam int NRULE = 8;
    localparam int NTOTAL = NCMP + NUDF;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    pw_match_key_t            key;
    logic [SLICE_WIN*8-1:0]   window;
    logic [15:0]              base;
    logic                     key_valid;

    logic                     cmp_wr_en;  logic [$clog2(NCMP)-1:0] cmp_wr_idx;
    logic [4:0]               cmp_wr_src; logic [31:0] cmp_wr_mask, cmp_wr_value;
    logic                     udf_wr_en;  logic [$clog2(NUDF)-1:0] udf_wr_idx;
    logic [15:0]              udf_wr_offset; logic [31:0] udf_wr_mask, udf_wr_value;
    logic                     rule_wr_en; logic [$clog2(NRULE)-1:0] rule_wr_idx;
    logic [NTOTAL-1:0]        rule_wr_care;
    logic [2:0]               rule_wr_action; logic [3:0] rule_wr_egress;
    logic [31:0]              rule_wr_lfid, rule_wr_lif; logic [7:0] rule_wr_prio;
    logic                     rule_wr_enable;
    pw_class_result_t         result;

    pw_field_classifier #(.HDR_BYTES(HDR_BYTES), .SLICE_WIN(SLICE_WIN),
                          .NCMP(NCMP), .NUDF(NUDF), .NRULE(NRULE)) dut (
        .clk(clk), .rst_n(rst_n), .key_i(key), .window_i(window), .base_i(base),
        .key_valid_i(key_valid),
        .cmp_wr_en(cmp_wr_en), .cmp_wr_idx(cmp_wr_idx), .cmp_wr_src(cmp_wr_src),
        .cmp_wr_mask(cmp_wr_mask), .cmp_wr_value(cmp_wr_value),
        .udf_wr_en(udf_wr_en), .udf_wr_idx(udf_wr_idx), .udf_wr_offset(udf_wr_offset),
        .udf_wr_mask(udf_wr_mask), .udf_wr_value(udf_wr_value),
        .rule_wr_en(rule_wr_en), .rule_wr_idx(rule_wr_idx), .rule_wr_care(rule_wr_care),
        .rule_wr_action(rule_wr_action), .rule_wr_egress(rule_wr_egress),
        .rule_wr_lfid(rule_wr_lfid), .rule_wr_lif(rule_wr_lif),
        .rule_wr_prio(rule_wr_prio), .rule_wr_enable(rule_wr_enable),
        .result_o(result)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++; end
        else $display("[ ok ] %s: %0d", what, got);
    endtask

    task automatic prog_cmp(input int i, input int src, input logic [31:0] msk, input logic [31:0] val);
        @(negedge clk); cmp_wr_en=1; cmp_wr_idx=i[$clog2(NCMP)-1:0]; cmp_wr_src=src[4:0];
        cmp_wr_mask=msk; cmp_wr_value=val; @(negedge clk); cmp_wr_en=0;
    endtask
    task automatic prog_udf(input int i, input int off, input logic [31:0] msk, input logic [31:0] val);
        @(negedge clk); udf_wr_en=1; udf_wr_idx=i[$clog2(NUDF)-1:0]; udf_wr_offset=off[15:0];
        udf_wr_mask=msk; udf_wr_value=val; @(negedge clk); udf_wr_en=0;
    endtask
    task automatic prog_rule(input int i, input logic [NTOTAL-1:0] care, input int act,
                             input int lf, input int lif, input int prio);
        @(negedge clk); rule_wr_en=1; rule_wr_idx=i[$clog2(NRULE)-1:0]; rule_wr_care=care;
        rule_wr_action=act[2:0]; rule_wr_egress=0; rule_wr_lfid=lf; rule_wr_lif=lif;
        rule_wr_prio=prio[7:0]; rule_wr_enable=1; @(negedge clk); rule_wr_en=0;
    endtask
    task automatic setb(input int i, input logic [7:0] v); window[i*8 +: 8] = v; endtask
    task automatic pulse(); @(negedge clk); key_valid=1; @(negedge clk); key_valid=0; @(negedge clk); endtask

    initial begin
        key='0; window='0; base=0; key_valid=0;
        cmp_wr_en=0; udf_wr_en=0; rule_wr_en=0;
        cmp_wr_idx=0; cmp_wr_src=0; cmp_wr_mask=0; cmp_wr_value=0;
        udf_wr_idx=0; udf_wr_offset=0; udf_wr_mask=0; udf_wr_value=0;
        rule_wr_idx=0; rule_wr_care=0; rule_wr_action=0; rule_wr_egress=0;
        rule_wr_lfid=0; rule_wr_lif=0; rule_wr_prio=0; rule_wr_enable=0;
        repeat (3) @(negedge clk); rst_n=1; @(negedge clk);

        // cmp0 = udp_dst (lane 0) == 50001; cmp1 = ipv4_dst (lane 2) == 192.0.2.1
        prog_cmp(0, 0, 32'h0000_FFFF, 32'h0000_C351);
        prog_cmp(1, 2, 32'hFFFF_FFFF, 32'hC000_0201);
        // rule0: both -> TEST_RX lfid 5
        prog_rule(0, 14'h003, 1, 5, 0, 20);

        key.l4_dst   = 16'hC351;  key.udp_dst = 16'hC351;
        key.ipv4_dst = 32'hC000_0201; key.is_udp = 1; key.is_ipv4 = 1;
        pulse();
        chk("field both: hit", result.hit, 1);
        chk("field both: TEST_RX", longint'(result.action), 1);
        chk("field both: lfid", result.local_flow_id, 5);

        // break ipv4_dst -> rule needs both -> no hit
        key.ipv4_dst = 32'hDEAD_BEEF;
        pulse();
        chk("field mismatch: no hit", result.hit, 0);

        // cmp2 = flags lane (12), is_arp = bit1 -> mask 0x2 value 0x2
        prog_cmp(2, 12, 32'h0000_0002, 32'h0000_0002);
        // rule1: is_arp -> PUNT, lif 1234
        prog_rule(1, 14'h004, 2, 0, 1234, 10);
        key='0; key.is_arp = 1; key.ethertype = 16'h0806;
        pulse();
        chk("arp punt: hit", result.hit, 1);
        chk("arp punt: action PUNT", longint'(result.action), 2);
        chk("arp punt: lif", result.logical_if_id, 1234);

        // UDF: window udp_dst at base(14)+22 = abs 36 == 50007
        prog_udf(0, 22, 32'hFFFF_0000, 32'hC357_0000);
        // rule2: udf0 (care bit NCMP+0 = 12) -> TEST_RX lfid 7
        prog_rule(2, (14'h1 << NCMP), 1, 7, 0, 30);
        key='0; base=14; setb(36,8'hC3); setb(37,8'h57);
        pulse();
        chk("udf hit", result.hit, 1);
        chk("udf lfid", result.local_flow_id, 7);

        if (errors == 0) $display("ALL FIELD_CLASSIFIER SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end
    initial begin #200000; $display("WATCHDOG"); $fatal; end
endmodule

`default_nettype wire
