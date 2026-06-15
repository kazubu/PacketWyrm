// Testbench for pw_flow_gen_axis: reassemble the streamed frames and
// check the layout (length, test-header magic, flow_id, incrementing
// sequence) matches the pw_flow_gen wire format.
`default_nettype none

module tb_flow_gen_axis;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [63:0] m_tdata; logic [7:0] m_tkeep; logic m_tvalid, m_tlast;
    logic        m_tready = 1'b1;
    logic [63:0] ts = 64'h0;

    int g_pass = 0, g_fail = 0;
    task chk(input string n, input logic c);
        if (c) begin g_pass++; $display("[ ok ] %s", n); end
        else   begin g_fail++; $display("[FAIL] %s", n); end
    endtask

    pw_flow_gen_axis #(.GLOBAL_FLOW_ID(32'd7), .FRAME_LEN_PAYLOAD(32)) dut (
        .clk(clk), .rst_n(rst_n),
        .enable_i(1'b1),
        .tokens_per_tick_fp_i(32'd00200000),  // ~32 bytes/cyc (fast)
        .burst_bytes_i(16'd128),
        .egress_port_i(4'd0),
        .src_mac_i(48'h02_00_00_00_00_01), .dst_mac_i(48'hFF_FF_FF_FF_FF_FF),
        .vlan_enable_i(1'b0), .vlan_id_i(12'd0),
        .src_ipv4_i(32'h0A000001), .dst_ipv4_i(32'h0A000002),
        .udp_src_port_i(16'd4000), .udp_dst_port_i(16'd4001),
        .timestamp_i(ts),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tready(m_tready), .m_tlast(m_tlast)
    );

    // frame capture
    byte unsigned fr [0:255];
    int           fr_len;
    int           frames_seen = 0;
    logic [63:0]  seq_seen [0:7];

    always_ff @(posedge clk) begin
        ts <= ts + 1;
        if (m_tvalid && m_tready) begin
            for (int k = 0; k < 8; k++) if (m_tkeep[k]) begin
                fr[fr_len] = m_tdata[k*8 +: 8];
                fr_len++;
            end
            if (m_tlast) begin
                // decode test header (no VLAN): magic @42, flow_id @50, seq @54
                automatic int mo = 42;
                if (frames_seen < 8) begin
                    seq_seen[frames_seen] =
                        {fr[mo+12],fr[mo+13],fr[mo+14],fr[mo+15],
                         fr[mo+16],fr[mo+17],fr[mo+18],fr[mo+19]};
                end
                if (frames_seen == 0) begin
                    chk("frame_len==74", fr_len==74);
                    chk("eth dst FF", fr[0]==8'hFF && fr[5]==8'hFF);
                    chk("ethertype IPv4", fr[12]==8'h08 && fr[13]==8'h00);
                    chk("ip ver/ihl 45", fr[14]==8'h45);
                    chk("ip proto UDP", fr[23]==8'h11);
                    chk("test magic", fr[mo]==8'hA5 && fr[mo+1]==8'h02 &&
                                       fr[mo+2]==8'h7E && fr[mo+3]==8'h57);
                    chk("flow_id==7", {fr[mo+8],fr[mo+9],fr[mo+10],fr[mo+11]}==32'd7);
                    chk("seq0==0", seq_seen[0]==64'd0);
                end
                frames_seen++;
                fr_len = 0;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        // run long enough for several frames
        repeat (2000) @(posedge clk);
        chk("saw >=3 frames", frames_seen >= 3);
        chk("seq increments 0,1,2", seq_seen[0]==0 && seq_seen[1]==1 && seq_seen[2]==2);
        $display("flow_gen_axis: %0d passed, %0d failed (%0d frames)", g_pass, g_fail, frames_seen);
        if (g_fail==0) $display("ALL FLOW_GEN_AXIS SCENARIOS PASS");
        $finish;
    end
endmodule
`default_nettype wire
