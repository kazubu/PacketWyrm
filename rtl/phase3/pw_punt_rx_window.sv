// PacketWyrm punt / slow-path RX window (FPGA -> host, BAR-polled).
//
// Sinks the data plane's punt AXIS master (PUNT_TO_HOST / MIRROR_TO_HOST
// frames, already whole-frame buffered by pw_frame_saf) into a single-
// frame buffer the host drains over the CSR BAR. No DMA: the host polls
// PUNT_STATUS, reads the metadata + frame words, then writes PUNT_POP to
// release the slot. While a frame waits to be read, s_tready is low, so
// the SAF holds the next punt frame (head-of-line) -- fine for slow-path
// control traffic, which is occasional.
//
// All in the dp_clk domain (the punt AXIS and the clock-converted CSR
// read path share dp_clk, like the BRAM histogram).
//
// Window register map (offsets within the window; DATA is RO frame bytes
// as little-endian 32-bit words):
//   0x000 PUNT_STATUS  RO  bit0 = frame_valid (a frame is ready to read)
//                          bit1 = overflow    (a frame was dropped: too big)
//   0x004 PUNT_INFO    RO  [13:0]=byte_len   [19:16]=ingress_port
//   0x008 PUNT_LIF     RO  [31:0]=logical_if_id
//   0x00C PUNT_POP     WO  write 1 -> release the current frame
//   0x010.. PUNT_DATA  RO  frame word i at 0x010 + i*4
//
// All CSR reads are registered (1-cycle latency); pw_csr_full defers
// rvalid one cycle for this window (same as the histogram).

`default_nettype none

module pw_punt_rx_window #(
    parameter int ADDR_W    = 16,
    parameter int BUF_BEATS = 512,                 // 64-bit beats; 4 KB max frame
    parameter int DATA_OFF  = 16'h0010             // PUNT_DATA base offset
) (
    input  wire               clk,
    input  wire               rst_n,

    // Punt AXIS slave (from the data plane punt arbiter).
    input  wire [63:0]        s_tdata,
    input  wire [7:0]         s_tkeep,
    input  wire               s_tvalid,
    output wire               s_tready,
    input  wire               s_tlast,
    input  wire [35:0]        s_tuser,             // {ingress[3:0], logical_if_id[31:0]}

    // CSR read: addressed, registered (1-cycle). rd_addr_i is the offset
    // within this window. rd_data_o is valid the cycle after rd_en_i.
    input  wire               rd_en_i,
    input  wire [ADDR_W-1:0]  rd_addr_i,
    output logic [31:0]       rd_data_o,

    // CSR write: pop strobe (decoded in pw_csr_full from PUNT_POP).
    input  wire               pop_i,

    // status tap (optional; e.g. for an IRQ/telemetry later)
    output wire               frame_valid_o
);

    localparam int BAW = $clog2(BUF_BEATS);

    // 64-bit frame beat buffer (one frame at a time).
    (* ram_style = "block" *) logic [63:0] mem [BUF_BEATS];

    logic [BAW:0]   wbeat;        // write beat index (extra MSB to detect full)
    logic [13:0]    byte_len;     // accumulated valid bytes
    logic [31:0]    lif_q;        // logical_if_id of the captured frame
    logic [3:0]     ingress_q;    // ingress port of the captured frame
    logic           frame_valid;  // a frame is buffered, awaiting host read
    logic           overflow;     // sticky: a frame was dropped (did not fit)
    logic           dropping;     // current in-progress frame overflowed

    assign frame_valid_o = frame_valid;

    // Accept beats only while empty and the current frame still fits.
    wire accepting = !frame_valid;
    assign s_tready  = accepting;       // backpressure once a frame is buffered

    // popcount of tkeep (contiguous AXIS keep -> number of valid bytes)
    function automatic [3:0] kcount(input [7:0] k);
        kcount = k[0]+k[1]+k[2]+k[3]+k[4]+k[5]+k[6]+k[7];
    endfunction

    wire beat_we = accepting && s_tvalid && !dropping && (wbeat != BUF_BEATS[BAW:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wbeat       <= '0;
            byte_len    <= '0;
            lif_q       <= '0;
            ingress_q   <= '0;
            frame_valid <= 1'b0;
            overflow    <= 1'b0;
            dropping    <= 1'b0;
        end else begin
            if (accepting && s_tvalid) begin
                if (beat_we) begin
                    wbeat      <= wbeat + 1'b1;
                    byte_len   <= byte_len + 14'(kcount(s_tkeep));
                end else if (!dropping) begin
                    // No room for this beat -> drop the whole frame.
                    dropping <= 1'b1;
                end

                if (s_tlast) begin
                    if (dropping || !beat_we) begin
                        // overflowed: discard, reset for next frame
                        overflow  <= 1'b1;
                        wbeat     <= '0;
                        byte_len  <= '0;
                        dropping  <= 1'b0;
                    end else begin
                        // whole frame captured -> publish for the host
                        frame_valid <= 1'b1;
                        lif_q       <= s_tuser[31:0];
                        ingress_q   <= s_tuser[35:32];
                    end
                end
            end

            // Host released the frame -> free the slot.
            if (pop_i && frame_valid) begin
                frame_valid <= 1'b0;
                wbeat       <= '0;
                byte_len    <= '0;
            end
        end
    end

    // The frame buffer WRITE port lives in its own reset-less clocked block
    // so the BRAM infers (a RAM in a block with an async reset is forced to
    // flip-flops -- which blew this 2 KB buffer up into 16k FFs + a 256:1
    // mux and wrecked dp_clk timing).
    always_ff @(posedge clk) begin
        if (beat_we) mem[wbeat[BAW-1:0]] <= s_tdata;
    end

    // CSR read (1-cycle latency). The frame buffer read must stay a clean,
    // unconditional registered read so it infers as BRAM (an earlier version
    // gated mem reads inside a case with the header regs, which forced the
    // 2 KB buffer into ~16k flip-flops + a 256:1 mux and blew up timing).
    // So: read the BRAM unconditionally into bram_q, register the header
    // value + the data/half select in parallel, and mux them combinationally
    // on the output (all aligned at the same 1-cycle latency).
    wire [ADDR_W-1:0] data_word = (rd_addr_i - DATA_OFF[ADDR_W-1:0]) >> 2;  // word index
    wire [BAW-1:0]    rd_beat   = data_word[BAW:1];
    wire              rd_half   = data_word[0];

    logic [63:0] bram_q;          // dedicated registered BRAM read
    logic [31:0] hdr_q;           // registered header-register value
    logic        is_data_q;       // was the address in the DATA region?
    logic        half_q;

    always_ff @(posedge clk) begin
        bram_q    <= mem[rd_beat];                       // clean BRAM read port
        half_q    <= rd_half;
        is_data_q <= (rd_addr_i >= DATA_OFF[ADDR_W-1:0]);
        case (rd_addr_i[7:0])
            8'h00:   hdr_q <= {30'b0, overflow, frame_valid};
            8'h04:   hdr_q <= {12'b0, ingress_q, 2'b0, byte_len};
            8'h08:   hdr_q <= lif_q;
            default: hdr_q <= 32'h0;
        endcase
    end

    assign rd_data_o = is_data_q ? (half_q ? bram_q[63:32] : bram_q[31:0]) : hdr_q;

    // rd_en_i is unused (the read is always live, like the histogram BRAM);
    // keep the port for interface symmetry.
    wire _unused_rd_en = rd_en_i;

endmodule

`default_nettype wire
