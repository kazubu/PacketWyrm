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

module pw_classifier (
    input  wire                       clk,        // combinational lookup; clock kept for future pipelining
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

            logic m_iport, m_etype, m_vlan, m_l3, m_ipsrc, m_ipdst,
                  m_usrc, m_udst, m_test, m_flow;

            assign m_iport = ~e.mask.match_ingress_port |
                              (key_i.ingress_port == e.key.ingress_port);
            assign m_etype = ~e.mask.match_ethertype    |
                              (key_i.ethertype     == e.key.ethertype);
            assign m_vlan  = ~e.mask.match_vlan_id      |
                              (key_i.vlan_valid && key_i.vlan_id == e.key.vlan_id);
            assign m_l3    = ~e.mask.match_l3_proto     |
                              (key_i.l3_proto      == e.key.l3_proto);
            assign m_ipsrc = ~e.mask.match_ipv4_src     |
                              (key_i.ipv4_src      == e.key.ipv4_src);
            assign m_ipdst = ~e.mask.match_ipv4_dst     |
                              (key_i.ipv4_dst      == e.key.ipv4_dst);
            assign m_usrc  = ~e.mask.match_udp_src      |
                              (key_i.udp_src       == e.key.udp_src);
            assign m_udst  = ~e.mask.match_udp_dst      |
                              (key_i.udp_dst       == e.key.udp_dst);
            assign m_test  = ~e.mask.match_is_test      | key_i.is_test;
            assign m_flow  = ~e.mask.match_flow_id      |
                              (key_i.is_test &&
                               key_i.test_flow_id  == e.key.test_flow_id);

            assign entry_hit[gi] = e.enable && key_valid_i &&
                                   m_iport & m_etype & m_vlan & m_l3 &
                                   m_ipsrc & m_ipdst & m_usrc & m_udst &
                                   m_test  & m_flow;
        end
    endgenerate

    // Priority winner: among hit rows, pick the one with smallest
    // priority_. Ties resolved by lowest entry index. Implemented as
    // a small selection loop; PW_CLASSIFIER_ENTRIES is tiny so this
    // synthesises into a flat mux.
    always_comb begin
        result_o = '0;
        for (int i = 0; i < PW_CLASSIFIER_ENTRIES; i++) begin
            if (entry_hit[i]) begin
                if (!result_o.hit ||
                    table_i[i].priority_ < table_i[result_o.entry_index].priority_) begin
                    result_o.hit          = 1'b1;
                    result_o.action       = table_i[i].action;
                    result_o.egress_port  = table_i[i].egress_port;
                    result_o.local_flow_id = table_i[i].local_flow_id;
                    result_o.logical_if_id = table_i[i].logical_if_id;
                    result_o.entry_index   = PW_ENTRY_IDX_W'(i);
                end
            end
        end

        // Default if nothing matched (or key invalid): drop.
        if (!result_o.hit) begin
            result_o.action = PW_ACT_DROP;
        end
    end

    wire _u2 = &{1'b0, entry_enable, 1'b0};

endmodule

`default_nettype wire
