// Unit testbench for pw_flowid_map: program flow_id -> {valid, local} entries,
// then look up and check the is_test gate, range, and miss behaviour.

`default_nettype none

module tb_flowid_map;

    localparam int NUM_FLOWS = 32;
    localparam int MAP_DEPTH = 256;
    localparam int AW  = $clog2(MAP_DEPTH);
    localparam int LFW = $clog2(NUM_FLOWS);

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic            wr_en;
    logic [AW-1:0]   wr_addr;
    logic            wr_valid;
    logic [LFW-1:0]  wr_lfid;
    logic [31:0]     flowid;
    logic            is_test, lookup_en;
    logic            valid_o;
    logic [LFW-1:0]  lfid_o;

    pw_flowid_map #(.NUM_FLOWS(NUM_FLOWS), .MAP_DEPTH(MAP_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_valid(wr_valid), .wr_lfid(wr_lfid),
        .flowid_i(flowid), .is_test_i(is_test), .lookup_en_i(lookup_en),
        .valid_o(valid_o), .local_flow_id_o(lfid_o)
    );

    int errors = 0;
    task automatic chk(string what, longint got, longint exp);
        if (got !== exp) begin $display("[FAIL] %s: got=%0d exp=%0d", what, got, exp); errors++; end
        else $display("[ ok ] %s: %0d", what, got);
    endtask

    task automatic prog(input int fid, input bit v, input int lf);
        @(negedge clk);
        wr_en = 1'b1; wr_addr = fid[AW-1:0]; wr_valid = v; wr_lfid = lf[LFW-1:0];
        @(negedge clk); wr_en = 1'b0;
    endtask

    task automatic look(input int fid, input bit t, input bit en);
        @(negedge clk);
        flowid = fid; is_test = t; lookup_en = en;
        @(negedge clk);   // 1-cycle registered read
    endtask

    initial begin
        wr_en=0; wr_addr=0; wr_valid=0; wr_lfid=0;
        flowid=0; is_test=0; lookup_en=0;
        repeat (3) @(negedge clk); rst_n = 1; @(negedge clk);

        prog(5, 1'b1, 2);
        prog(7, 1'b1, 3);
        prog(40, 1'b1, 31);

        look(5, 1'b1, 1'b1);  chk("f5 valid", valid_o, 1); chk("f5 lfid", lfid_o, 2);
        look(7, 1'b1, 1'b1);  chk("f7 valid", valid_o, 1); chk("f7 lfid", lfid_o, 3);
        look(40,1'b1, 1'b1);  chk("f40 valid", valid_o, 1); chk("f40 lfid", lfid_o, 31);
        look(6, 1'b1, 1'b1);  chk("f6 unprogrammed", valid_o, 0);
        look(5, 1'b0, 1'b1);  chk("f5 not-test gated", valid_o, 0);
        look(5, 1'b1, 1'b0);  chk("f5 lookup_en=0", valid_o, 0);
        look(300,1'b1,1'b1);  chk("oob flowid", valid_o, 0);

        // reprogram f5 invalid
        prog(5, 1'b0, 0);
        look(5, 1'b1, 1'b1);  chk("f5 after invalidate", valid_o, 0);

        if (errors == 0) $display("ALL FLOWID_MAP SCENARIOS PASS");
        else begin $display("FAILED with %0d errors", errors); $fatal; end
        $finish;
    end

    initial begin #100000; $display("WATCHDOG"); $fatal; end

endmodule

`default_nettype wire
