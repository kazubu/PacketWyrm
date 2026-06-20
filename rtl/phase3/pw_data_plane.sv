// PacketWyrm Phase 3 data plane (skeleton, single card).
//
// Wires the parser + classifier + checker per ingress port, plus a
// flow generator per egress port. External outputs:
//
//   - port[N] egress frames    (driven by either a forwarded RX
//                              frame or flow_gen output; testbench
//                              loops these back into ingress for
//                              the loopback test)
//   - punt frame channel       (PUNT_TO_HOST action; testbench
//                              counts and inspects)
//   - per-flow checker counters
//   - per-port basic drop counters

`default_nettype none

import pw_axis_pkg::*;
import pw_classifier_pkg::*;

module pw_data_plane #(
    parameter int PW_PORTS       = 2,
    parameter int PW_NUM_FLOWS   = 16,
    parameter int PW_NUM_BUCKETS = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire [63:0]                timestamp_i,

    input  pw_classifier_table_t      cls_table_i,

    // Per-port ingress (driven by testbench / Phase-2 MAC RX)
    input  pw_frame_t                 rx_frame_i  [PW_PORTS],
    input  wire                       rx_valid_i  [PW_PORTS],

    // Per-port egress (testbench can loopback into rx)
    output pw_frame_t                 tx_frame_o  [PW_PORTS],
    output logic                      tx_valid_o  [PW_PORTS],
    input  wire                       tx_ready_i  [PW_PORTS],

    // Punt to host
    output pw_frame_t                 punt_frame_o,
    output logic                      punt_valid_o,

    // Flow gen control (one generator per egress port, flow 0)
    input  wire                       gen_enable_i   [PW_PORTS],
    input  wire [31:0]                gen_tokens_fp_i[PW_PORTS],
    input  wire [15:0]                gen_burst_i    [PW_PORTS],
    input  wire [47:0]                gen_src_mac_i  [PW_PORTS],
    input  wire [47:0]                gen_dst_mac_i  [PW_PORTS],
    input  wire                       gen_vlan_en_i  [PW_PORTS],
    input  wire [11:0]                gen_vlan_id_i  [PW_PORTS],
    input  wire [31:0]                gen_src_ip_i   [PW_PORTS],
    input  wire [31:0]                gen_dst_ip_i   [PW_PORTS],
    input  wire [15:0]                gen_udp_sp_i   [PW_PORTS],
    input  wire [15:0]                gen_udp_dp_i   [PW_PORTS],

    // Per-flow checker counters (concatenation over all ports)
    output logic [63:0]               flow_rx        [PW_NUM_FLOWS],
    output logic [63:0]               flow_lost      [PW_NUM_FLOWS],
    output logic [63:0]               flow_dup       [PW_NUM_FLOWS],
    output logic [63:0]               flow_ooo       [PW_NUM_FLOWS],
    output logic [63:0]               flow_last_seq  [PW_NUM_FLOWS],
    output logic [63:0]               flow_min_lat   [PW_NUM_FLOWS],
    output logic [63:0]               flow_max_lat   [PW_NUM_FLOWS],
    output logic [63:0]               flow_sum_lat   [PW_NUM_FLOWS],
    output logic [63:0]               flow_samples   [PW_NUM_FLOWS],
    output logic [63:0]               flow_hist      [PW_NUM_FLOWS * PW_NUM_BUCKETS],

    // Per-port simple drop counters
    output logic [31:0]               port_drops_o   [PW_PORTS]
);

    // ------------------------------------------------------------
    // Per-port RX: parser -> classifier
    // ------------------------------------------------------------
    // Module-port-driven scalars and small structs are kept as
    // *packed* arrays so the simulator's continuous-assign /
    // unpacked-array-element bug never bites.
    pw_match_key_t       [PW_PORTS-1:0] rx_key;
    logic                [PW_PORTS-1:0] rx_kv;
    pw_class_result_t    [PW_PORTS-1:0] rx_res;

    genvar gp;
    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_rx
            pw_parser u_parser (
                .clk          (clk),
                .rst_n        (rst_n),
                .frame_i      (rx_frame_i[gp]),
                .frame_valid_i(rx_valid_i[gp]),
                .key_o        (rx_key[gp]),
                .key_valid_o  (rx_kv[gp])
            );

            pw_classifier u_cls (
                .clk         (clk),
                .rst_n       (rst_n),
                .table_i     (cls_table_i),
                .key_i       (rx_key[gp]),
                .key_valid_i (rx_kv[gp]),
                .result_o    (rx_res[gp])
            );
        end
    endgenerate

    // ------------------------------------------------------------
    // RX checker (one logical block, sees events from any port)
    // ------------------------------------------------------------
    // For the skeleton we only forward one classification event per
    // cycle to the checker. With two ports the testbench drives them
    // alternately or one at a time, which is sufficient to prove the
    // path. Production RTL adds a small ingress arbiter here.
    pw_match_key_t    chk_key;
    pw_class_result_t chk_res;
    logic             chk_ev;

    always_comb begin
        chk_key = '0;
        chk_res = '0;
        chk_ev  = 1'b0;
        for (int p = 0; p < PW_PORTS; p++) begin
            // rx_kv[p] is the parser's registered key_valid_o; using
            // it (rather than the raw rx_valid_i) cleanly absorbs
            // 1-cycle ingress pulses through the sequential parser.
            if (rx_kv[p] && rx_res[p].hit &&
                rx_res[p].action == PW_ACT_TEST_RX) begin
                chk_key = rx_key[p];
                chk_res = rx_res[p];
                chk_ev  = 1'b1;
            end
        end
    end

    pw_test_rx_checker #(
        .NUM_FLOWS       (PW_NUM_FLOWS),
        .NUM_BUCKETS     (PW_NUM_BUCKETS),
        .EMIT_HIST_ARRAY (1)   // legacy plane keeps the flat FF histogram
    ) u_checker (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear_i         (1'b0),
        .timestamp_i     (timestamp_i),
        .key_i           (chk_key),
        .result_i        (chk_res),
        .event_valid_i   (chk_ev),
        .rx_frames_o     (flow_rx),
        .lost_o          (flow_lost),
        .duplicate_o     (flow_dup),
        .out_of_order_o  (flow_ooo),
        .last_seq_o      (flow_last_seq),
        .min_latency_o   (flow_min_lat),
        .max_latency_o   (flow_max_lat),
        .sum_latency_o   (flow_sum_lat),
        .sample_count_o  (flow_samples),
        .jitter_min_o    (),   // legacy wide-bus plane (sim-only): jitter unused
        .jitter_max_o    (),
        .jitter_sum_o    (),
        .hist_ev_o       (),
        .hist_flow_o     (),
        .hist_bucket_o   (),
        .hist_o          (flow_hist)
    );

    // ------------------------------------------------------------
    // Dispatcher: per-port action handling
    //
    // Skeleton simplifications:
    //   - FORWARD_PORT routes the RX frame to tx_frame_o[egress_port]
    //   - PUNT_TO_HOST emits on punt_frame_o
    //   - MIRROR_TO_HOST behaves like PUNT_TO_HOST for now
    //   - TEST_RX consumes the frame (checker has already seen it)
    //   - DROP simply drops; per-port drop counter ticks
    //
    // Frame generators contend for tx_frame_o via a tiny arbiter:
    // forwarded frames have priority, flow_gen fills the idle slot.
    // ------------------------------------------------------------
    pw_frame_t fwd_frame   [PW_PORTS];
    logic      fwd_valid   [PW_PORTS];
    pw_frame_t gen_frame   [PW_PORTS];
    logic      gen_valid   [PW_PORTS];
    logic      gen_ready   [PW_PORTS];
    pw_frame_t punt_lat;
    logic      punt_lat_v;
    logic [31:0] port_drops [PW_PORTS];

    // The parser produces a 1-cycle-delayed copy of the ingress
    // frame inside u_parser; for forwarding / punt the original
    // frame data must travel through the same 1 cycle of delay so
    // it lines up with the classifier result. Register it.
    pw_frame_t rx_frame_d  [PW_PORTS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < PW_PORTS; p++) rx_frame_d[p] <= '0;
        end else begin
            for (int p = 0; p < PW_PORTS; p++) rx_frame_d[p] <= rx_frame_i[p];
        end
    end

    always_comb begin
        for (int p = 0; p < PW_PORTS; p++) begin
            fwd_frame[p] = '0;
            fwd_valid[p] = 1'b0;
        end
        punt_lat   = '0;
        punt_lat_v = 1'b0;
        for (int p = 0; p < PW_PORTS; p++) begin
            if (rx_kv[p]) begin
                unique case (rx_res[p].action)
                    PW_ACT_FORWARD_PORT: begin
                        int ep = int'(rx_res[p].egress_port);
                        if (ep >= 0 && ep < PW_PORTS) begin
                            fwd_frame[ep] = rx_frame_d[p];
                            fwd_valid[ep] = 1'b1;
                        end
                    end
                    PW_ACT_PUNT_TO_HOST, PW_ACT_MIRROR_TO_HOST: begin
                        punt_lat   = rx_frame_d[p];
                        punt_lat_v = 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // Drop counter per port: a key_valid event whose action is DROP
    // (including the default for no match) increments.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < PW_PORTS; p++) port_drops[p] <= '0;
        end else begin
            for (int p = 0; p < PW_PORTS; p++) begin
                if (rx_kv[p] && rx_res[p].action == PW_ACT_DROP)
                    port_drops[p] <= port_drops[p] + 32'd1;
            end
        end
    end

    assign punt_frame_o = punt_lat;
    assign punt_valid_o = punt_lat_v;

    // ------------------------------------------------------------
    // Flow generators + tx arbiter
    // ------------------------------------------------------------
    generate
        for (gp = 0; gp < PW_PORTS; gp++) begin : g_tx
            pw_flow_gen #(.GLOBAL_FLOW_ID(32'd1 + gp), .LOCAL_FLOW_ID(32'd0)) u_gen (
                .clk                  (clk),
                .rst_n                (rst_n),
                .enable_i             (gen_enable_i[gp]),
                .tokens_per_tick_fp_i (gen_tokens_fp_i[gp]),
                .burst_bytes_i        (gen_burst_i[gp]),
                .egress_port_i        (4'(gp)),
                .src_mac_i      (gen_src_mac_i[gp]),
                .dst_mac_i      (gen_dst_mac_i[gp]),
                .vlan_enable_i  (gen_vlan_en_i[gp]),
                .vlan_id_i      (gen_vlan_id_i[gp]),
                .src_ipv4_i     (gen_src_ip_i[gp]),
                .dst_ipv4_i     (gen_dst_ip_i[gp]),
                .udp_src_port_i (gen_udp_sp_i[gp]),
                .udp_dst_port_i (gen_udp_dp_i[gp]),
                .timestamp_i    (timestamp_i),
                .frame_o        (gen_frame[gp]),
                .frame_valid_o  (gen_valid[gp]),
                .frame_ready_i  (gen_ready[gp])
            );

            // tx arbiter: forwarded frames first, flow_gen second
            always_comb begin
                tx_frame_o[gp] = '0;
                tx_valid_o[gp] = 1'b0;
                gen_ready[gp]  = 1'b0;
                if (fwd_valid[gp]) begin
                    tx_frame_o[gp] = fwd_frame[gp];
                    tx_valid_o[gp] = 1'b1;
                end else if (gen_valid[gp]) begin
                    tx_frame_o[gp] = gen_frame[gp];
                    tx_valid_o[gp] = 1'b1;
                    gen_ready[gp]  = tx_ready_i[gp];
                end
            end
        end
    endgenerate

    // Expose drop counters
    always_comb begin
        for (int p = 0; p < PW_PORTS; p++)
            port_drops_o[p] = port_drops[p];
    end

endmodule

`default_nettype wire
