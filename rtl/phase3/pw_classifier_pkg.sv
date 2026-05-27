// PacketWyrm classifier types.

`ifndef PW_CLASSIFIER_PKG_SV
`define PW_CLASSIFIER_PKG_SV

package pw_classifier_pkg;

    typedef enum logic [2:0] {
        PW_ACT_DROP           = 3'd0,
        PW_ACT_TEST_RX        = 3'd1,
        PW_ACT_PUNT_TO_HOST   = 3'd2,
        PW_ACT_MIRROR_TO_HOST = 3'd3,
        PW_ACT_FORWARD_PORT   = 3'd4
    } pw_action_e;

    parameter int PW_CLASSIFIER_ENTRIES = 8;
    parameter int PW_ENTRY_IDX_W        = $clog2(PW_CLASSIFIER_ENTRIES);

    // Fields the parser extracts; the classifier matches a subset of
    // them via per-entry mask bits. Phase 3 skeleton supports exact
    // / wildcard at the field granularity (one mask bit per field).
    typedef struct packed {
        logic         valid;            // parse succeeded
        logic         is_test;          // test_magic match
        logic [3:0]   ingress_port;
        logic [15:0]  ethertype;
        logic         vlan_valid;
        logic [11:0]  vlan_id;
        logic [7:0]   l3_proto;
        logic [31:0]  ipv4_src;
        logic [31:0]  ipv4_dst;
        logic [15:0]  udp_src;
        logic [15:0]  udp_dst;
        logic [31:0]  test_magic;
        logic [31:0]  test_flow_id;
        logic [63:0]  test_sequence;
        logic [63:0]  test_tx_timestamp;
    } pw_match_key_t;

    // Per-entry mask. Each bit enables one field for matching.
    typedef struct packed {
        logic         match_ingress_port;
        logic         match_ethertype;
        logic         match_vlan_id;
        logic         match_l3_proto;
        logic         match_ipv4_src;
        logic         match_ipv4_dst;
        logic         match_udp_src;
        logic         match_udp_dst;
        logic         match_is_test;     // require key.is_test == 1
        logic         match_flow_id;     // match test header flow_id
    } pw_match_mask_t;

    typedef struct packed {
        logic            enable;
        pw_action_e      action;
        logic [3:0]      egress_port;
        logic [31:0]     local_flow_id;
        logic [31:0]     logical_if_id;
        logic [7:0]      priority_;     // lower wins
        pw_match_mask_t  mask;
        pw_match_key_t   key;
    } pw_classifier_entry_t;

    typedef pw_classifier_entry_t [PW_CLASSIFIER_ENTRIES-1:0]
        pw_classifier_table_t;

    typedef struct packed {
        logic             hit;
        pw_action_e       action;
        logic [3:0]       egress_port;
        logic [31:0]      local_flow_id;
        logic [31:0]      logical_if_id;
        logic [PW_ENTRY_IDX_W-1:0] entry_index;
    } pw_class_result_t;

endpackage : pw_classifier_pkg

`endif
