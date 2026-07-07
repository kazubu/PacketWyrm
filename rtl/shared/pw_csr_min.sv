// PacketWyrm Phase 1 minimum CSR fabric.
//
// AXI4-Lite slave (32-bit data, 12-bit address) exposing the static
// identity registers the host needs to confirm a working bitstream:
//
//   0x000  device_id            R   constant from pw_pkg::PW_DEVICE_ID
//   0x004  version              R   from pw_version_pkg::PW_VERSION
//   0x008  build_id             R   from pw_version_pkg::PW_BUILD_ID
//   0x00c  git_hash             R   from pw_version_pkg::PW_GIT_HASH
//   0x010  capabilities         R   parameter CAPABILITIES
//   0x014  num_local_ports      R   parameter NUM_PORTS
//   0x018  num_local_flows      R   parameter NUM_FLOWS         (Phase >=3)
//   0x01c  num_logical_ifs      R   parameter NUM_LOGICAL_IFS   (Phase >=5)
//   0x020  num_classifier       R   parameter NUM_CLASSIFIER    (Phase >=3)
//   0x024  num_hist_bins        R   parameter NUM_HIST_BINS     (Phase >=3)
//   0x100  global_control       RW  software-visible bits (no effect Phase 1)
//   0x104  global_status        R   {degraded, error, running, armed, ready}
//   0x108  timestamp_low        R   FPGA timestamp counter (snapshot pair)
//   0x10c  timestamp_high       R   latched on read of _low
//   0x110  error_status         W1C sticky error bits
//
// Phase 2+ extends this fabric with the classifier / flow / stats /
// histogram windows. Each addition keeps the same AXI-Lite shell so
// the host backend never needs to learn a second protocol.

`default_nettype none

module pw_csr_min #(
    parameter logic [31:0] CAPABILITIES   = 32'h0,
    parameter int          NUM_PORTS      = 2,
    parameter int          NUM_FLOWS      = 0,
    parameter int          NUM_LOGICAL_IFS = 0,
    parameter int          NUM_CLASSIFIER = 0,
    parameter int          NUM_HIST_BINS  = 0
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    // AXI4-Lite write address
    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    // AXI4-Lite write data
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    // AXI4-Lite write response
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Lite read address
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // AXI4-Lite read data
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // FPGA-side observable signals (ignored if you don't need them)
    output wire [31:0] global_control_o,
    input  wire [31:0] error_status_set_i,   // set bits W1S into sticky register
    input  wire [63:0] timestamp_i,

    // Phase 2 SFP+ status / counters (read-only) + control (RW). The
    // Phase 1 top ties the inputs to 0 and leaves sfp_control_o open.
    input  wire [31:0] sfp_status_i,  // {.., p1_rx_status,p1_lock, p0_rx_status,p0_lock}
    input  wire [31:0] sfp_rx0_i,     // port 0 RX frame count
    input  wire [31:0] sfp_rx1_i,     // port 1 RX frame count
    input  wire [31:0] sfp_tx0_i,     // port 0 TX frame count
    input  wire [31:0] sfp_tx1_i,     // port 1 TX frame count
    output wire [31:0] sfp_control_o   // bit0=tx_en0, bit1=tx_en1
);

    import pw_pkg::*;
    import pw_version_pkg::*;

    // --- write-side state machine ------------------------------------------
    reg [11:0] awaddr_q;
    reg        aw_captured;

    reg [31:0] global_control_q;
    reg [31:0] error_status_q;
    reg [31:0] sfp_control_q;

    // Phase 2 SFP+ register offsets (read window above the identity regs).
    localparam [11:0] PW_REG_SFP_STATUS  = 12'h200;
    localparam [11:0] PW_REG_SFP_RX0     = 12'h204;
    localparam [11:0] PW_REG_SFP_RX1     = 12'h208;
    localparam [11:0] PW_REG_SFP_TX0     = 12'h20c;
    localparam [11:0] PW_REG_SFP_TX1     = 12'h210;
    localparam [11:0] PW_REG_SFP_CONTROL = 12'h214;

    assign sfp_control_o = sfp_control_q;

    // 64-bit counter read-latch: reading _low latches _high.
    reg [31:0] timestamp_high_latched;

    wire [31:0] timestamp_low  = timestamp_i[31:0];
    wire [31:0] timestamp_high = timestamp_i[63:32];

    assign global_control_o = global_control_q;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        // W1C clear mask for ERROR_STATUS, valid this cycle only. The sticky
        // register has a SINGLE assignment point (bottom of the else branch)
        // merging this clear with the external set. A separate
        // `error_status_q <= error_status_q & ~wdata` inside the write case
        // would be dead code: the textually later sticky-set NBA would win
        // and every W1C write would be silently discarded.
        logic [31:0] err_w1c;
        err_w1c = '0;
        if (!s_axi_aresetn) begin
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            s_axi_bvalid     <= 1'b0;
            s_axi_bresp      <= 2'b00;
            aw_captured      <= 1'b0;
            awaddr_q         <= '0;
            global_control_q <= '0;
            error_status_q   <= '0;
            sfp_control_q    <= '0;
        end else begin
            // accept address
            if (!aw_captured && s_axi_awvalid) begin
                aw_captured   <= 1'b1;
                awaddr_q      <= s_axi_awaddr;
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // accept data + commit
            if (aw_captured && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_wready <= 1'b1;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                case (awaddr_q)
                    PW_REG_GLOBAL_CONTROL: global_control_q <= s_axi_wdata;
                    PW_REG_ERROR_STATUS:   err_w1c          = s_axi_wdata; // W1C (applied below)
                    PW_REG_SFP_CONTROL:    sfp_control_q    <= s_axi_wdata;
                    default:               s_axi_bresp <= 2'b10; // SLVERR on unknown / RO reg
                endcase
                aw_captured  <= 1'b0;
            end else begin
                s_axi_wready <= 1'b0;
            end

            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // Single assignment point for the sticky error register: apply
            // this cycle's W1C clear (if any) and OR in the external set. A
            // bit both cleared and set in the same cycle stays set (the new
            // event wins over the stale acknowledgement).
            error_status_q <= (error_status_q & ~err_w1c) | error_status_set_i;
        end
    end

    // --- read-side ----------------------------------------------------------
    // Canonical AXI4-Lite slave read: ARREADY pulses for one cycle to
    // accept and latch the address, then RVALID/RDATA are presented on
    // the *following* cycle. ARREADY and RVALID are never asserted in
    // the same cycle. The previous version raised both together, which
    // the xdma M_AXI_LITE master mishandled (only the first read on a
    // freshly mapped BAR completed; subsequent reads timed out and the
    // host saw 0xffffffff). See README "AXI-Lite read stability".
    reg [11:0] araddr_q;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready          <= 1'b0;
            s_axi_rvalid           <= 1'b0;
            s_axi_rdata            <= '0;
            s_axi_rresp            <= 2'b00;
            araddr_q               <= '0;
            timestamp_high_latched <= '0;
        end else begin
            s_axi_arready <= 1'b0;

            // Accept a read address only when idle (no response in flight).
            if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                araddr_q      <= s_axi_araddr;
            end

            // One cycle after acceptance (ARREADY was high last cycle),
            // present the data.
            if (s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                case (araddr_q)
                    PW_REG_DEVICE_ID:      s_axi_rdata <= PW_DEVICE_ID;
                    PW_REG_VERSION:        s_axi_rdata <= PW_VERSION;
                    PW_REG_BUILD_ID:       s_axi_rdata <= PW_BUILD_ID;
                    PW_REG_GIT_HASH:       s_axi_rdata <= PW_GIT_HASH;
                    PW_REG_CAPABILITIES:   s_axi_rdata <= CAPABILITIES;
                    PW_REG_NUM_PORTS:      s_axi_rdata <= NUM_PORTS[31:0];
                    PW_REG_NUM_FLOWS:      s_axi_rdata <= NUM_FLOWS[31:0];
                    PW_REG_NUM_LOG_IFS:    s_axi_rdata <= NUM_LOGICAL_IFS[31:0];
                    PW_REG_NUM_CLS:        s_axi_rdata <= NUM_CLASSIFIER[31:0];
                    PW_REG_NUM_HIST_BINS:  s_axi_rdata <= NUM_HIST_BINS[31:0];
                    PW_REG_GLOBAL_CONTROL: s_axi_rdata <= global_control_q;
                    PW_REG_GLOBAL_STATUS:  s_axi_rdata <= 32'h0000_0001; // ready
                    PW_REG_TIMESTAMP_LOW: begin
                        s_axi_rdata            <= timestamp_low;
                        timestamp_high_latched <= timestamp_high;
                    end
                    PW_REG_TIMESTAMP_HIGH: s_axi_rdata <= timestamp_high_latched;
                    PW_REG_ERROR_STATUS:   s_axi_rdata <= error_status_q;
                    PW_REG_SFP_STATUS:     s_axi_rdata <= sfp_status_i;
                    PW_REG_SFP_RX0:        s_axi_rdata <= sfp_rx0_i;
                    PW_REG_SFP_RX1:        s_axi_rdata <= sfp_rx1_i;
                    PW_REG_SFP_TX0:        s_axi_rdata <= sfp_tx0_i;
                    PW_REG_SFP_TX1:        s_axi_rdata <= sfp_tx1_i;
                    PW_REG_SFP_CONTROL:    s_axi_rdata <= sfp_control_q;
                    default: begin
                        s_axi_rdata <= 32'h0;
                        s_axi_rresp <= 2'b10; // SLVERR on unmapped
                    end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
