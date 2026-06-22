/* PacketWyrm: flow compiler — global YAML flows -> per-card programming. */
#ifndef PACKETWYRM_FLOW_COMPILER_H
#define PACKETWYRM_FLOW_COMPILER_H

#include "packetwyrm/config.h"
#include "packetwyrm/csr.h"

struct pw_flow_meta {
    uint32_t global_flow_id;
    uint16_t tx_card_id;
    uint16_t rx_card_id;
    uint32_t tx_local_flow_id;
    uint32_t rx_local_flow_id;
    bool     latency_valid;              /* false for cross-card */
};

/* TEST_RX flow-id map entry: a test flow's wire flow_id -> its local checker
 * slot. Programmed into PWFPGA_WIN_FLOWID_MAP; replaces the per-flow classifier
 * TEST_RX rule so test flows scale past the classifier's routability limit. */
struct pw_flowid_map_entry {
    uint32_t flow_id;
    uint32_t local_flow_id;
};

/* Unified field+UDF classifier programming (pw_field_classifier). A field
 * comparator sources one canonical key field (enum pwfpga_fc_src); a UDF
 * comparator matches a raw inner-frame window slice. A rule ANDs a care subset
 * of the comparator bits into a {action,egress,lfid,lif} result. The compiler
 * dedups identical comparators and caps at PWFPGA_NUM_CMP / _UDF / _RULE.
 * care bit i = field comparator i; UDF comparator j = bit PWFPGA_NUM_CMP+j. */
struct pw_fc_cmp {
    uint8_t  src;           /* enum pwfpga_fc_src */
    uint32_t mask;
    uint32_t value;
};
struct pw_fc_udf {
    uint16_t offset;        /* byte offset from the inner-frame (L3) base */
    uint32_t mask;
    uint32_t value;
};
struct pw_fc_rule {
    uint16_t care;          /* bit i set -> comparator i must match */
    uint8_t  action;        /* enum pwfpga_action */
    uint8_t  egress;
    uint32_t local_flow_id;
    uint32_t logical_if_id;
    uint8_t  priority;      /* lower wins */
};

/* Hash exact-table entry (pw_hash_classifier): a header-keyed TEST_RX flow.
 * key_word[0..5] are the 6 CSR words of the 168-bit key (== the bucket the HW
 * computes); index is the bucket the SW chose with the collision-free seed. */
struct pw_fc_hash_entry {
    uint16_t index;
    uint32_t key_word[6];
    uint32_t local_flow_id;
};

struct pw_card_program {
    uint16_t card_id;

    struct pwfpga_flow_config      *flow_rows;
    size_t                          n_flow_rows;

    struct pw_flowid_map_entry     *map_entries;
    size_t                          n_map_entries;

    struct pw_fc_cmp               *fc_cmps;
    size_t                          n_fc_cmps;
    struct pw_fc_udf               *fc_udfs;
    size_t                          n_fc_udfs;
    struct pw_fc_rule              *fc_rules;
    size_t                          n_fc_rules;

    /* Hash exact table: header-keyed high-count TEST_RX flows. hash_seed is the
     * collision-free seed the compiler found for this card's hash entries. */
    uint32_t                        hash_seed;
    struct pw_fc_hash_entry        *hash_entries;
    size_t                          n_hash_entries;
};

struct pw_program {
    struct pw_card_program *per_card;    /* indexed by card_id slot */
    size_t                  n_cards;

    struct pw_flow_meta    *flow_meta;
    size_t                  n_flow_meta;
};

struct pw_program *pw_program_new(void);
void               pw_program_free(struct pw_program *p);

/* Compile a validated configuration into per-card programming records.
 * Returns PW_OK or a negative pw_status; on error, *diag may be filled. */
pw_status pw_flow_compile(const struct pw_config *cfg, struct pw_program *out, struct pw_diag *diag);

#endif
