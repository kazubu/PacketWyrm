// PacketWyrm BRAM-backed latency histogram.
//
// Stores the per-flow power-of-two latency distribution in a single
// shared block RAM instead of flip-flops, so NUM_FLOWS can scale far
// past the ~8 the FF-based histogram allowed (the histogram was the
// dominant FF consumer in the data plane).
//
// Memory layout: one 64-bit counter per (flow, bucket), flat-indexed
//   addr = flow * NUM_BUCKETS + bucket
//
// It is fed by registered histogram *events* from each ingress port's
// RX checker -- one event per counted TEST_RX frame, carrying the
// flow id and the (already computed) log2 latency bucket. The events
// are accumulated read-modify-write into the BRAM. The host reads the
// distribution live through an independent registered read port.
//
// BRAM port usage (true dual-port, 1 write + extra reads):
//   * Port A : the accumulate engine -- a two-phase read-then-write
//              RMW, and the clear walk. One physical address port,
//              read on one cycle, write on the next, so the engine
//              retires one event every two cycles. That is far above
//              the worst-case event rate: each port emits at most one
//              event per Ethernet frame (>= ~9 cycles for a 64-byte
//              frame at 64 bits/cycle), so two ports together stay
//              well under one event every two cycles.
//   * Port B : the host read port (rd_addr_i -> rd_data_o), fully
//              independent of the accumulate engine.
//
// Hazards / assumptions (documented):
//   * Same-address back-to-back RMW would read stale data. It cannot
//     happen here: a given flow's RX lands on exactly one ingress
//     port, so the two event streams never target the same flow, and
//     a single port cannot emit two events for the same flow within
//     the two-cycle RMW window (frame spacing). Different addresses
//     have no hazard.
//   * The clear walk (NUM_FLOWS*NUM_BUCKETS cycles) pauses accumulate
//     and drops any events that arrive during it. Clear is driven by
//     the `test arm` CSR write, which coincides with reprogramming /
//     no traffic, so no live samples are lost.
//   * The host read is live (not an atomic snapshot across buckets);
//     acceptable for a distribution. The loss / min / max counters
//     that must be atomic stay in the checker's flip-flops.

`default_nettype none

module pw_lat_histogram #(
    parameter int NUM_FLOWS   = 8,
    parameter int NUM_BUCKETS = 16,    // power-of-2 latency buckets
    parameter int N_EV        = 2,     // number of event sources (ingress ports)
    parameter int RD_ADDR_W   = 16     // host read address bus width
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // Synchronous clear: walk the whole array back to zero. Also
    // performed once automatically after reset (BRAM has no reset).
    input  wire                   clear_i,

    // Registered histogram events, one bus per ingress port.
    input  wire                   ev_valid_i  [N_EV],
    input  wire [15:0]            ev_flow_i   [N_EV],
    input  wire [15:0]            ev_bucket_i [N_EV],

    // Host read port: flat (flow*NUM_BUCKETS+bucket) address in,
    // registered 64-bit count out (1-cycle latency).
    input  wire [RD_ADDR_W-1:0]   rd_addr_i,
    output logic [63:0]           rd_data_o
);

    localparam int DEPTH = NUM_FLOWS * NUM_BUCKETS;
    localparam int AW    = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int RRW   = (N_EV  <= 1) ? 1 : $clog2(N_EV);

    // ---- the storage --------------------------------------------------
    (* ram_style = "block" *) logic [63:0] mem [DEPTH];
    logic [63:0] doutA;   // port A read data (accumulate engine)
    logic [63:0] doutB;   // port B read data (host)

    // ---- per-source pending event holders -----------------------------
    // One in-flight event per source; round-robin drained by the engine.
    // Frame spacing guarantees a holder is drained long before the same
    // source produces its next event, so a depth of one cannot overflow.
    logic            hv [N_EV];
    logic [AW-1:0]   ha [N_EV];
    logic [RRW-1:0]  rr;

    // Flat address of each source's incoming event.
    logic [AW-1:0]   ev_flat [N_EV];
    always_comb begin
        for (int s = 0; s < N_EV; s++)
            ev_flat[s] = AW'(ev_flow_i[s] * NUM_BUCKETS + ev_bucket_i[s]);
    end

    // Round-robin pick among pending sources, starting at rr.
    logic           sel_v;
    logic [RRW-1:0] sel_idx;
    logic [AW-1:0]  sel_addr;
    always_comb begin
        sel_v    = 1'b0;
        sel_idx  = '0;
        for (int k = 0; k < N_EV; k++) begin
            automatic int idx = (int'(rr) + k) % N_EV;
            if (!sel_v && hv[idx]) begin
                sel_v   = 1'b1;
                sel_idx = RRW'(idx);
            end
        end
        sel_addr = ha[sel_idx];
    end

    // ---- accumulate / clear engine ------------------------------------
    typedef enum logic [1:0] { ST_CLEAR, ST_READ, ST_WRITE } state_e;
    state_e        state;
    logic [AW:0]   clr_addr;
    logic [AW-1:0] eng_addr;

    // Port A address / write controls (combinational).
    logic [AW-1:0] addrA;
    logic          weA;
    logic [63:0]   dinA;
    always_comb begin
        addrA = eng_addr;
        weA   = 1'b0;
        dinA  = '0;
        unique case (state)
            ST_CLEAR: begin addrA = clr_addr[AW-1:0]; weA = 1'b1; dinA = '0;        end
            ST_READ:  begin addrA = sel_addr;          weA = 1'b0;                    end
            ST_WRITE: begin addrA = eng_addr;          weA = 1'b1; dinA = doutA + 64'd1; end
            default:  ;
        endcase
    end

    // BRAM: port A (RMW + clear) with read-back, port B (host read).
    always_ff @(posedge clk) begin
        if (weA) mem[addrA] <= dinA;
        doutA <= mem[addrA];
        doutB <= mem[rd_addr_i[AW-1:0]];
    end
    assign rd_data_o = doutB;

    // Engine FSM + pending-event bookkeeping.
    logic consume [N_EV];
    always_comb begin
        for (int s = 0; s < N_EV; s++)
            consume[s] = (state == ST_READ) && sel_v && (sel_idx == RRW'(s));
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_CLEAR;
            clr_addr <= '0;
            eng_addr <= '0;
            rr       <= '0;
            for (int s = 0; s < N_EV; s++) begin
                hv[s] <= 1'b0;
                ha[s] <= '0;
            end
        end else begin
            // Restart a clear walk on the soft-clear pulse.
            if (clear_i && state != ST_CLEAR) begin
                state    <= ST_CLEAR;
                clr_addr <= '0;
            end else begin
                unique case (state)
                    ST_CLEAR: begin
                        if (clr_addr == (DEPTH - 1)) begin
                            state    <= ST_READ;
                            clr_addr <= '0;
                        end else begin
                            clr_addr <= clr_addr + 1'b1;
                        end
                    end
                    ST_READ: begin
                        if (sel_v) begin
                            eng_addr <= sel_addr;
                            rr       <= RRW'((int'(sel_idx) + 1) % N_EV);
                            state    <= ST_WRITE;
                        end
                    end
                    ST_WRITE: begin
                        state <= ST_READ;
                    end
                    default: state <= ST_READ;
                endcase
            end

            // Pending-event holders. Drop incoming events while clearing.
            for (int s = 0; s < N_EV; s++) begin
                if (state == ST_CLEAR) begin
                    hv[s] <= 1'b0;
                end else if (consume[s]) begin
                    // Consumed this cycle; re-arm only if a new event arrives.
                    hv[s] <= ev_valid_i[s];
                    if (ev_valid_i[s]) ha[s] <= ev_flat[s];
                end else if (ev_valid_i[s]) begin
                    hv[s] <= 1'b1;
                    ha[s] <= ev_flat[s];
                end
            end
        end
    end

endmodule

`default_nettype wire
