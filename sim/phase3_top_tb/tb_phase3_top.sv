// End-to-end loop test for pwfpga_top_phase3 (streaming data plane):
//   AXI-Lite host writes -> pw_csr_full -> program both windows
//                                       -> flow_gen_axis emits 64b AXIS
//                                          frames on m_axis_tx[0]
//                                       -> testbench loops 64b AXIS
//                                          from m_axis_tx[0] back into
//                                          s_axis_rx[1]
//                                       -> parser_axis + classifier =>
//                                          TEST_RX checker
//                                       -> snapshot reads back rx>0
//
// Also exercises:
//   * an ARP frame injected on port 0 raises punt AXIS
//   * stats snapshot returns flow_rx for the classified flow

`default_nettype none

import pw_axis_pkg::*;

module tb_phase3_top;

    localparam int NUM_PORTS = 2;
    localparam int NUM_FLOWS = 8;
    localparam int NUM_HIST  = 16;
    localparam int ADDR_W    = 16;

    // Wire offsets (mirror csr.h)
    localparam int W_KEY_OFF    = 0;
    localparam int W_MASK_OFF   = 40;
    localparam int W_LIF        = 80;
    localparam int W_LOCAL_FLOW = 84;
    localparam int W_ACTION     = 88;
    localparam int W_PRIORITY   = 89;
    localparam int W_FLAGS      = 90;

    // Punt / slow-path RX window (PWFPGA_WIN_PUNT_RX = 0x1000)
    localparam logic [15:0] PUNT_STATUS = 16'h1000;
    localparam logic [15:0] PUNT_INFO   = 16'h1004;
    localparam logic [15:0] PUNT_LIF    = 16'h1008;
    localparam logic [15:0] PUNT_POP    = 16'h100C;
    localparam logic [15:0] PUNT_DATA   = 16'h1010;
    localparam int F_ENABLE             = 0;
    localparam int F_EGRESS_PORT        = 1;
    localparam int F_GLOBAL_FLOW_ID     = 2;
    localparam int F_DST_MAC            = 14;
    localparam int F_SRC_MAC            = 20;
    localparam int F_SRC_IPV4           = 31;
    localparam int F_DST_IPV4           = 35;
    localparam int F_UDP_SRC_PORT       = 41;
    localparam int F_UDP_DST_PORT       = 43;
    localparam int F_TOKENS_PER_TICK_FP = 75;
    localparam int F_BURST_BYTES        = 79;
    localparam int F_TX_ENABLE          = 90;

    localparam logic [15:0] WIN_CLS  = 16'h2000;
    localparam logic [15:0] WIN_FLOW = 16'h6000;
    localparam logic [15:0] CLS_COMMIT  = WIN_CLS  + 16'h3FFC;
    localparam logic [15:0] FLOW_COMMIT = WIN_FLOW + 16'h3FFC;
    localparam logic [15:0] STATS_TRIGGER = 16'hC000 + 16'h3FFC;
    localparam logic [15:0] STATS_FLOW_BASE = 16'hC000 + 16'h0100;
    localparam int          OFF_RX_FRAMES = 16;

    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    // AXI-Lite
    logic [ADDR_W-1:0] awaddr;  logic awvalid; logic awready;
    logic [31:0]       wdata;   logic [3:0] wstrb; logic wvalid; logic wready;
    logic [1:0]        bresp;   logic bvalid; logic bready;
    logic [ADDR_W-1:0] araddr;  logic arvalid; logic arready;
    logic [31:0]       rdata;   logic [1:0] rresp; logic rvalid; logic rready;

    // Per-port AXIS RX (into DUT)
    logic [63:0] rx_tdata  [NUM_PORTS];
    logic [7:0]  rx_tkeep  [NUM_PORTS];
    logic        rx_tvalid [NUM_PORTS];
    logic        rx_tready [NUM_PORTS];
    logic        rx_tlast  [NUM_PORTS];
    logic        rx_tuser     [NUM_PORTS] = '{default: 1'b0};
    logic        link_up_t    [NUM_PORTS] = '{default: 1'b1};
    logic        block_lock_t [NUM_PORTS] = '{default: 1'b1};

    // Per-port AXIS TX (out of DUT)
    logic [63:0] tx_tdata  [NUM_PORTS];
    logic [7:0]  tx_tkeep  [NUM_PORTS];
    logic        tx_tvalid [NUM_PORTS];
    logic        tx_tready [NUM_PORTS];
    logic        tx_tlast  [NUM_PORTS];
    logic        tx_tuser  [NUM_PORTS];   // generator-test-frame marker

    // Punt AXIS
    logic [63:0] punt_tdata;
    logic [7:0]  punt_tkeep;
    logic        punt_tvalid;
    logic        punt_tready;
    logic        punt_tlast;

    logic [63:0] ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts <= '0;
        else        ts <= ts + 64'd1;
    end

    // RX ingress wire-timestamp, emulating the board top: per port, latch ts at
    // the frame's SOF beat and present it (constant) for the whole frame. The
    // SOF beat presents ts directly (the held reg updates one cycle later), so
    // whichever beat the data plane reads sees this frame's wire time. This is
    // the same SOF reference the generator stamps tx_timestamp with (build() at
    // emit-start), so checker latency = RX_SOF - TX_SOF = wire-to-wire.
    logic [63:0] rx_wire_ts  [NUM_PORTS];
    logic        rx_inframe  [NUM_PORTS] = '{default: 1'b0};
    logic [63:0] rx_held     [NUM_PORTS] = '{default: '0};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin rx_inframe[p] <= 1'b0; rx_held[p] <= '0; end
        end else begin
            for (int p = 0; p < NUM_PORTS; p++) if (rx_tvalid[p]) begin
                if (!rx_inframe[p]) rx_held[p] <= ts;     // latch SOF wire time
                rx_inframe[p] <= !rx_tlast[p];
            end
        end
    end
    always_comb
        for (int p = 0; p < NUM_PORTS; p++)
            rx_wire_ts[p] = rx_inframe[p] ? rx_held[p] : ts;

    pwfpga_top_phase3 #(
        .NUM_PORTS    (NUM_PORTS),
        .NUM_FLOWS    (NUM_FLOWS),
        .NUM_HIST_BINS(NUM_HIST)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_axi_awaddr (awaddr),  .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata  (wdata),   .s_axi_wstrb (wstrb),   .s_axi_wvalid(wvalid),
        .s_axi_wready (wready),  .s_axi_bresp (bresp),
        .s_axi_bvalid (bvalid),  .s_axi_bready(bready),
        .s_axi_araddr (araddr),  .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata  (rdata),   .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid),  .s_axi_rready(rready),
        .s_axis_rx_tdata  (rx_tdata),
        .s_axis_rx_tkeep  (rx_tkeep),
        .s_axis_rx_tvalid (rx_tvalid),
        .s_axis_rx_tready (rx_tready),
        .s_axis_rx_tlast  (rx_tlast),
        .s_axis_rx_tuser  (rx_tuser),
        .s_axis_rx_wire_ts(rx_wire_ts),
        .link_up_i        (link_up_t),
        .block_lock_i     (block_lock_t),
        .m_axis_tx_tdata  (tx_tdata),
        .m_axis_tx_tkeep  (tx_tkeep),
        .m_axis_tx_tvalid (tx_tvalid),
        .m_axis_tx_tready (tx_tready),
        .m_axis_tx_tlast  (tx_tlast),
        .m_axis_tx_tuser  (tx_tuser),
        // punt is consumed internally by pw_punt_rx_window (read via CSR)
        .timestamp_i  (ts),
        .spi_sck_o    (),
        .spi_cs_n_o   (),
        .spi_mosi_o   (),
        .spi_miso_i   (1'b0),
        .icap_csib_o  (),
        .icap_rdwrb_o (),
        .icap_i_o     (),
        .dp_soft_rst_o(),
        .gpio_i       (6'b0),
        .gpio_o       (),
        .gpio_t       (),
        .sfp_i2c_i    (4'hF),
        .sfp_i2c_o    (),
        .sfp_i2c_t    (),
        .status_err_o      (),
        .status_activity_o ()
    );

    int    errors = 0;
    string scenario = "init";

    task automatic check_eq(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] %s: got=%0d expected=%0d",
                     scenario, what, got, exp);
            errors++;
        end else begin
            $display("[ ok %s] %s: %0d", scenario, what, got);
        end
    endtask

    task automatic axi_write(input logic [ADDR_W-1:0] addr,
                              input logic [31:0]       data);
        @(posedge clk);
        awaddr  = addr;
        awvalid = 1'b1;
        wdata   = data;
        wstrb   = 4'hF;
        wvalid  = 1'b1;
        bready  = 1'b1;
        do @(posedge clk); while (!bvalid);
        awvalid = 1'b0;
        wvalid  = 1'b0;
        bready  = 1'b0;
    endtask

    task automatic axi_read(input  logic [ADDR_W-1:0] addr,
                             output logic [31:0]       data);
        @(posedge clk);
        araddr  = addr;
        arvalid = 1'b1;
        rready  = 1'b1;
        do @(posedge clk); while (!rvalid);
        data    = rdata;
        arvalid = 1'b0;
        rready  = 1'b0;
    endtask

    typedef logic [127:0][7:0] row_bytes_t;
    function automatic row_bytes_t row_zero();
        row_bytes_t r; r = '0; return r;
    endfunction
    function automatic row_bytes_t put_u8(input row_bytes_t r, input int off,
                                           input logic [7:0] v);
        row_bytes_t o; o = r; o[off] = v; return o;
    endfunction
    function automatic row_bytes_t put_u16(input row_bytes_t r, input int off,
                                            input logic [15:0] v);
        row_bytes_t o; o = r;
        o[off + 0] = v[7:0]; o[off + 1] = v[15:8];
        return o;
    endfunction
    function automatic row_bytes_t put_u32(input row_bytes_t r, input int off,
                                            input logic [31:0] v);
        row_bytes_t o; o = r;
        o[off + 0] = v[7:0];  o[off + 1] = v[15:8];
        o[off + 2] = v[23:16]; o[off + 3] = v[31:24];
        return o;
    endfunction
    function automatic row_bytes_t put_mac(input row_bytes_t r, input int off,
                                            input logic [47:0] v);
        row_bytes_t o; o = r;
        o[off + 0] = v[47:40]; o[off + 1] = v[39:32];
        o[off + 2] = v[31:24]; o[off + 3] = v[23:16];
        o[off + 4] = v[15:8];  o[off + 5] = v[7:0];
        return o;
    endfunction

    task automatic write_row(input logic [15:0] win, input int row_idx,
                              input row_bytes_t bytes);
        logic [15:0] row_base;
        logic [31:0] dw;
        row_base = win + 16'(row_idx * 128);
        for (int d = 0; d < 32; d++) begin
            dw = {bytes[d*4+3], bytes[d*4+2], bytes[d*4+1], bytes[d*4+0]};
            axi_write(row_base + 16'(d*4), dw);
        end
    endtask

    // (Punt frames are now consumed by pw_punt_rx_window and read back
    // over the CSR BAR -- see the "punt" scenario.)

    // Send one ARP-like frame (14 bytes, no payload) on port 0 into the
    // DUT's 64-bit AXIS RX. Bytes are packed little-endian (byte k in
    // tdata[8k +: 8]), matching pw_parser_axis / the real MAC.
    //   dst MAC ff:ff:ff:ff:ff:ff, src 02:a5:02:00:00:01, ethertype 0806
    task automatic send_arp_on_rx(input int p);
        // Beat 0: bytes 0..7 = ff ff ff ff ff ff 02 a5
        @(posedge clk);
        rx_tdata[p]  = {8'ha5,8'h02,8'hff,8'hff,8'hff,8'hff,8'hff,8'hff};
        rx_tkeep[p]  = 8'hFF;
        rx_tvalid[p] = 1'b1;
        rx_tlast[p]  = 1'b0;
        do @(posedge clk); while (!rx_tready[p]);
        // Beat 1: bytes 8..13 = 02 00 00 01 08 06  (src tail + ethertype)
        rx_tdata[p]  = {8'h00,8'h00,8'h06,8'h08,8'h01,8'h00,8'h00,8'h02};
        rx_tkeep[p]  = 8'b0011_1111;   // 6 valid bytes -> 14-byte total
        rx_tvalid[p] = 1'b1;
        rx_tlast[p]  = 1'b1;
        do @(posedge clk); while (!rx_tready[p]);
        rx_tvalid[p] = 1'b0;
        rx_tlast[p]  = 1'b0;
        rx_tdata[p]  = '0;
        rx_tkeep[p]  = '0;
    endtask

    initial begin
        awaddr = '0; awvalid = 0;
        wdata  = '0; wstrb = 4'hF; wvalid = 0;
        bready = 0;
        araddr = '0; arvalid = 0; rready = 0;
        for (int p = 0; p < NUM_PORTS; p++) begin
            rx_tdata[p] = '0;  rx_tkeep[p] = '0;
            rx_tvalid[p] = 0;  rx_tlast[p] = 0;
            tx_tready[p] = 1;
        end
        punt_tready = 1;

        repeat (8) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- identity register sanity check ---------------------
        scenario = "identity";
        begin
            logic [31:0] v;
            axi_read(16'h0000, v);
            check_eq("device_id", v, 32'hA502BEEF);
        end

        // ---- program a TEST_RX rule that matches port-0 flow_gen
        //      (GLOBAL_FLOW_ID=1) and an ARP punt rule -----------
        scenario = "program";
        begin
            logic [31:0] w0;
            // TEST_RX for GLOBAL_FLOW_ID=1 -> checker slot 0 via the flow-id map
            // (entry[flow_id] at 0x0400 + flow_id*4, data {[31]valid,[15:0]lfid}).
            axi_write(16'h0400 + 16'(1*4), 32'h8000_0000 | 32'd0);

            // ARP punt via the field classifier: comparator 0 on the flags lane
            // (src 12), is_arp = bit 1 -> mask/value 0x2; rule 0 -> PUNT, lif 0x99.
            axi_write(16'h2000 + 16'h0, 32'd12);          // cmp0 src = flags lane
            axi_write(16'h2000 + 16'h4, 32'h0000_0002);   // cmp0 mask = is_arp bit
            axi_write(16'h2000 + 16'h8, 32'h0000_0002);   // cmp0 value (commit)
            w0 = 32'd0;
            w0[13:0]  = 14'h0001;   // care = cmp0
            w0[16:14] = 3'd2;       // action PUNT_TO_HOST
            w0[28:21] = 8'd10;      // priority
            w0[31]    = 1'b1;       // enable
            axi_write(16'h2200 + 16'h0, w0);              // rule0 word0
            axi_write(16'h2200 + 16'h4, 32'd0);           // rule0 lfid
            axi_write(16'h2200 + 16'h8, 32'h0000_0099);   // rule0 lif (commit)
        end

        // ---- program a flow row binding port 0 to flow_gen -----
        begin
            row_bytes_t fr;
            fr = row_zero();
            fr = put_u8 (fr, F_ENABLE,             8'd1);
            fr = put_u8 (fr, F_EGRESS_PORT,        8'd0);
            fr = put_u32(fr, F_GLOBAL_FLOW_ID,     32'd1);  // multi-gen emits this flow_id
            fr = put_mac(fr, F_DST_MAC,            48'h02_a5_02_00_00_02);
            fr = put_mac(fr, F_SRC_MAC,            48'h02_a5_02_00_00_01);
            fr = put_u32(fr, F_SRC_IPV4,           32'hC000_0201);
            fr = put_u32(fr, F_DST_IPV4,           32'hC000_0202);
            fr = put_u16(fr, F_UDP_SRC_PORT,       16'd49152);
            fr = put_u16(fr, F_UDP_DST_PORT,       16'd50001);
            fr = put_u32(fr, F_TOKENS_PER_TICK_FP, 32'h00040000);
            fr = put_u16(fr, F_BURST_BYTES,        16'd256);
            fr = put_u8 (fr, F_TX_ENABLE,          8'd1);
            write_row(WIN_FLOW, 0, fr);
            axi_write(FLOW_COMMIT, 32'h1);
        end

        // ---- AXIS loopback: port-0 TX out -> port-1 RX in ----
        scenario = "loopback";
        // Run the loop for many cycles so the token bucket emits
        // some frames; each 64b AXIS frame loops m_axis_tx[0] ->
        // s_axis_rx[1] straight into the streaming data plane.
        for (int n = 0; n < 1500; n++) begin
            @(posedge clk);
            rx_tdata[1]  = tx_tdata[0];
            rx_tkeep[1]  = tx_tkeep[0];
            rx_tvalid[1] = tx_tvalid[0];
            rx_tlast[1]  = tx_tlast[0];
        end
        // Idle both sides cleanly before reading stats.
        @(posedge clk);
        rx_tvalid[1] = 0; rx_tlast[1] = 0;
        repeat (8) @(posedge clk);

        // Trigger stats snapshot, read back flow 0's rx_frames.
        axi_write(STATS_TRIGGER, 32'h1);
        @(posedge clk);
        @(posedge clk);
        begin
            logic [31:0] lo, hi, minlat;
            axi_read(STATS_FLOW_BASE + 0*128 + OFF_RX_FRAMES,     lo);
            axi_read(STATS_FLOW_BASE + 0*128 + OFF_RX_FRAMES + 4, hi);
            check_eq("snap flow0 rx_frames > 0", (lo > 0) ? 1 : 0, 1);
            check_eq("snap flow0 rx_frames hi   = 0", hi, 0);
            // RX wire-stamp: latency is now RX_SOF - TX_SOF (both SOF-referenced,
            // wire-to-wire), so in this tight loopback it must be small + bounded
            // -- NOT the old post-FIFO+parser+classifier pipeline figure, and
            // never a wrapped/huge value. (offset 80 = min_latency, u32.)
            axi_read(STATS_FLOW_BASE + 0*128 + 80, minlat);
            check_eq("snap flow0 min_latency bounded (wire-to-wire)",
                     (minlat > 0 && minlat < 32'd256) ? 1 : 0, 1);
        end

        // ---- ARP punt path: drive an ARP frame on RX[0], drain it from
        //      the punt RX window over the CSR BAR --------------------
        scenario = "punt";
        begin
            logic [31:0] st, info, lif;
            send_arp_on_rx(0);
            repeat (24) @(posedge clk);
            axi_read(PUNT_STATUS, st);
            check_eq("punt frame_valid",  st[0], 1);
            check_eq("punt no overflow",  st[1], 0);
            axi_read(PUNT_INFO, info);
            check_eq("punt byte_len > 0", (info[13:0] > 0) ? 1 : 0, 1);
            check_eq("punt ingress port", info[19:16], 0);
            axi_read(PUNT_LIF, lif);
            check_eq("punt logical_if_id", lif, 32'h0000_0099);
            // release the slot and confirm it clears
            axi_write(PUNT_POP, 32'h1);
            repeat (4) @(posedge clk);
            axi_read(PUNT_STATUS, st);
            check_eq("punt slot freed", st[0], 0);
        end

        if (errors == 0) begin
            $display("ALL PHASE3 TOP SCENARIOS PASS");
            $finish;
        end else begin
            $display("FAILED with %0d error(s)", errors);
            $fatal;
        end
    end

    initial begin
        #800000;
        $display("WATCHDOG TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
