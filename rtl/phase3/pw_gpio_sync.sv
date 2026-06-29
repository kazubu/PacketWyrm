// Cross-card time-sync over the board's J5 GPIO (daisy-chain).
//
// PacketWyrm's free-running 64-bit timestamp counter is card-LOCAL: two cards'
// counters share neither phase nor frequency, so a latency measured on card A
// against a tx_timestamp from card B is meaningless. Rather than discipline the
// HW counter to a shared time base (a *stepping* counter would break the Gray-
// coded CDC that pw_ts_insert relies on -- see hw-architecture-freeze), this
// shares a clean hardware SYNC EDGE between cards and lets software correct the
// raw timestamps:
//
//   * One card is the MASTER: it drives a periodic pulse out a J5 GPIO pin.
//   * Every card (master included) LATCHES its own free-running counter at the
//     rising edge of that pulse and bumps an edge sequence number. Latching is a
//     read -- the counter itself is never disturbed -- so the Gray CDC is safe.
//   * A mid-chain card can REPEAT the pulse out a second pin to the next card
//     (daisy-chain); the per-hop trace/cable delay is fixed and calibratable.
//
// Software then reads each card's {latched timestamp, edge seq}: matching edge
// numbers across cards gives the inter-card counter OFFSET at that instant, and
// successive edges give the relative rate (skew). The servo that turns these
// into corrected cross-card latencies lives in software (needs >= 2 cards).
//
// Precision floor: the counter granularity (1 dp_clk tick = 6.4 ns at
// 156.25 MHz) plus the 2-FF input synchroniser's <=1-cycle metastability jitter.
// The synchroniser's nominal latency is identical on every card, so it cancels
// in the inter-card offset; only the +-1-cycle jitter and the (calibratable)
// wire delay remain. Software can average many edges to push below a tick.
//
// The GPIO pins are bidirectional at the pad (IOBUF in the board top); this
// module drives gpio_o/gpio_t and consumes gpio_i. Only the configured sync-out
// pin is driven (gpio_t low); every other pin is left hi-Z (gpio_t high) so the
// same bitstream works as master, slave, or repeater by CSR config alone.

`default_nettype none

module pw_gpio_sync #(
    parameter int NGPIO = 6
) (
    input  wire                  clk,        // dp_clk (same domain as timestamp_i)
    input  wire                  rst_n,
    input  wire [63:0]           timestamp_i,// free-running card-local counter

    // GPIO pad interface (to/from the board-top IOBUFs).
    input  wire [NGPIO-1:0]      gpio_i,     // ASYNC pad inputs
    output logic [NGPIO-1:0]     gpio_o,     // pad output value
    output logic [NGPIO-1:0]     gpio_t,     // pad tri-state (1 = input / hi-Z)

    // CSR control (quasi-static, written from the AXI/dp domain by pw_csr_full).
    //   [0]     enable
    //   [1]     master   (1 = originate the pulse, 0 = listen only)
    //   [2]     repeat   (re-drive the incoming edge out the sync-out pin)
    //   [6:4]   in_sel   (sync-in  pin index, 0..NGPIO-1)
    //   [10:8]  out_sel  (sync-out pin index, 0..NGPIO-1)
    //   [19:16] period_log2 (master pulse every 2^period_log2 dp_clk cycles)
    input  wire [31:0]           ctrl_i,

    // CSR status (read back by software).
    output logic [63:0]          sync_ts_o,  // counter latched at the last edge
    output logic [31:0]          sync_seq_o, // edge count since reset (matches across cards)
    output logic [NGPIO-1:0]     gpio_in_o   // raw synchronised pad inputs (debug)
);
    localparam int PW = 16;     // sync-out pulse width in dp_clk cycles (>= a few
                                // dst-clock samples so the far card reliably catches it)

    // ---- config unpack ----
    wire        en       = ctrl_i[0];
    wire        master   = ctrl_i[1];
    wire        repeat_en= ctrl_i[2];
    wire [2:0]  in_sel   = ctrl_i[6:4];
    wire [2:0]  out_sel  = ctrl_i[10:8];
    wire [3:0]  per_log2 = ctrl_i[19:16];

    // Pin-select sanity: the fields are 3-bit but only NGPIO pins exist. Guard
    // both the variable read and the variable drive against an out-of-range
    // index (clamp the index to 0 and gate the use), so a stray 6/7 can't X-out
    // the sim or infer a bogus mux. in/out must be valid to capture/drive.
    wire        in_ok    = (in_sel  < NGPIO[2:0]);
    wire        out_ok   = (out_sel < NGPIO[2:0]);
    wire [2:0]  in_idx   = in_ok  ? in_sel  : 3'd0;
    wire [2:0]  out_idx  = out_ok ? out_sel : 3'd0;

    // Effective master period: the outgoing pulse is PW cycles HIGH, so the
    // period must leave a LOW gap or the far card never sees a fresh rising
    // edge. Clamp 2^per_log2 to a floor of 2*PW (>= PW high + PW low). With
    // PW=16 that means a minimum period of 32 cycles (per_log2 >= 5 effective).
    wire [3:0]  per_eff  = (per_log2 < 4'd5) ? 4'd5 : per_log2;

    // ---- 2-FF input synchronisers on every pad (async -> dp_clk) ----
    (* ASYNC_REG = "TRUE" *) logic [NGPIO-1:0] gi_s1, gi_s2;
    logic [NGPIO-1:0] gi_d;     // one more for edge detect
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin gi_s1 <= '0; gi_s2 <= '0; gi_d <= '0; end
        else        begin gi_s1 <= gpio_i; gi_s2 <= gi_s1; gi_d <= gi_s2; end
    end
    assign gpio_in_o = gi_s2;

    // selected sync-in, synchronised; rising edge = the shared sync event
    wire sync_in_lvl  = in_ok & gi_s2[in_idx];
    wire sync_in_d    = in_ok & gi_d[in_idx];
    wire sync_in_rise = sync_in_lvl & ~sync_in_d;

    // ---- master pulse generator (period down-counter on dp_clk) ----
    // Fires for 1 cycle every 2^per_eff cycles; that tick starts the outgoing
    // pulse. The master's own LATCH event is the actual pad rise (see capture
    // below), not this tick, so the recorded time matches the edge it emits.
    logic [31:0] per_cnt;
    logic        m_tick;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin per_cnt <= '0; m_tick <= 1'b0; end
        else begin
            m_tick <= 1'b0;
            if (en && master) begin
                if (per_cnt >= ((32'h1 << per_eff) - 1)) begin
                    per_cnt <= '0;
                    m_tick  <= 1'b1;
                end else begin
                    per_cnt <= per_cnt + 1'b1;
                end
            end else begin
                per_cnt <= '0;
            end
        end
    end

    // ---- outgoing pulse shaper (master originate OR repeater forward) ----
    logic [$clog2(PW+1)-1:0] pulse_cnt;
    logic                    pulse_active, pulse_active_q;
    wire                     out_trigger = (en && master   && m_tick)
                                         | (en && repeat_en && sync_in_rise);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pulse_cnt <= '0; pulse_active <= 1'b0; pulse_active_q <= 1'b0; end
        else begin
            pulse_active_q <= pulse_active;
            if (out_trigger) begin
                pulse_active <= 1'b1;
                pulse_cnt    <= PW[$clog2(PW+1)-1:0];
            end else if (pulse_active) begin
                if (pulse_cnt <= 1) pulse_active <= 1'b0;
                pulse_cnt <= pulse_cnt - 1'b1;
            end
        end
    end
    // pad rises the cycle pulse_active goes high -- the true emit edge.
    wire pulse_rise = pulse_active & ~pulse_active_q;

    // ---- drive the sync-out pin ONLY when this card originates/forwards ----
    // A pure listener (master=0, repeat=0) leaves every pin hi-Z so it never
    // fights the upstream pulse (e.g. a mis-set in_sel==out_sel).
    wire drive_out = en && (master || repeat_en) && out_ok;
    always_comb begin
        gpio_o = '0;
        gpio_t = '1;                       // default: all inputs / hi-Z
        if (drive_out) begin
            gpio_t[out_idx] = 1'b0;        // drive the sync-out pin
            gpio_o[out_idx] = pulse_active;
        end
    end

    // ---- the capture: latch the counter + bump the sequence at each edge ----
    // Master: at its own pad RISE (pulse_rise) -- so it records the counter at
    // the instant the edge actually leaves the pin, matching the slaves.
    // Listener/repeater: at the synchronised rising edge on the sync-in pin.
    wire capture = en & ((master & pulse_rise) | (~master & sync_in_rise));
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_ts_o <= '0; sync_seq_o <= '0;
        end else if (capture) begin
            sync_ts_o  <= timestamp_i;     // READ only -- counter undisturbed
            sync_seq_o <= sync_seq_o + 1'b1;
        end
    end

endmodule

`default_nettype wire
