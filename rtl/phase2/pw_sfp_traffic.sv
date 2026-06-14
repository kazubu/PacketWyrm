// PacketWyrm Phase 2: minimal per-port SFP traffic engine.
//
// Per port:
//   - RX frame counter (rx_clk): counts frames delivered by the MAC.
//   - TX template sender (tx_clk): when enabled, emits a fixed 64-byte
//     frame back-to-back at line rate (the MAC appends the FCS and
//     enforces IFG). Phase 2 only needs "send copies of a template",
//     so the content is a fixed pattern -- the RX side just counts.
//   - TX frame counter (tx_clk).
//
// The counters are Gray-code CDC'd into the AXI (CSR) clock domain so
// the host can read them, and tx_enable is synchronised into tx_clk.
// This is the line-rate loopback instrument for the Phase 2 DoD: drive
// a DAC between the two SFP+ ports, enable TX, and confirm the RX count
// on the far port tracks the TX count with zero loss.

`default_nettype none

module pw_sfp_traffic #(
    parameter int PORTS  = 2,
    parameter int DATA_W = 64,
    parameter int BEATS  = 8          // 8 x 64b = 64-byte frame (pre-FCS)
) (
    input  wire logic              axi_clk,
    input  wire logic              axi_rst,

    // Control (axi_clk domain): per-port TX enable, bit p = port p
    input  wire logic [PORTS-1:0]  tx_enable,

    // Counters read out in axi_clk domain
    output wire logic [31:0]       rx_frames [PORTS],
    output wire logic [31:0]       tx_frames [PORTS],

    // Per-port MAC clocks
    input  wire logic              tx_clk [PORTS],
    input  wire logic              tx_rst [PORTS],
    input  wire logic              rx_clk [PORTS],
    input  wire logic              rx_rst [PORTS],

    // Flat TX AXIS to the MAC (tx_clk domain)
    output wire logic [DATA_W-1:0]   tx_tdata  [PORTS],
    output wire logic [DATA_W/8-1:0] tx_tkeep  [PORTS],
    output wire logic                tx_tvalid [PORTS],
    input  wire logic                tx_tready [PORTS],
    output wire logic                tx_tlast  [PORTS],
    output wire logic                tx_tuser  [PORTS],

    // Flat RX AXIS from the MAC (rx_clk domain)
    input  wire logic                rx_tvalid [PORTS],
    input  wire logic                rx_tlast  [PORTS],
    input  wire logic                rx_tuser  [PORTS]
);

    // binary -> Gray
    function automatic logic [31:0] bin2gray(input logic [31:0] b);
        return b ^ (b >> 1);
    endfunction
    // Gray -> binary
    function automatic logic [31:0] gray2bin(input logic [31:0] g);
        logic [31:0] b;
        b[31] = g[31];
        for (int i = 30; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    for (genvar p = 0; p < PORTS; p++) begin : g_port

        // --- tx_enable sync into tx_clk -----------------------------------
        logic [1:0] txen_sync;
        always_ff @(posedge tx_clk[p]) begin
            txen_sync <= {txen_sync[0], tx_enable[p]};
        end
        wire txen_t = txen_sync[1];

        // --- TX template FSM (tx_clk) -------------------------------------
        localparam logic [$clog2(BEATS):0] LAST = ($clog2(BEATS)+1)'(BEATS - 1);
        logic [$clog2(BEATS):0] beat;
        logic                   active;
        logic [31:0]            txcnt;

        always_ff @(posedge tx_clk[p]) begin
            if (tx_rst[p]) begin
                beat   <= '0;
                active <= 1'b0;
                txcnt  <= '0;
            end else begin
                if (!active) begin
                    if (txen_t) begin active <= 1'b1; beat <= '0; end
                end else if (tx_tready[p]) begin
                    if (beat == LAST) begin
                        txcnt <= txcnt + 1;
                        // continue streaming while enabled, else stop
                        active <= txen_t;
                        beat   <= '0;
                    end else begin
                        beat <= beat + 1;
                    end
                end
            end
        end

        assign tx_tvalid[p] = active;
        assign tx_tlast[p]  = active && (beat == LAST);
        assign tx_tkeep[p]  = '1;
        assign tx_tuser[p]  = 1'b0;
        // Fixed, recognisable pattern; first beat carries a broadcast-ish
        // dst so the far MAC accepts it. Content is irrelevant to counting.
        assign tx_tdata[p]  = (beat == 0) ? 64'hA5A5_0001_FFFF_FFFF
                                          : {56'(beat), 8'hA5};

        // --- RX frame counter (rx_clk) ------------------------------------
        logic [31:0] rxcnt;
        always_ff @(posedge rx_clk[p]) begin
            if (rx_rst[p]) rxcnt <= '0;
            else if (rx_tvalid[p] && rx_tlast[p]) rxcnt <= rxcnt + 1;
        end

        // --- Gray-code CDC of both counters into axi_clk ------------------
        logic [31:0] rx_gray_tx, tx_gray_tx;   // gray in source domain
        always_ff @(posedge rx_clk[p]) rx_gray_tx <= bin2gray(rxcnt);
        always_ff @(posedge tx_clk[p]) tx_gray_tx <= bin2gray(txcnt);

        (* ASYNC_REG = "TRUE" *) logic [31:0] rx_g1, rx_g2, tx_g1, tx_g2;
        always_ff @(posedge axi_clk) begin
            rx_g1 <= rx_gray_tx; rx_g2 <= rx_g1;
            tx_g1 <= tx_gray_tx; tx_g2 <= tx_g1;
        end

        assign rx_frames[p] = gray2bin(rx_g2);
        assign tx_frames[p] = gray2bin(tx_g2);
    end

endmodule

`default_nettype wire
