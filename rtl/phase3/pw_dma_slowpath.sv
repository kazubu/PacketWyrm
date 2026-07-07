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
//     [39:32] ingress_local_port
//     [55:40] byte_len              (frame length in bytes, SAF-measured; LE)
//     [63:56] reserved
//
// Metadata note: the punt RX wire timestamp (s_punt_tuser rx_ts) is NOT carried
// in v1 (the 8-byte header holds lif_id + ingress + byte_len). If a future PTP
// servo needs punt timestamps, widen the header to 16 B (add a second beat) on both
// this module and the host parser.

`timescale 1ns / 1ps
`default_nettype none

module pw_dma_slowpath #(
    parameter int DP_DATA_W  = 64,
    parameter int XD_DATA_W  = 256,
    // Async-FIFO depth in BYTES (taxi FRAME_FIFO + DROP_OVERSIZE_FRAME: a frame
    // larger than DEPTH is dropped whole). 16384 holds a jumbo frame (MTU 9000 ~
    // 9018 B) + margin. (Was 2048 = ~2 KB, which silently capped punt/inject at
    // ~2 KB even though the MAC + data-plane SAF were widened for jumbo.) BRAM.
    parameter int FIFO_DEPTH = 16384,
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

    // Store-and-forward + length header (dp domain): buffer one punt frame while
    // counting its byte length, then emit a full 64-b in-band header beat followed
    // by the frame beats into the async FIFO (which upsizes 64->256 and packs the
    // header contiguously with the frame -- no partial-keep mid-stream beat, which
    // the header must be a full dp beat to avoid). The header carries the byte
    // length so the host sizes the frame WITHOUT parsing L2/L3 (VLAN/QinQ/unknown-
    // ethertype/LLDP all work). tuser = {rx_ts[63:0], ingress[3:0], lif_id[31:0]}.
    //   header: byte0-3 = lif_id (LE), byte4 = {4'b0, ingress}, byte5-6 = byte_len,
    //           byte7 = 0.
    localparam int PSAF_BEATS = 1280;                     // >= a jumbo frame (9600 B / 8)
    localparam int PAW = $clog2(PSAF_BEATS);
    (* ram_style = "block" *) logic [DP_DATA_W-1:0] psaf_d [PSAF_BEATS];
    (* ram_style = "block" *) logic [DP_KEEP_W-1:0] psaf_k [PSAF_BEATS];
    // PS_DROP: an oversize frame (more beats than PSAF_BEATS) is swallowed to
    // tlast and NOT emitted, so psaf_wr can never index past the BRAM. The MAC
    // ceiling (9599 B < PSAF_BEATS*8 = 10240 B) keeps this unreachable today; it
    // is a guard against a future cap change or a malformed stream.
    localparam logic [1:0] PS_FILL = 2'd0, PS_HDR = 2'd1, PS_DRAIN = 2'd2,
                           PS_DROP = 2'd3;
    logic [1:0]       psaf_st;
    logic [PAW-1:0]   psaf_wr, psaf_rd, psaf_n;   // n = beat count of the buffered frame
    logic [15:0]      psaf_len, psaf_len_acc;
    logic [31:0]      psaf_lif;
    logic [3:0]       psaf_ing;
    logic [DP_DATA_W-1:0] psaf_dq;                // registered BRAM read
    logic [DP_KEEP_W-1:0] psaf_kq;

    function automatic [4:0] keepcnt(input [DP_KEEP_W-1:0] k);
        keepcnt = '0;
        for (int i = 0; i < DP_KEEP_W; i++) if (k[i]) keepcnt = keepcnt + 5'd1;
    endfunction

    wire fill_acc  = (psaf_st == PS_FILL) && s_punt_tvalid;                 // s_punt accepted
    wire drop_acc  = (psaf_st == PS_DROP) && s_punt_tvalid;                 // oversize swallow
    wire hdr_acc   = (psaf_st == PS_HDR)  && punt_dp.tready;                // header beat accepted
    wire drain_acc = (psaf_st == PS_DRAIN) && punt_dp.tvalid && punt_dp.tready;
    // Read the address we will PRESENT next cycle (1-ahead so the registered BRAM
    // read stays aligned with psaf_rd).
    wire [PAW-1:0] rd_nxt = drain_acc ? (psaf_rd + 1'b1) : psaf_rd;

    always_ff @(posedge dp_clk) begin
        if (dp_rst) begin
            psaf_st <= PS_FILL; psaf_wr <= '0; psaf_rd <= '0; psaf_n <= '0;
            psaf_len_acc <= '0;
        end else begin
            case (psaf_st)
            PS_FILL: if (fill_acc) begin
                psaf_d[psaf_wr] <= s_punt_tdata;             // psaf_wr is in-range here
                psaf_k[psaf_wr] <= s_punt_tkeep;
                psaf_len_acc <= psaf_len_acc + 16'(keepcnt(s_punt_tkeep));
                if (s_punt_tlast) begin
                    psaf_n   <= psaf_wr;                     // last index (0..n = the beats)
                    psaf_len <= psaf_len_acc + 16'(keepcnt(s_punt_tkeep));
                    psaf_lif <= s_punt_tuser[31:0];
                    psaf_ing <= s_punt_tuser[35:32];
                    psaf_rd  <= '0;
                    psaf_st  <= PS_HDR;
                end else if (psaf_wr == PAW'(PSAF_BEATS - 1)) begin
                    psaf_st <= PS_DROP;                      // next beat would overflow -> drop
                end else begin
                    psaf_wr <= psaf_wr + 1'b1;
                end
            end
            // Swallow the rest of an oversize frame without emitting it, then
            // re-arm for the next frame (no desync).
            PS_DROP: if (drop_acc && s_punt_tlast) begin
                psaf_st <= PS_FILL; psaf_wr <= '0; psaf_len_acc <= '0;
            end
            PS_HDR: if (hdr_acc) psaf_st <= PS_DRAIN;
            PS_DRAIN: if (drain_acc) begin
                psaf_rd <= psaf_rd + 1'b1;
                if (psaf_rd == psaf_n) begin                 // last beat drained
                    psaf_st <= PS_FILL; psaf_wr <= '0; psaf_len_acc <= '0;
                end
            end
            default: psaf_st <= PS_FILL;
            endcase
        end
    end
    // Registered BRAM read, 1-ahead of psaf_rd (see rd_nxt). Primed during PS_HDR
    // (rd_nxt = psaf_rd = 0) so beat 0 is ready when PS_DRAIN begins.
    always_ff @(posedge dp_clk) begin
        psaf_dq <= psaf_d[rd_nxt];
        psaf_kq <= psaf_k[rd_nxt];
    end

    wire [DP_DATA_W-1:0] punt_hdr =
        { 8'b0, psaf_len, 4'b0, psaf_ing, psaf_lif };        // b0-3 lif, b4 ing, b5-6 len, b7 0

    assign s_punt_tready  = (psaf_st == PS_FILL) || (psaf_st == PS_DROP);
    assign punt_dp.tvalid = (psaf_st == PS_HDR) || (psaf_st == PS_DRAIN);
    assign punt_dp.tdata  = (psaf_st == PS_HDR) ? punt_hdr           : psaf_dq;
    assign punt_dp.tkeep  = (psaf_st == PS_HDR) ? {DP_KEEP_W{1'b1}}  : psaf_kq;
    assign punt_dp.tstrb  = punt_dp.tkeep;
    assign punt_dp.tlast  = (psaf_st == PS_DRAIN) && (psaf_rd == psaf_n);
    assign punt_dp.tid    = '0;
    assign punt_dp.tdest  = '0;
    assign punt_dp.tuser  = '0;

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
