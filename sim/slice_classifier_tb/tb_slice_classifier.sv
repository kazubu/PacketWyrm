// Unit testbench for pw_slice_classifier: program slices (offset/mask/value)
// + rules (care over slice bits) and check header-defined classification.

`default_nettype none

import pw_classifier_pkg::*;

module tb_slice_classifier;

    localparam int HDR_BYTES = 160;
    localparam int NSLICE = 8;
    localparam int NRULE  = 8;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic [HDR_BYTES*8-1:0] window;
    logic [15:0]            base;
    logic                   key_valid;

    logic                   slice_wr_en;
    logic [2:0]             slice_wr_idx;
    logic [15:0]            slice_wr_offset;
    logic [31:0]            slice_wr_mask, slice_wr_value;

    logic                   rule_wr_en;
    logic [2:0]             rule_wr_idx;
    logic [NSLICE-1:0]      rule_wr_care;
    logic [2:0]             rule_wr_action;
    logic [3:0]             rule_wr_egress;
    logic [31:0]            rule_wr_lfid;
    logic [7:0]             rule_wr_prio;
    logic                   rule_wr_enable;

    pw_class_result_t       result;

    pw_slice_classifier #(.HDR_BYTES(HDR_BYTES), .NSLICE(NSLICE), .NRULE(NRULE)) dut (
        .clk(clk), .rst_n(rst_n),
        .window_i(window), .base_i(base), .key_valid_i(key_valid),
        .slice_wr_en(slice_wr_en), .slice_wr_idx(slice_wr_idx),
        .slice_wr_offset(slice_wr_offset), .slice_wr_mask(slice_wr_mask), .slice_wr_value(slice_wr_value),
        .rule_wr_en(rule_wr_en), .rule_wr_idx(rule_wr_idx), .rule_wr_care(rule_wr_care),
        .rule_wr_action(rule_wr_action), .rule_wr_egress(rule_wr_egress),
        .rule_wr_lfid(rule_wr_lfid), .rule_wr_prio(rule_wr_prio), .rule_wr_enable(rule_wr_enable),
        .result_o(result)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++; end
        else $display("[ ok ] %s: %0d", what, got);
    endtask

    task automatic prog_slice(input int idx, input int off, input logic [31:0] mask, input logic [31:0] val);
        @(negedge clk);
        slice_wr_en=1; slice_wr_idx=idx[2:0]; slice_wr_offset=off[15:0]; slice_wr_mask=mask; slice_wr_value=val;
        @(negedge clk); slice_wr_en=0;
    endtask

    task automatic prog_rule(input int idx, input logic [NSLICE-1:0] care, input int act,
                             input int lfid, input int prio);
        @(negedge clk);
        rule_wr_en=1; rule_wr_idx=idx[2:0]; rule_wr_care=care; rule_wr_action=act[2:0];
        rule_wr_egress=0; rule_wr_lfid=lfid; rule_wr_prio=prio[7:0]; rule_wr_enable=1;
        @(negedge clk); rule_wr_en=0;
    endtask

    task automatic setb(input int i, input logic [7:0] v); window[i*8 +: 8] = v; endtask

    task automatic pulse_valid();
        @(negedge clk); key_valid=1; @(negedge clk); key_valid=0;
        @(negedge clk);   // 2-cycle latency -> result valid
    endtask

    initial begin
        window='0; base=0; key_valid=0;
        slice_wr_en=0; rule_wr_en=0;
        slice_wr_idx=0; slice_wr_offset=0; slice_wr_mask=0; slice_wr_value=0;
        rule_wr_idx=0; rule_wr_care=0; rule_wr_action=0; rule_wr_egress=0; rule_wr_lfid=0; rule_wr_prio=0; rule_wr_enable=0;
        repeat (3) @(negedge clk); rst_n=1; @(negedge clk);

        // slice 0 = udp_dst (offset 36, 2 bytes) == 50001 (0xC351)
        prog_slice(0, 36, 32'hFFFF_0000, 32'hC351_0000);
        // slice 1 = ipv4_dst (offset 30, 4 bytes) == 192.0.2.1 (0xC0000201)
        prog_slice(1, 30, 32'hFFFF_FFFF, 32'hC000_0201);
        // rule 0: needs BOTH slices -> TEST_RX, lfid 5
        prog_rule(0, 8'b0000_0011, 1, 5, 10);

        // header that matches both
        setb(30,8'hC0); setb(31,8'h00); setb(32,8'h02); setb(33,8'h01);
        setb(36,8'hC3); setb(37,8'h51);
        pulse_valid();
        chk("both match: hit", result.hit, 1);
        chk("both match: action TEST_RX", longint'(result.action), 1);
        chk("both match: lfid", result.local_flow_id, 5);

        // break udp_dst -> rule needs both -> no hit
        setb(36,8'hC3); setb(37,8'h99);
        pulse_valid();
        chk("udp mismatch: no hit", result.hit, 0);

        // rule 1: care only slice 0 (udp_dst alone), lfid 7, higher prio (lower num)
        prog_rule(1, 8'b0000_0001, 1, 7, 5);
        setb(36,8'hC3); setb(37,8'h51);   // udp_dst matches again
        pulse_valid();
        chk("udp-only rule hit", result.hit, 1);
        chk("udp-only lfid (prio wins)", result.local_flow_id, 7);  // rule1 prio 5 < rule0 prio 10

        if (errors == 0) $display("ALL SLICE_CLASSIFIER SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("WATCHDOG"); $fatal; end

endmodule

`default_nettype wire
