// PacketWyrm Phase 3 full CSR fabric.
//
// AXI4-Lite slave (16-bit address space, covering BAR0's first
// 64 KB) that wraps:
//   - The identity / global control / timestamp registers from
//     pw_csr_min.
//   - The classifier table window (0x1000..0x1FFF) via
//     pw_classifier_window.
//   - The flow table window (0x2000..0x2FFF) via pw_flow_window.
//   - The stats snapshot window (0x3000..0x3FFF) via
//     pw_stats_snapshot.
//   - The latency-histogram window (0x4000..0x4FFF) as an addressed
//     pass-through to the data plane's BRAM histogram
//     (pw_lat_histogram): the read address decodes to a flat
//     (flow,bucket) BRAM address and the 64-bit count returns one
//     cycle later.
//
// A single AXI-Lite write decode produces the `wr_en/wr_addr/wr_data`
// strobe that the classifier and flow windows consume. Writes to
// PWFPGA_REG_STATS_SNAPSHOT_TRIGGER (0x3FFC) trigger the stats shadow;
// the histogram is read live (not snapshotted).

`default_nettype none

import pw_classifier_pkg::*;
import pw_axis_pkg::*;

module pw_csr_full #(
    parameter int          ADDR_W          = 16,
    parameter logic [31:0] CAPABILITIES    = 32'h0,
    parameter int          NUM_PORTS       = 2,
    parameter int          NUM_FLOWS       = 8,
    parameter int          NUM_LOGICAL_IFS = 0,
    parameter int          NUM_CLASSIFIER  = 8,
    parameter int          NUM_HIST_BINS   = 16
) (
    input  wire              s_axi_aclk,
    input  wire              s_axi_aresetn,

    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire              s_axi_awvalid,
    output reg               s_axi_awready,

    input  wire [31:0]       s_axi_wdata,
    input  wire [3:0]        s_axi_wstrb,
    input  wire              s_axi_wvalid,
    output reg               s_axi_wready,

    output reg  [1:0]        s_axi_bresp,
    output reg               s_axi_bvalid,
    input  wire              s_axi_bready,

    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire              s_axi_arvalid,
    output reg               s_axi_arready,

    output reg  [31:0]       s_axi_rdata,
    output reg  [1:0]        s_axi_rresp,
    output reg               s_axi_rvalid,
    input  wire              s_axi_rready,

    input  wire [63:0]       timestamp_i,
    output wire [31:0]       global_control_o,
    input  wire [31:0]       error_status_set_i,

    // Counters from the data plane (driven into the stats /
    // histogram snapshot modules).
    input  wire [31:0]       port_drops_i      [NUM_PORTS],
    input  wire [47:0]       rx_frames_i       [NUM_PORTS],
    input  wire [47:0]       rx_bytes_i        [NUM_PORTS],
    input  wire [47:0]       tx_frames_i       [NUM_PORTS],
    input  wire [47:0]       tx_bytes_i        [NUM_PORTS],
    input  wire [63:0]       flow_rx_i         [NUM_FLOWS],
    input  wire [63:0]       flow_lost_i       [NUM_FLOWS],
    input  wire [63:0]       flow_dup_i        [NUM_FLOWS],
    input  wire [63:0]       flow_ooo_i        [NUM_FLOWS],
    input  wire [63:0]       flow_last_seq_i   [NUM_FLOWS],
    input  wire [63:0]       flow_min_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_max_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_sum_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_samples_i    [NUM_FLOWS],
    input  wire [47:0]       flow_tx_i         [NUM_FLOWS],

    // Outputs to the data plane.
    output pw_classifier_table_t          cls_table_o,

    // Decoded CSR write strobe for the BRAM-backed flow table (now in
    // pw_data_plane_axis). The flow window range is filtered there.
    output logic                          flow_wr_en_o,
    output logic [ADDR_W-1:0]             flow_wr_addr_o,
    output logic [31:0]                   flow_wr_data_o,

    // Live latency-histogram read port into the data plane's BRAM
    // (pw_lat_histogram). Flat (flow*NUM_HIST_BINS+bucket) address out,
    // 64-bit count back one cycle later.
    output logic [15:0]                   hist_rd_addr_o,
    input  wire  [63:0]                   hist_rd_data_i,

    // Soft clear pulse for the RX checkers (write to STATS_CLEAR_ADDR).
    output logic                          stats_clear_o,

    // Data-plane soft reset pulse (write to DP_RESET_ADDR): resets the
    // wedge-prone datapath state machines (gen / SAF / arbiters) so a
    // wedged data plane recovers without a JTAG reconfig.
    output logic                          dp_soft_rst_o,

    // In-system SPI flash master pins (wired to STARTUPE3 in the board
    // top). Lets the host erase/program/read the config flash live.
    output logic                          spi_sck_o,
    output logic                          spi_cs_n_o,
    output logic                          spi_mosi_o,
    input  wire                           spi_miso_i,

    // In-band reconfiguration trigger: pulses when the host writes the
    // magic to REG_REBOOT. Drives pw_icap_reboot (ICAP IPROG) -> the FPGA
    // reloads its bitstream from flash (PCIe drops; host re-enumerates).
    output logic                          icap_reboot_o,

    // Punt / slow-path RX window (pw_punt_rx_window lives in the top).
    // Addressed read is combinational out / registered back (1-cycle), like
    // the histogram. punt_pop_o pulses when the host writes PUNT_POP.
    output logic                          punt_rd_en_o,
    output logic [15:0]                   punt_rd_addr_o,
    input  wire  [31:0]                   punt_rd_data_i,
    output logic                          punt_pop_o,

    // Slow-path TX inject AXIS master (pw_inject_tx_window lives here; the
    // data plane mixes this into the selected egress port's TX arbiter).
    output logic [63:0]                   inj_m_tdata,
    output logic [7:0]                    inj_m_tkeep,
    output logic                          inj_m_tvalid,
    input  wire                           inj_m_tready,
    output logic                          inj_m_tlast,
    output logic [3:0]                    inj_egress_o
);

    // Top-level register offsets we still serve here (the rest live
    // in their windows). Mirrors pw_pkg, expanded to 16-bit.
    localparam logic [15:0] REG_DEVICE_ID      = 16'h0000;
    localparam logic [15:0] REG_VERSION        = 16'h0004;
    localparam logic [15:0] REG_BUILD_ID       = 16'h0008;
    localparam logic [15:0] REG_GIT_HASH       = 16'h000C;
    localparam logic [15:0] REG_CAPABILITIES   = 16'h0010;
    localparam logic [15:0] REG_NUM_PORTS      = 16'h0014;
    localparam logic [15:0] REG_NUM_FLOWS      = 16'h0018;
    localparam logic [15:0] REG_NUM_LOG_IFS    = 16'h001C;
    localparam logic [15:0] REG_NUM_CLS        = 16'h0020;
    localparam logic [15:0] REG_NUM_HIST_BINS  = 16'h0024;
    localparam logic [15:0] REG_GLOBAL_CONTROL = 16'h0100;
    localparam logic [15:0] REG_GLOBAL_STATUS  = 16'h0104;
    localparam logic [15:0] REG_TIMESTAMP_LOW  = 16'h0108;
    localparam logic [15:0] REG_TIMESTAMP_HIGH = 16'h010C;
    localparam logic [15:0] REG_ERROR_STATUS   = 16'h0110;
    localparam logic [15:0] REG_REBOOT         = 16'h0120;   // write magic -> ICAP IPROG
    localparam logic [31:0] REBOOT_MAGIC       = 32'h5242_4F54;  // "RBOT"

    // Wide CSR address map (64 flows / 64 classifier rows). Each
    // table window holds 64 rows * 128 B = 8 KB of data; the
    // commit-bearing windows are spaced 16 KB apart so the commit /
    // trigger / clear registers sit ABOVE the 8 KB data region
    // (COMMIT_OFF = 0x3FFC, clear = 0x3FF8). The histogram has no
    // commit (live read), so it gets an 8 KB slot. The whole 64 KB
    // BAR is used; the unused SLOW_RX/TX placeholders are reclaimed.
    localparam logic [15:0] WIN_CLS_BASE       = 16'h2000;  // 0x2000..0x5FFF
    localparam logic [15:0] WIN_FLOW_BASE      = 16'h6000;  // 0x6000..0x9FFF
    localparam logic [15:0] WIN_HIST_BASE      = 16'hA000;  // 0xA000..0xBFFF (8 KB)
    localparam logic [15:0] WIN_STATS_BASE     = 16'hC000;  // 0xC000..0xFFFF
    localparam logic [15:0] WIN_SPAN_16K       = 16'h4000;
    localparam logic [15:0] WIN_SPAN_8K        = 16'h2000;
    localparam logic [15:0] COMMIT_OFF         = 16'h3FFC;
    localparam logic [15:0] STATS_TRIGGER_ADDR = WIN_STATS_BASE + COMMIT_OFF;
    localparam logic [15:0] STATS_CLEAR_ADDR   = WIN_STATS_BASE + 16'h3FF8;
    localparam logic [15:0] DP_RESET_ADDR      = WIN_STATS_BASE + 16'h3FF4;
    // In-system SPI flash window: sits in the free reg region (below the
    // 0x2000 table windows). Spans CTRL/LEN + 512 B TX + 512 B RX.
    localparam logic [15:0] SPI_BASE           = 16'h0800;
    localparam logic [15:0] SPI_SPAN           = 16'h0500;   // 0x0800..0x0CFF

    localparam logic [15:0] PUNT_BASE          = 16'h1000;   // 0x1000..0x1FFF
    localparam logic [15:0] PUNT_SPAN          = 16'h1000;
    localparam logic [15:0] PUNT_POP_ADDR      = PUNT_BASE + 16'h000C;

    localparam logic [15:0] INJ_BASE           = 16'h0D00;   // 0x0D00..0x0FFF
    localparam logic [15:0] INJ_SPAN           = 16'h0300;
    localparam logic [15:0] HIST_STRIDE        = 16'd128;   // 16 buckets * 8 B per flow

    import pw_version_pkg::*;
    import pw_pkg::*;

    // --- write-side FSM ------------------------------------------
    reg  [ADDR_W-1:0] awaddr_q;
    reg               aw_captured;
    reg  [31:0]       global_control_q;
    reg  [31:0]       error_status_q;
    reg  [31:0]       timestamp_high_latched;

    wire [31:0] timestamp_low  = timestamp_i[31:0];
    wire [31:0] timestamp_high = timestamp_i[63:32];

    assign global_control_o = global_control_q;

    // Strobe to the windows when an AXI-Lite write transaction completes.
    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [31:0]       wr_data;

    // Snapshot trigger (write 1 to STATS_TRIGGER_ADDR latches the
    // stats + histogram shadows in lockstep).
    logic              snapshot_trigger;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            s_axi_bvalid     <= 1'b0;
            s_axi_bresp      <= 2'b00;
            aw_captured      <= 1'b0;
            awaddr_q         <= '0;
            global_control_q <= '0;
            error_status_q   <= '0;
            wr_en            <= 1'b0;
            wr_addr          <= '0;
            wr_data          <= '0;
            snapshot_trigger <= 1'b0;
            stats_clear_o    <= 1'b0;
            dp_soft_rst_o    <= 1'b0;
            icap_reboot_o    <= 1'b0;
            punt_pop_o       <= 1'b0;
        end else begin
            wr_en            <= 1'b0;
            snapshot_trigger <= 1'b0;
            stats_clear_o    <= 1'b0;
            dp_soft_rst_o    <= 1'b0;
            icap_reboot_o    <= 1'b0;
            punt_pop_o       <= 1'b0;

            if (!aw_captured && s_axi_awvalid) begin
                aw_captured   <= 1'b1;
                awaddr_q      <= s_axi_awaddr;
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            if (aw_captured && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_wready <= 1'b1;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                // Local register writes
                case (awaddr_q)
                    REG_GLOBAL_CONTROL: global_control_q <= s_axi_wdata;
                    REG_ERROR_STATUS:   error_status_q   <= error_status_q & ~s_axi_wdata;
                    default: /* defer to windows */ ;
                endcase
                // Window strobe
                wr_en   <= 1'b1;
                wr_addr <= awaddr_q;
                wr_data <= s_axi_wdata;
                if (awaddr_q == STATS_TRIGGER_ADDR && s_axi_wdata[0])
                    snapshot_trigger <= 1'b1;
                if (awaddr_q == STATS_CLEAR_ADDR && s_axi_wdata[0])
                    stats_clear_o <= 1'b1;
                if (awaddr_q == DP_RESET_ADDR && s_axi_wdata[0])
                    dp_soft_rst_o <= 1'b1;
                if (awaddr_q == REG_REBOOT && s_axi_wdata == REBOOT_MAGIC)
                    icap_reboot_o <= 1'b1;
                if (awaddr_q == PUNT_POP_ADDR && s_axi_wdata[0])
                    punt_pop_o <= 1'b1;
                aw_captured  <= 1'b0;
            end else begin
                s_axi_wready <= 1'b0;
            end

            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            error_status_q <= error_status_q | error_status_set_i;
        end
    end

    // --- window read ports ---------------------------------------
    logic [31:0] stats_rdata;
    logic [31:0] spi_rdata;
    logic [31:0] inj_rdata;

    // Slow-path TX inject window: host composes a frame here; it emits the
    // frame as an AXIS master into the data plane egress mux. Region-gated
    // write strobe so writes to other windows do not land in its buffer.
    wire inj_wr_sel = (wr_addr >= INJ_BASE) && (wr_addr < (INJ_BASE + INJ_SPAN));
    pw_inject_tx_window #(
        .ADDR_W   (ADDR_W),
        .BUF_BYTES(512),
        .CTRL_OFF (16'h0000),
        .INFO_OFF (16'h0004),
        .DATA_OFF (16'h0040)
    ) u_inj (
        .clk      (s_axi_aclk),
        .rst_n    (s_axi_aresetn),
        .wr_en    (wr_en && inj_wr_sel),
        .wr_addr  (wr_addr - INJ_BASE),
        .wr_data  (wr_data),
        .rd_addr  (s_axi_araddr[15:0] - INJ_BASE),
        .rd_data  (inj_rdata),
        .m_tdata  (inj_m_tdata),
        .m_tkeep  (inj_m_tkeep),
        .m_tvalid (inj_m_tvalid),
        .m_tready (inj_m_tready),
        .m_tlast  (inj_m_tlast),
        .egress_o (inj_egress_o)
    );

    // In-system SPI flash master (live config-flash access over PCIe).
    pw_spi_flash #(
        .ADDR_W   (ADDR_W),
        .WIN_BASE (SPI_BASE),
        .BUF_BYTES(512),
        .CLK_DIV  (8)
    ) u_spi (
        .clk      (s_axi_aclk),
        .rst_n    (s_axi_aresetn),
        .wr_en    (wr_en),
        .wr_addr  (wr_addr),
        .wr_data  (wr_data),
        .rd_addr  (s_axi_araddr[15:0]),
        .rd_data  (spi_rdata),
        .sck      (spi_sck_o),
        .cs_n     (spi_cs_n_o),
        .mosi     (spi_mosi_o),
        .miso     (spi_miso_i)
    );

    // Histogram read decode: the host reads the per-flow latency
    // distribution at WIN_HIST_BASE + flow*HIST_STRIDE + bucket*8 (+0/+4
    // for the lo/hi dword). Decode the current read address into the
    // flat BRAM address (driven into the data plane) and a dword-half
    // select; the registered 64-bit count comes back on hist_rd_data_i
    // one cycle later (handled by the read FSM's wait state below).
    wire [15:0] h_off   = (s_axi_araddr[15:0] - WIN_HIST_BASE) & 16'hFFFC;
    wire [15:0] h_flow  = h_off / HIST_STRIDE;
    wire [15:0] h_boff  = h_off - h_flow * HIST_STRIDE;
    wire [15:0] h_bkt   = h_boff >> 3;
    wire        h_valid = (h_flow < NUM_FLOWS) && (h_bkt < NUM_HIST_BINS);
    wire        h_half  = s_axi_araddr[2];   // +0 -> lo dword, +4 -> hi dword
    assign hist_rd_addr_o = h_valid ? 16'(h_flow * NUM_HIST_BINS + h_bkt) : 16'd0;

    // Punt window read: combinational address out, registered data back one
    // cycle later (same timing as the histogram). rd_en keeps the window's
    // registered read tracking the current address.
    wire punt_sel_rd   = (s_axi_araddr[15:0] >= PUNT_BASE) &&
                         (s_axi_araddr[15:0] <  (PUNT_BASE + PUNT_SPAN));
    assign punt_rd_en_o   = punt_sel_rd;
    assign punt_rd_addr_o = s_axi_araddr[15:0] - PUNT_BASE;

    pw_classifier_window #(
        .ADDR_W        (ADDR_W),
        .WIN_BASE      (WIN_CLS_BASE),
        .COMMIT_OFFSET (COMMIT_OFF)
    ) u_cw (
        .clk            (s_axi_aclk),
        .rst_n          (s_axi_aresetn),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .cls_table_o    (cls_table_o),
        .commit_pulse_o ()
    );

    // The flow table itself is now BRAM-backed and lives in pw_data_plane_axis
    // (co-located with the generators for the read path). Export the decoded
    // CSR write strobe so the data plane's pw_flow_table_bram can stage it.
    assign flow_wr_en_o   = wr_en;
    assign flow_wr_addr_o = wr_addr;
    assign flow_wr_data_o = wr_data;

    pw_stats_snapshot #(
        .PORTS    (NUM_PORTS),
        .NUM_FLOWS(NUM_FLOWS)
    ) u_stats (
        .clk            (s_axi_aclk),
        .rst_n          (s_axi_aresetn),
        .trigger_i      (snapshot_trigger),
        .port_drops_i   (port_drops_i),
        .rx_frames_i    (rx_frames_i),
        .rx_bytes_i     (rx_bytes_i),
        .tx_frames_i    (tx_frames_i),
        .tx_bytes_i     (tx_bytes_i),
        .flow_rx_i      (flow_rx_i),
        .flow_lost_i    (flow_lost_i),
        .flow_dup_i     (flow_dup_i),
        .flow_ooo_i     (flow_ooo_i),
        .flow_last_seq_i(flow_last_seq_i),
        .flow_min_lat_i (flow_min_lat_i),
        .flow_max_lat_i (flow_max_lat_i),
        .flow_sum_lat_i (flow_sum_lat_i),
        .flow_samples_i (flow_samples_i),
        .flow_tx_i      (flow_tx_i),
        .rd_addr_i      (s_axi_araddr[15:0] - WIN_STATS_BASE),
        .rd_data_o      (stats_rdata)
    );

    // (The histogram is now BRAM-backed in the data plane; the read is
    // an addressed pass-through -- see hist_rd_addr_o decode above and
    // the WIN_HIST wait state in the read FSM below.)

    // --- read-side -----------------------------------------------
    // WIN_HIST reads are BRAM-backed: the address is presented to the
    // data plane combinationally (hist_rd_addr_o) and the 64-bit count
    // returns on hist_rd_data_i one cycle later. The FSM accepts the
    // read (arready) but defers rvalid one cycle to capture it. All
    // other reads stay single-cycle.
    reg hist_pend;
    reg hist_half_q;
    reg hist_val_q;
    reg punt_pend;

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready          <= 1'b0;
            s_axi_rvalid           <= 1'b0;
            s_axi_rdata            <= '0;
            s_axi_rresp            <= 2'b00;
            timestamp_high_latched <= '0;
            hist_pend              <= 1'b0;
            hist_half_q            <= 1'b0;
            hist_val_q             <= 1'b0;
            punt_pend              <= 1'b0;
        end else begin
            if (!s_axi_rvalid && !hist_pend && !punt_pend && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rresp   <= 2'b00;
                if (s_axi_araddr >= WIN_HIST_BASE &&
                    s_axi_araddr < (WIN_HIST_BASE + WIN_SPAN_8K)) begin
                    // BRAM read launched this cycle; capture it next cycle.
                    hist_pend   <= 1'b1;
                    hist_half_q <= h_half;
                    hist_val_q  <= h_valid;
                end else if (punt_sel_rd) begin
                    // Punt window: registered read, capture next cycle.
                    punt_pend   <= 1'b1;
                end else begin
                    s_axi_rvalid <= 1'b1;
                    // Stats is the topmost window (0xC000..0xFFFF), so an
                    // open-ended lower-bound check avoids 16-bit wrap.
                    if (s_axi_araddr >= WIN_STATS_BASE) begin
                        s_axi_rdata <= stats_rdata;
                    end else if (s_axi_araddr >= SPI_BASE &&
                                 s_axi_araddr < (SPI_BASE + SPI_SPAN)) begin
                        s_axi_rdata <= spi_rdata;   // SPI flash status / RX buffer
                    end else if (s_axi_araddr >= INJ_BASE &&
                                 s_axi_araddr < (INJ_BASE + INJ_SPAN)) begin
                        s_axi_rdata <= inj_rdata;   // inject window busy status
                    end else begin
                        case (s_axi_araddr)
                            REG_DEVICE_ID:      s_axi_rdata <= PW_DEVICE_ID;
                            REG_VERSION:        s_axi_rdata <= PW_VERSION;
                            REG_BUILD_ID:       s_axi_rdata <= PW_BUILD_ID;
                            REG_GIT_HASH:       s_axi_rdata <= PW_GIT_HASH;
                            REG_CAPABILITIES:   s_axi_rdata <= CAPABILITIES;
                            REG_NUM_PORTS:      s_axi_rdata <= NUM_PORTS[31:0];
                            REG_NUM_FLOWS:      s_axi_rdata <= NUM_FLOWS[31:0];
                            REG_NUM_LOG_IFS:    s_axi_rdata <= NUM_LOGICAL_IFS[31:0];
                            REG_NUM_CLS:        s_axi_rdata <= NUM_CLASSIFIER[31:0];
                            REG_NUM_HIST_BINS:  s_axi_rdata <= NUM_HIST_BINS[31:0];
                            REG_GLOBAL_CONTROL: s_axi_rdata <= global_control_q;
                            REG_GLOBAL_STATUS:  s_axi_rdata <= 32'h0000_0001;
                            REG_TIMESTAMP_LOW: begin
                                s_axi_rdata            <= timestamp_low;
                                timestamp_high_latched <= timestamp_high;
                            end
                            REG_TIMESTAMP_HIGH: s_axi_rdata <= timestamp_high_latched;
                            REG_ERROR_STATUS:   s_axi_rdata <= error_status_q;
                            default: begin
                                s_axi_rdata <= 32'h0;
                                // Don't SLVERR on the table windows; their
                                // read responses are intentionally 0 today
                                // (host reads come back via the snapshot
                                // windows instead).
                            end
                        endcase
                    end
                end
            end else begin
                s_axi_arready <= 1'b0;
                if (hist_pend) begin
                    // BRAM data valid now; complete the histogram read.
                    hist_pend    <= 1'b0;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rdata  <= hist_val_q
                                      ? (hist_half_q ? hist_rd_data_i[63:32]
                                                     : hist_rd_data_i[31:0])
                                      : 32'h0;
                end else if (punt_pend) begin
                    // Punt window registered data valid now; complete read.
                    punt_pend    <= 1'b0;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rdata  <= punt_rd_data_i;
                end
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
