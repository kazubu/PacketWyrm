// PacketWyrm slow-path TX inject window (host -> FPGA, BAR-driven).
//
// The complement of pw_punt_rx_window: the host composes a frame in a CSR
// buffer, sets its length + egress port, and writes GO; the window emits
// it as a 64-bit AXIS master into the data plane, which mixes it into the
// chosen egress port's TX arbiter (priority between forwarded frames and
// the test generator). One frame in flight at a time (busy gates GO).
//
// Slow-path / control traffic only -> a small 512 B max frame, so the
// buffer fits the free CSR region below the table windows without a DMA
// ring. Larger injects are rejected (len clamped).
//
// All in the dp_clk domain (CSR writes are clock-converted to dp_clk
// before pw_csr_full, same as the rest of the data plane).
//
// Register map (offsets within the window):
//   0x000 INJECT_CTRL   W:[0]go        R:[0]busy
//   0x004 INJECT_INFO   W:[13:0]byte_len [19:16]egress_port
//   0x040.. INJECT_DATA W: frame word i at +i*4 (little-endian)
//
// The host writes DATA words in order (0,1,2,...); each even/odd pair
// forms one 64-bit beat. byte_len picks the valid bytes of the last beat.

`default_nettype none

module pw_inject_tx_window #(
    parameter int ADDR_W   = 16,
    parameter int BUF_BYTES = 512,
    parameter int CTRL_OFF = 16'h0000,
    parameter int INFO_OFF = 16'h0004,
    parameter int DATA_OFF = 16'h0040
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [63:0]        timestamp_i,    // free-running counter (egress TX timestamp)

    // CSR write (broadcast window strobe from pw_csr_full).
    input  wire               wr_en,
    input  wire [ADDR_W-1:0]  wr_addr,        // offset within this window
    input  wire [31:0]        wr_data,

    // CSR read (status; combinational).
    input  wire [ADDR_W-1:0]  rd_addr,        // offset within this window
    output logic [31:0]       rd_data,

    // AXIS master into the data plane egress mux.
    output logic [63:0]       m_tdata,
    output logic [7:0]        m_tkeep,
    output logic              m_tvalid,
    input  wire               m_tready,
    output logic              m_tlast,
    output logic [3:0]        egress_o        // target egress port (valid while busy)
);

    localparam int BEATS = BUF_BYTES / 8;          // 64 beats
    localparam int BAW   = $clog2(BEATS);

    // Frame buffer (64-bit beats). Small -> kept in registers (a 64-entry
    // array, unlike the 256-entry punt buffer that had to be BRAM).
    logic [63:0] mem [BEATS];

    logic [13:0] byte_len;
    logic [3:0]  egress_q;
    logic        busy;

    // ---- CSR writes: DATA buffer + INFO + GO ----
    // Each 32-bit word maps to one half of a 64-bit beat: even word ->
    // low half, odd word -> high half. The buffer is a register array, so
    // write each half directly (no low-word latch). This matters for a
    // frame whose last beat has only its low word written (odd word count):
    // a latch-then-commit-on-odd scheme would strand that last low word.
    wire        is_data = (wr_addr >= DATA_OFF[ADDR_W-1:0]);
    wire [ADDR_W-1:0] wword = (wr_addr - DATA_OFF[ADDR_W-1:0]) >> 2;  // word index

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_len <= '0;
            egress_q <= '0;
        end else begin
            if (wr_en && !busy) begin
                if (is_data) begin
                    if (!wword[0]) mem[wword[BAW:1]][31:0]  <= wr_data;  // even -> low half
                    else           mem[wword[BAW:1]][63:32] <= wr_data;  // odd -> high half
                end else if (wr_addr == INFO_OFF[ADDR_W-1:0]) begin
                    byte_len <= wr_data[13:0];
                    egress_q <= wr_data[19:16];
                end
            end
        end
    end

    // ---- emit FSM ----
    logic [BAW:0]  rbeat;       // current beat index (extra bit for compare)
    logic [BAW:0]  nbeats;      // total beats = ceil(byte_len/8)
    logic [63:0]   beat_q;      // registered read of mem[rbeat]
    logic [2:0]    last_valid;  // valid bytes in the last beat (1..8) -> tkeep
    logic [63:0]   tx_ts;       // egress wire timestamp (latched at the frame's first beat)
    wire           go = wr_en && !busy && (wr_addr == CTRL_OFF[ADDR_W-1:0]) && wr_data[0];

    wire           is_last = (rbeat + 1'b1 == nbeats);
    // last_valid: 1..7 = partial last beat; 0 = last beat is full (8 bytes).
    wire [7:0]     last_keep = (last_valid == 3'd0) ? 8'hFF
                                                    : (8'hFF >> (4'd8 - {1'b0, last_valid}));

    assign m_tdata  = beat_q;
    assign m_tkeep  = is_last ? last_keep : 8'hFF;
    assign m_tvalid = busy;
    assign m_tlast  = is_last;
    assign egress_o = egress_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            rbeat  <= '0;
            nbeats <= '0;
            beat_q <= '0;
            last_valid <= 3'd0;
            tx_ts  <= '0;
        end else begin
            // Latch the egress timestamp at the frame's first accepted beat
            // (servo-facing TX-event time, e.g. a PTP Delay_Req departure).
            if (busy && m_tvalid && m_tready && (rbeat == '0)) tx_ts <= timestamp_i;
            if (!busy) begin
                if (go && byte_len != 0) begin
                    busy       <= 1'b1;
                    rbeat      <= '0;
                    nbeats     <= ({1'b0, byte_len} + 14'd7) >> 3;       // ceil(len/8)
                    last_valid <= (byte_len[2:0] == 3'd0) ? 3'd0        // 0 => full 8
                                                          : byte_len[2:0];
                    beat_q     <= mem[0];                                // preload beat 0
                end
            end else begin
                if (m_tvalid && m_tready) begin
                    if (is_last) begin
                        busy <= 1'b0;                                    // frame sent
                    end else begin
                        rbeat  <= rbeat + 1'b1;
                        beat_q <= mem[rbeat[BAW-1:0] + 1'b1];            // next beat
                    end
                end
            end
        end
    end

    // status read (combinational): only CTRL[0]=busy is meaningful.
    always_comb begin
        rd_data = 32'h0;
        if      (rd_addr == CTRL_OFF[ADDR_W-1:0]) rd_data = {31'b0, busy};
        else if (rd_addr == 16'h008)              rd_data = tx_ts[31:0];   // egress TS low
        else if (rd_addr == 16'h00C)              rd_data = tx_ts[63:32];  //            high
    end

endmodule

`default_nettype wire
