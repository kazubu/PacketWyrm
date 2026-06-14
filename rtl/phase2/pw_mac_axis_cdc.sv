// PacketWyrm: per-port AXIS clock-domain crossing between the SFP+ MAC
// (per-port rx_clk / tx_clk, ~156 MHz) and a single data-plane clock.
//
// The Phase 3 data plane (pwfpga_top_phase3) is a single-clock design;
// the Taxi MAC delivers RX / accepts TX in the GT-derived per-port clock
// domains. This wraps a pair of Taxi async FIFOs per port (RX: rx_clk ->
// dp_clk, TX: dp_clk -> tx_clk) in frame-FIFO mode, presenting flat
// 64-bit AXIS on both sides. CERN-OHL-S (Taxi); see top-level LICENSE.

`default_nettype none

module pw_mac_axis_cdc #(
    parameter int PORTS  = 2,
    parameter int DATA_W = 64,
    parameter int DEPTH  = 1024
) (
    input  wire logic              dp_clk,
    input  wire logic              dp_rst,

    // MAC per-port clocks
    input  wire logic              rx_clk [PORTS],
    input  wire logic              rx_rst [PORTS],
    input  wire logic              tx_clk [PORTS],
    input  wire logic              tx_rst [PORTS],

    // MAC RX (rx_clk) flat in  <- pw_sfp_10g
    input  wire logic [DATA_W-1:0]   mac_rx_tdata  [PORTS],
    input  wire logic [DATA_W/8-1:0] mac_rx_tkeep  [PORTS],
    input  wire logic                mac_rx_tvalid [PORTS],
    input  wire logic                mac_rx_tlast  [PORTS],
    input  wire logic                mac_rx_tuser  [PORTS],

    // MAC TX (tx_clk) flat out -> pw_sfp_10g
    output wire logic [DATA_W-1:0]   mac_tx_tdata  [PORTS],
    output wire logic [DATA_W/8-1:0] mac_tx_tkeep  [PORTS],
    output wire logic                mac_tx_tvalid [PORTS],
    input  wire logic                mac_tx_tready [PORTS],
    output wire logic                mac_tx_tlast  [PORTS],
    output wire logic                mac_tx_tuser  [PORTS],

    // Data-plane side (dp_clk): RX out to data plane
    output wire logic [DATA_W-1:0]   dp_rx_tdata  [PORTS],
    output wire logic [DATA_W/8-1:0] dp_rx_tkeep  [PORTS],
    output wire logic                dp_rx_tvalid [PORTS],
    input  wire logic                dp_rx_tready [PORTS],
    output wire logic                dp_rx_tlast  [PORTS],
    output wire logic                dp_rx_tuser  [PORTS],

    // Data-plane side (dp_clk): TX in from data plane
    input  wire logic [DATA_W-1:0]   dp_tx_tdata  [PORTS],
    input  wire logic [DATA_W/8-1:0] dp_tx_tkeep  [PORTS],
    input  wire logic                dp_tx_tvalid [PORTS],
    output wire logic                dp_tx_tready [PORTS],
    input  wire logic                dp_tx_tlast  [PORTS],
    input  wire logic                dp_tx_tuser  [PORTS]
);

    for (genvar p = 0; p < PORTS; p++) begin : g_cdc

        taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) rx_s ();
        taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) rx_m ();
        taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) tx_s ();
        taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) tx_m ();

        // ---- RX: MAC(rx_clk) -> data plane(dp_clk) ----
        assign rx_s.tdata  = mac_rx_tdata[p];
        assign rx_s.tkeep  = mac_rx_tkeep[p];
        assign rx_s.tvalid = mac_rx_tvalid[p];
        assign rx_s.tlast  = mac_rx_tlast[p];
        assign rx_s.tuser  = mac_rx_tuser[p];
        assign rx_s.tid    = '0;
        assign rx_s.tdest  = '0;
        assign rx_s.tstrb  = '0;
        // MAC RX has no backpressure; FIFO frame-drops if it ever fills.

        taxi_axis_async_fifo #(
            .DEPTH(DEPTH), .FRAME_FIFO(1'b1), .DROP_OVERSIZE_FRAME(1'b1),
            .DROP_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1)
        ) u_rx_fifo (
            .s_clk(rx_clk[p]), .s_rst(rx_rst[p]), .s_axis(rx_s),
            .m_clk(dp_clk),    .m_rst(dp_rst),    .m_axis(rx_m),
            .s_pause_ack(), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );

        assign dp_rx_tdata[p]  = rx_m.tdata;
        assign dp_rx_tkeep[p]  = rx_m.tkeep;
        assign dp_rx_tvalid[p] = rx_m.tvalid;
        assign dp_rx_tlast[p]  = rx_m.tlast;
        assign dp_rx_tuser[p]  = rx_m.tuser;
        assign rx_m.tready     = dp_rx_tready[p];

        // ---- TX: data plane(dp_clk) -> MAC(tx_clk) ----
        assign tx_s.tdata  = dp_tx_tdata[p];
        assign tx_s.tkeep  = dp_tx_tkeep[p];
        assign tx_s.tvalid = dp_tx_tvalid[p];
        assign tx_s.tlast  = dp_tx_tlast[p];
        assign tx_s.tuser  = dp_tx_tuser[p];
        assign tx_s.tid    = '0;
        assign tx_s.tdest  = '0;
        assign tx_s.tstrb  = '0;
        assign dp_tx_tready[p] = tx_s.tready;

        taxi_axis_async_fifo #(
            .DEPTH(DEPTH), .FRAME_FIFO(1'b1)
        ) u_tx_fifo (
            .s_clk(dp_clk),    .s_rst(dp_rst),    .s_axis(tx_s),
            .m_clk(tx_clk[p]), .m_rst(tx_rst[p]), .m_axis(tx_m),
            .s_pause_ack(), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );

        assign mac_tx_tdata[p]  = tx_m.tdata;
        assign mac_tx_tkeep[p]  = tx_m.tkeep;
        assign mac_tx_tvalid[p] = tx_m.tvalid;
        assign mac_tx_tlast[p]  = tx_m.tlast;
        assign mac_tx_tuser[p]  = tx_m.tuser;
        assign tx_m.tready      = mac_tx_tready[p];
    end

endmodule

`default_nettype wire
