// PacketWyrm classifier.
//
// Priority linear table of `PW_CLASSIFIER_ENTRIES` rows. Each row
// has an enable bit, an action, an optional mask telling the
// classifier which key fields to consider, and the per-field
// expected values. Lowest `priority_` (numerically) wins among the
// matching rows; ties break on lower index.
//
// Phase 3 skeleton: the table is loaded over the `table_i` port,
// which the testbench (or eventually a CSR window writer) drives.
// Phase 5 backs `table_i` with the BAR0 classifier window's shadow
// register file + commit logic.

`default_nettype none

import pw_classifier_pkg::*;

module pw_classifier #(
    // Output pipeline depth (cycles of latency from key_valid_i to result_o):
    //   0: combinational result (default; wide-bus plane + its sims rely on
    //      same-cycle result alongside key_valid_i).
    //   1: register result_o (breaks cls_table -> ... -> downstream).
    //   2: also register the per-entry match before the priority select,
    //      splitting the field-compare cloud (incl 128-bit IPv6) from the
    //      winner select -- needed to fit the data-plane clock.
    // The consumer must delay the key feeding it by the matching latency.
    parameter int RESULT_STAGES = 0
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  pw_classifier_table_t      table_i,
    input  pw_match_key_t             key_i,
    input  wire                       key_valid_i,
    output pw_class_result_t          result_o
);

    wire _unused = &{1'b0, clk, rst_n, 1'b0};

    logic [PW_CLASSIFIER_ENTRIES-1:0] entry_hit;
    logic [PW_CLASSIFIER_ENTRIES-1:0] entry_enable;

    genvar gi;
    generate
        for (gi = 0; gi < PW_CLASSIFIER_ENTRIES; gi++) begin : g_match
            pw_classifier_entry_t e;
            assign e               = table_i[gi];
            assign entry_enable[gi] = e.enable;

            logic m_iport, m_etype, m_vlan, m_ivlan, m_l3,
                  m_ipsrc, m_ipdst, m_v6src, m_v6dst,
                  m_l4src, m_l4dst, m_usrc, m_udst,
                  m_test, m_arp, m_ipv4_class, m_ipv6_class,
                  m_tcp, m_udp_class, m_icmp, m_icmp6, m_ospf,
                  m_flow;

            assign m_iport     = ~e.mask.match_ingress_port |
                                  (key_i.ingress_port == e.key.ingress_port);
            assign m_etype     = ~e.mask.match_ethertype |
                                  (key_i.ethertype     == e.key.ethertype);
            assign m_vlan      = ~e.mask.match_vlan_id   |
                                  (key_i.vlan_valid && key_i.vlan_id == e.key.vlan_id);
            assign m_ivlan     = ~e.mask.match_inner_vlan_id |
                                  (key_i.inner_vlan_valid &&
                                   key_i.inner_vlan_id == e.key.inner_vlan_id);
            assign m_l3        = ~e.mask.match_l3_proto  |
                                  (key_i.l3_proto      == e.key.l3_proto);
            assign m_ipsrc     = ~e.mask.match_ipv4_src  |
                                  (key_i.ipv4_src      == e.key.ipv4_src);
            assign m_ipdst     = ~e.mask.match_ipv4_dst  |
                                  (key_i.ipv4_dst      == e.key.ipv4_dst);
            assign m_v6src     = ~e.mask.match_ipv6_src  |
                                  (key_i.ipv6_src      == e.key.ipv6_src);
            assign m_v6dst     = ~e.mask.match_ipv6_dst  |
                                  (key_i.ipv6_dst      == e.key.ipv6_dst);
            assign m_l4src     = ~e.mask.match_l4_src    |
                                  (key_i.l4_src        == e.key.l4_src);
            assign m_l4dst     = ~e.mask.match_l4_dst    |
                                  (key_i.l4_dst        == e.key.l4_dst);
            assign m_usrc      = ~e.mask.match_udp_src   |
                                  (key_i.udp_src       == e.key.udp_src);
            assign m_udst      = ~e.mask.match_udp_dst   |
                                  (key_i.udp_dst       == e.key.udp_dst);
            assign m_test      = ~e.mask.match_is_test   | key_i.is_test;
            assign m_arp       = ~e.mask.match_is_arp    | key_i.is_arp;
            assign m_ipv4_class= ~e.mask.match_is_ipv4   | key_i.is_ipv4;
            assign m_ipv6_class= ~e.mask.match_is_ipv6   | key_i.is_ipv6;
            assign m_tcp       = ~e.mask.match_is_tcp    | key_i.is_tcp;
            assign m_udp_class = ~e.mask.match_is_udp    | key_i.is_udp;
            assign m_icmp      = ~e.mask.match_is_icmp   | key_i.is_icmp;
            assign m_icmp6     = ~e.mask.match_is_icmp6  | key_i.is_icmp6;
            assign m_ospf      = ~e.mask.match_is_ospf   | key_i.is_ospf;
            assign m_flow      = ~e.mask.match_flow_id   |
                                  (key_i.is_test &&
                                   key_i.test_flow_id  == e.key.test_flow_id);

            assign entry_hit[gi] = e.enable && key_valid_i &&
                                   m_iport & m_etype & m_vlan & m_ivlan & m_l3 &
                                   m_ipsrc & m_ipdst & m_v6src & m_v6dst &
                                   m_l4src & m_l4dst & m_usrc & m_udst &
                                   m_test  & m_arp & m_ipv4_class & m_ipv6_class &
                                   m_tcp & m_udp_class & m_icmp & m_icmp6 & m_ospf &
                                   m_flow;
        end
    endgenerate

    // Per-entry fields the priority select consumes. For RESULT_STAGES==2
    // they are REGISTERED in stage A (the match), so the stage-B select never
    // reads the live cls_table -- the cls_table -> select -> result path was
    // the residual timing path at 156 MHz. For 0/1 they pass straight from
    // the (quasi-static) table.
    logic        s_hit     [PW_CLASSIFIER_ENTRIES];
    pw_action_e  s_action  [PW_CLASSIFIER_ENTRIES];
    logic [3:0]  s_egress  [PW_CLASSIFIER_ENTRIES];
    logic [31:0] s_flow    [PW_CLASSIFIER_ENTRIES];
    logic [31:0] s_logical [PW_CLASSIFIER_ENTRIES];
    logic [7:0]  s_prio    [PW_CLASSIFIER_ENTRIES];

    generate
        if (RESULT_STAGES == 2) begin : g_cand
            // Stage A: register the per-entry match + the fields the winner
            // select needs, so stage B is a pure mux over registered values.
            logic        cand_hit     [PW_CLASSIFIER_ENTRIES];
            pw_action_e  cand_action  [PW_CLASSIFIER_ENTRIES];
            logic [3:0]  cand_egress  [PW_CLASSIFIER_ENTRIES];
            logic [31:0] cand_flow    [PW_CLASSIFIER_ENTRIES];
            logic [31:0] cand_logical [PW_CLASSIFIER_ENTRIES];
            logic [7:0]  cand_prio    [PW_CLASSIFIER_ENTRIES];
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
                        cand_hit[i]     <= 1'b0;
                        cand_action[i]  <= PW_ACT_DROP;
                        cand_egress[i]  <= '0;
                        cand_flow[i]    <= '0;
                        cand_logical[i] <= '0;
                        cand_prio[i]    <= '0;
                    end
                end else begin
                    for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
                        cand_hit[i]     <= entry_hit[i];
                        cand_action[i]  <= table_i[i].action;
                        cand_egress[i]  <= table_i[i].egress_port;
                        cand_flow[i]    <= table_i[i].local_flow_id;
                        cand_logical[i] <= table_i[i].logical_if_id;
                        cand_prio[i]    <= table_i[i].priority_;
                    end
                end
            end
            always_comb begin
                for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
                    s_hit[i]     = cand_hit[i];
                    s_action[i]  = cand_action[i];
                    s_egress[i]  = cand_egress[i];
                    s_flow[i]    = cand_flow[i];
                    s_logical[i] = cand_logical[i];
                    s_prio[i]    = cand_prio[i];
                end
            end
        end else begin : g_live
            always_comb begin
                for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
                    s_hit[i]     = entry_hit[i];
                    s_action[i]  = table_i[i].action;
                    s_egress[i]  = table_i[i].egress_port;
                    s_flow[i]    = table_i[i].local_flow_id;
                    s_logical[i] = table_i[i].logical_if_id;
                    s_prio[i]    = table_i[i].priority_;
                end
            end
        end
    endgenerate

    // Priority winner: among hit rows, smallest priority_ wins; ties resolve
    // on lowest entry index. PW_CLASSIFIER_ENTRIES is tiny -> a flat mux.
    pw_class_result_t result_c;
    always_comb begin
        result_c = '0;
        for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
            if (s_hit[i]) begin
                if (!result_c.hit ||
                    s_prio[i] < s_prio[result_c.entry_index]) begin
                    result_c.hit           = 1'b1;
                    result_c.action        = s_action[i];
                    result_c.egress_port   = s_egress[i];
                    result_c.local_flow_id = s_flow[i];
                    result_c.logical_if_id = s_logical[i];
                    result_c.entry_index   = PW_ENTRY_IDX_W'(i);
                end
            end
        end

        // Default if nothing matched (or key invalid): drop.
        if (!result_c.hit) begin
            result_c.action = PW_ACT_DROP;
        end
    end

    // Output stage: combinational (0) or registered (1, 2).
    generate
        if (RESULT_STAGES == 0) begin : g_comb
            assign result_o = result_c;
        end else begin : g_reg
            pw_class_result_t result_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) result_q <= '0;
                else        result_q <= result_c;
            end
            assign result_o = result_q;
        end
    endgenerate

    wire _u2 = &{1'b0, entry_enable, 1'b0};

endmodule

`default_nettype wire
