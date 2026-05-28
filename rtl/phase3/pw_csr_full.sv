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
//   - The histogram window (0x4000..0x4FFF) via
//     pw_histogram_snapshot.
//
// A single AXI-Lite write decode produces the `wr_en/wr_addr/wr_data`
// strobe that the classifier and flow windows consume. Writes to
// PWFPGA_REG_STATS_SNAPSHOT_TRIGGER (0x3FFC) trigger both the stats
// and histogram shadows in lockstep.

`default_nettype none

import pw_classifier_pkg::*;

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
    input  wire [63:0]       flow_rx_i         [NUM_FLOWS],
    input  wire [63:0]       flow_lost_i       [NUM_FLOWS],
    input  wire [63:0]       flow_dup_i        [NUM_FLOWS],
    input  wire [63:0]       flow_ooo_i        [NUM_FLOWS],
    input  wire [63:0]       flow_last_seq_i   [NUM_FLOWS],
    input  wire [63:0]       flow_min_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_max_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_sum_lat_i    [NUM_FLOWS],
    input  wire [63:0]       flow_samples_i    [NUM_FLOWS],
    input  wire [63:0]       flow_hist_i       [NUM_FLOWS * NUM_HIST_BINS],

    // Outputs to the data plane.
    output pw_classifier_table_t          cls_table_o,
    output logic [NUM_PORTS-1:0]          gen_enable_o,
    output logic [NUM_PORTS-1:0] [31:0]   gen_tokens_fp_o,
    output logic [NUM_PORTS-1:0] [15:0]   gen_burst_o,
    output logic [NUM_PORTS-1:0] [47:0]   gen_src_mac_o,
    output logic [NUM_PORTS-1:0] [47:0]   gen_dst_mac_o,
    output logic [NUM_PORTS-1:0]          gen_vlan_en_o,
    output logic [NUM_PORTS-1:0] [11:0]   gen_vlan_id_o,
    output logic [NUM_PORTS-1:0] [31:0]   gen_src_ip_o,
    output logic [NUM_PORTS-1:0] [31:0]   gen_dst_ip_o,
    output logic [NUM_PORTS-1:0] [15:0]   gen_udp_sp_o,
    output logic [NUM_PORTS-1:0] [15:0]   gen_udp_dp_o
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

    localparam logic [15:0] WIN_CLS_BASE       = 16'h1000;
    localparam logic [15:0] WIN_FLOW_BASE      = 16'h2000;
    localparam logic [15:0] WIN_STATS_BASE     = 16'h3000;
    localparam logic [15:0] WIN_HIST_BASE      = 16'h4000;
    localparam logic [15:0] COMMIT_OFF         = 16'h0FFC;
    localparam logic [15:0] STATS_TRIGGER_ADDR = WIN_STATS_BASE + COMMIT_OFF;

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
        end else begin
            wr_en            <= 1'b0;
            snapshot_trigger <= 1'b0;

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
    logic [31:0] hist_rdata;

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

    pw_flow_window #(
        .ADDR_W        (ADDR_W),
        .PORTS         (NUM_PORTS),
        .DEPTH         (NUM_FLOWS),
        .WIN_BASE      (WIN_FLOW_BASE),
        .COMMIT_OFFSET (COMMIT_OFF)
    ) u_fw (
        .clk             (s_axi_aclk),
        .rst_n           (s_axi_aresetn),
        .wr_en           (wr_en),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .gen_enable_o    (gen_enable_o),
        .gen_tokens_fp_o (gen_tokens_fp_o),
        .gen_burst_o     (gen_burst_o),
        .gen_src_mac_o   (gen_src_mac_o),
        .gen_dst_mac_o   (gen_dst_mac_o),
        .gen_vlan_en_o   (gen_vlan_en_o),
        .gen_vlan_id_o   (gen_vlan_id_o),
        .gen_src_ip_o    (gen_src_ip_o),
        .gen_dst_ip_o    (gen_dst_ip_o),
        .gen_udp_sp_o    (gen_udp_sp_o),
        .gen_udp_dp_o    (gen_udp_dp_o),
        .commit_pulse_o  ()
    );

    pw_stats_snapshot #(
        .PORTS    (NUM_PORTS),
        .NUM_FLOWS(NUM_FLOWS)
    ) u_stats (
        .clk            (s_axi_aclk),
        .rst_n          (s_axi_aresetn),
        .trigger_i      (snapshot_trigger),
        .port_drops_i   (port_drops_i),
        .flow_rx_i      (flow_rx_i),
        .flow_lost_i    (flow_lost_i),
        .flow_dup_i     (flow_dup_i),
        .flow_ooo_i     (flow_ooo_i),
        .flow_last_seq_i(flow_last_seq_i),
        .flow_min_lat_i (flow_min_lat_i),
        .flow_max_lat_i (flow_max_lat_i),
        .flow_sum_lat_i (flow_sum_lat_i),
        .flow_samples_i (flow_samples_i),
        .rd_addr_i      (s_axi_araddr[15:0] - WIN_STATS_BASE),
        .rd_data_o      (stats_rdata)
    );

    pw_histogram_snapshot #(
        .NUM_FLOWS  (NUM_FLOWS),
        .NUM_BUCKETS(NUM_HIST_BINS)
    ) u_hist (
        .clk       (s_axi_aclk),
        .rst_n     (s_axi_aresetn),
        .trigger_i (snapshot_trigger),
        .hist_i    (flow_hist_i),
        .rd_addr_i (s_axi_araddr[15:0] - WIN_HIST_BASE),
        .rd_data_o (hist_rdata)
    );

    // --- read-side -----------------------------------------------
    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready          <= 1'b0;
            s_axi_rvalid           <= 1'b0;
            s_axi_rdata            <= '0;
            s_axi_rresp            <= 2'b00;
            timestamp_high_latched <= '0;
        end else begin
            if (!s_axi_rvalid && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                if (s_axi_araddr >= WIN_HIST_BASE &&
                    s_axi_araddr < (WIN_HIST_BASE + 16'h1000)) begin
                    s_axi_rdata <= hist_rdata;
                end else if (s_axi_araddr >= WIN_STATS_BASE &&
                             s_axi_araddr < (WIN_STATS_BASE + 16'h1000)) begin
                    s_axi_rdata <= stats_rdata;
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
            end else begin
                s_axi_arready <= 1'b0;
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
