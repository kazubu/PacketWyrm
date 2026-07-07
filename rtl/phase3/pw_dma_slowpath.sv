// SPDX-License-Identifier: (see repo LICENSE)
//
// pw_dma_slowpath -- PCIe-DMA slow path (host <-> FPGA frame movement) for the
// XDMA AXI-Stream engine. Replaces the CSR-window inject/punt (pw_inject_tx_window
// / pw_punt_rx_window), which capped frames at 512 B inject / 2048 B punt and ran
// at ~200 ms via MMIO-per-word. See docs/design/dma-slow-path.md (Approach A2).
//
// The Xilinx XDMA IP (AXI-Stream mode) presents:
//   * m_axis_h2c (host->FPGA, 256 b @ axi_aclk 250 MHz)  -> our inject source
//   * s_axis_c2h (FPGA->host, 256 b @ axi_aclk 250 MHz)  <- our punt sink
// The data-plane inject/punt AXIS is 64 b @ dp_clk (156.25 MHz). This module
// bridges the two: async CDC + width conversion (256<->64) via the proven taxi
// async-FIFO+adapter, plus a fixed 8-byte in-band metadata header per frame
// (XDMA AXI-ST C2H has no per-frame completion sideband, so metadata rides the
// byte stream). Headers are exactly one 64 b beat, so payload stays 8-byte
// aligned and no sub-beat barrel shifting is needed.
//
//   inject header (host -> FPGA, first 8 bytes of each H2C frame):
//     [7:0]   egress_local_port     (rest reserved, host sets 0)
//   punt header (FPGA -> host, first 8 bytes of each C2H frame):
//     [31:0]  logical_if_id
//     [39:32] ingress_local_port    (rest reserved)
//
// Metadata note: the punt RX wire timestamp (s_punt_tuser rx_ts) is NOT carried
// in v1 (the 8-byte header holds lif_id + ingress only). If a future PTP servo
// needs punt timestamps, widen the header to 16 B (add a second beat) on both
// this module and the host parser.

`timescale 1ns / 1ps
`default_nettype none

module pw_dma_slowpath #(
    parameter int DP_DATA_W  = 64,
    parameter int XD_DATA_W  = 256,
    // Async-FIFO depth (in DP_DATA_W words). 2048 words * 8 B = 16 KB per
    // direction -> a couple of jumbo (9 KB) frames in flight. BRAM is ample.
    parameter int FIFO_DEPTH = 2048,
    // Number of data-plane egress ports. An inject header whose egress id is
    // >= PORT_COUNT would never be drained by any TX arbiter (tvalid would
    // stay high forever and wedge the whole H2C channel), so such frames are
    // swallowed here instead of being presented on m_inj.
    parameter int PORT_COUNT = 2
) (
    // ---- XDMA domain (axi_aclk, ~250 MHz; axi_rst active-high) ----
    input  wire                        axi_clk,
    input  wire                        axi_rst,
    // H2C stream in (host -> FPGA) = inject source
    input  wire [XD_DATA_W-1:0]        s_h2c_tdata,
    input  wire [XD_DATA_W/8-1:0]      s_h2c_tkeep,
    input  wire                        s_h2c_tvalid,
    output wire                        s_h2c_tready,
    input  wire                        s_h2c_tlast,
    // C2H stream out (FPGA -> host) = punt sink
    output wire [XD_DATA_W-1:0]        m_c2h_tdata,
    output wire [XD_DATA_W/8-1:0]      m_c2h_tkeep,
    output wire                        m_c2h_tvalid,
    input  wire                        m_c2h_tready,
    output wire                        m_c2h_tlast,

    // ---- data-plane domain (dp_clk, 156.25 MHz; dp_rst active-high) ----
    input  wire                        dp_clk,
    input  wire                        dp_rst,
    // inject out -> TX arbiter (egress port selected per-frame from the header)
    output wire [DP_DATA_W-1:0]        m_inj_tdata,
    output wire [DP_DATA_W/8-1:0]      m_inj_tkeep,
    output wire                        m_inj_tvalid,
    input  wire                        m_inj_tready,
    output wire                        m_inj_tlast,
    output wire [3:0]                  m_inj_egress,
    // punt in <- data plane (tuser = {rx_ts[63:0], ingress[3:0], lif_id[31:0]})
    input  wire [DP_DATA_W-1:0]        s_punt_tdata,
    input  wire [DP_DATA_W/8-1:0]      s_punt_tkeep,
    input  wire                        s_punt_tvalid,
    output wire                        s_punt_tready,
    input  wire                        s_punt_tlast,
    input  wire [99:0]                 s_punt_tuser
);

    localparam int DP_KEEP_W = DP_DATA_W/8;

    // ================================================================
    // INJECT: H2C (256@axi) --async+downsize--> 64@dp --strip header--> m_inj
    // ================================================================
    // taxi interfaces: XDMA-side 256 b (sink of the adapter), dp-side 64 b (src).
    taxi_axis_if #(.DATA_W(XD_DATA_W)) inj_xd ();
    taxi_axis_if #(.DATA_W(DP_DATA_W)) inj_dp ();

    assign inj_xd.tdata  = s_h2c_tdata;
    assign inj_xd.tkeep  = s_h2c_tkeep;
    assign inj_xd.tstrb  = s_h2c_tkeep;
    assign inj_xd.tvalid = s_h2c_tvalid;
    assign inj_xd.tlast  = s_h2c_tlast;
    assign inj_xd.tid    = '0;
    assign inj_xd.tdest  = '0;
    assign inj_xd.tuser  = '0;
    assign s_h2c_tready  = inj_xd.tready;

    taxi_axis_async_fifo_adapter #(
        .DEPTH          (FIFO_DEPTH),
        .FRAME_FIFO     (1'b1),          // frame mode: clean per-frame boundaries
        .DROP_OVERSIZE_FRAME (1'b1)      // drop frames larger than the FIFO
    ) u_inj_fifo (
        .s_clk   (axi_clk), .s_rst (axi_rst), .s_axis (inj_xd),
        .m_clk   (dp_clk),  .m_rst (dp_rst),  .m_axis (inj_dp)
    );

    // Header-strip FSM (dp domain): the first 64 b beat of each frame is the
    // inject header; latch egress and drop it, then forward the payload beats.
    // S_DROP swallows the payload of a frame whose header carried an
    // out-of-range egress id (>= PORT_COUNT): no TX arbiter would ever match
    // such an id, so presenting the frame on m_inj would leave tvalid high
    // forever, back up the inject FIFO, and wedge the XDMA H2C channel until
    // an operator-issued reset. Dropped frames are not counted -- the module
    // exposes no debug/stats counters today; if one is ever added, count
    // invalid-egress drops there.
    localparam logic [1:0] S_HDR = 2'd0, S_PAY = 2'd1, S_DROP = 2'd2;
    logic [1:0] inj_state;
    logic [3:0] inj_egress_q;

    // Validate the full header egress byte (byte 0), not just the 4 bits we
    // latch: a host bug that writes e.g. 0x10 must not alias to port 0.
    wire inj_hdr_egress_bad = (inj_dp.tdata[7:0] >= 8'(PORT_COUNT));

    always_ff @(posedge dp_clk) begin
        if (dp_rst) begin
            inj_state    <= S_HDR;
            inj_egress_q <= '0;
        end else begin
            // advance on accepted beats of the dp-side stream
            if (inj_dp.tvalid && inj_dp.tready) begin
                case (inj_state)
                    S_HDR: begin
                        inj_egress_q <= inj_dp.tdata[3:0];   // header: egress in byte 0
                        // A header-only frame (tlast on the header beat) is a
                        // malformed/empty inject with no payload -- stay in S_HDR so
                        // the header is swallowed and dropped, and the NEXT frame's
                        // header is still parsed as a header (not mis-read as payload).
                        if (inj_dp.tlast)             inj_state <= S_HDR;
                        else if (inj_hdr_egress_bad)  inj_state <= S_DROP;
                        else                          inj_state <= S_PAY;
                    end
                    S_PAY:  if (inj_dp.tlast) inj_state <= S_HDR;
                    // invalid egress: consume payload beats without presenting them
                    S_DROP: if (inj_dp.tlast) inj_state <= S_HDR;
                    default: inj_state <= S_HDR;
                endcase
            end
        end
    end

    // In S_HDR/S_DROP: consume (ready) but do NOT present to m_inj.
    // In S_PAY: pass through.
    wire inj_is_pay = (inj_state == S_PAY);
    assign m_inj_tdata   = inj_dp.tdata;
    assign m_inj_tkeep   = inj_dp.tkeep[DP_KEEP_W-1:0];
    assign m_inj_tlast   = inj_dp.tlast;
    assign m_inj_egress  = inj_egress_q;
    assign m_inj_tvalid  = inj_dp.tvalid & inj_is_pay;
    // ready back to the FIFO: always ready in S_HDR/S_DROP (swallow), else follow m_inj
    assign inj_dp.tready = inj_is_pay ? m_inj_tready : 1'b1;

    // ================================================================
    // PUNT: s_punt(64@dp) --insert header--> 64@dp --async+upsize--> m_c2h(256@axi)
    // ================================================================
    taxi_axis_if #(.DATA_W(DP_DATA_W)) punt_dp ();
    taxi_axis_if #(.DATA_W(XD_DATA_W)) punt_xd ();

    // Header-insert FSM (dp domain): on each frame, emit one header beat built
    // from s_punt_tuser, then the frame beats. tuser = {rx_ts[63:0],
    // ingress[3:0], lif_id[31:0]}.
    localparam logic P_HDR = 1'b0, P_PAY = 1'b1;
    logic        punt_state;   // P_HDR: emit header; P_PAY: pass frame
    wire  [31:0] punt_lif      = s_punt_tuser[31:0];
    wire  [3:0]  punt_ingress  = s_punt_tuser[35:32];
    // header beat: byte0..3 = lif_id[31:0] (LE), byte4 = {4'b0, ingress[3:0]}
    wire  [DP_DATA_W-1:0] punt_hdr = { {(DP_DATA_W-40){1'b0}}, 4'b0, punt_ingress, punt_lif };

    always_ff @(posedge dp_clk) begin
        if (dp_rst) begin
            punt_state <= P_HDR;
        end else begin
            if (punt_dp.tvalid && punt_dp.tready) begin
                if (punt_state == P_HDR) punt_state <= P_PAY;
                else if (punt_dp.tlast)  punt_state <= P_HDR;
            end
        end
    end

    wire punt_hdr_beat = (punt_state == P_HDR);
    // Present either the header beat (from tuser, don't consume s_punt yet) or the
    // frame beats (pass-through from s_punt).
    assign punt_dp.tdata  = punt_hdr_beat ? punt_hdr        : s_punt_tdata;
    assign punt_dp.tkeep  = punt_hdr_beat ? {DP_KEEP_W{1'b1}} : s_punt_tkeep;
    assign punt_dp.tstrb  = punt_dp.tkeep;
    assign punt_dp.tlast  = punt_hdr_beat ? 1'b0            : s_punt_tlast;
    assign punt_dp.tid    = '0;
    assign punt_dp.tdest  = '0;
    assign punt_dp.tuser  = '0;
    // valid: header beat is valid whenever a frame is waiting (s_punt_tvalid);
    // frame beats follow s_punt_tvalid.
    assign punt_dp.tvalid = s_punt_tvalid;
    // consume s_punt only during payload (the header beat does not pop s_punt)
    assign s_punt_tready  = (~punt_hdr_beat) & punt_dp.tready;

    taxi_axis_async_fifo_adapter #(
        .DEPTH          (FIFO_DEPTH),
        .FRAME_FIFO     (1'b1),
        .DROP_OVERSIZE_FRAME (1'b1)
    ) u_punt_fifo (
        .s_clk   (dp_clk),  .s_rst (dp_rst),  .s_axis (punt_dp),
        .m_clk   (axi_clk), .m_rst (axi_rst), .m_axis (punt_xd)
    );

    assign m_c2h_tdata   = punt_xd.tdata;
    assign m_c2h_tkeep   = punt_xd.tkeep;
    assign m_c2h_tlast   = punt_xd.tlast;
    assign m_c2h_tvalid  = punt_xd.tvalid;
    assign punt_xd.tready = m_c2h_tready;

endmodule

`default_nettype wire
