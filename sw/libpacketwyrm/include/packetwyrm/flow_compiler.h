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
    bool     latency_valid;              /* true = same-card (counter-direct, exact).
                                          * false = cross-card: latency is STILL
                                          * reported, via HW lat_correction + J5
                                          * sync (latency_method "gpio-corrected").
                                          * This flag now distinguishes the method,
                                          * not availability. */
    bool     rx_slot_valid;              /* true = this flow has a real RX checker
                                          * slot (rx_local_flow_id is meaningful).
                                          * FALSE for background (load) flows: they
                                          * are TX-only and allocate no RX row/slot,
                                          * so rx_local_flow_id must NOT be read
                                          * (stats) or written (lat_correction) --
                                          * doing so would alias a real flow's
                                          * slot on the RX card. */
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
    uint32_t key_word[11];      /* already masked (key & hash_mask) */
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
     * collision-free seed the compiler found; hash_mask is the global key mask
     * (11 words) -- keyed-field bits set, modifier-randomized/cleared bits 0. */
    uint32_t                        hash_seed;
    uint32_t                        hash_mask[11];
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

/* Write one compiled per-card program's tables (flow rows + commit, flow-id map,
 * field+UDF classifier, hash table) into a backend. Returns the worst hard
 * status (NOT_IMPLEMENTED treated as soft). Shared by the daemon + tests. */
struct pw_card_backend_ops;
pw_status pw_program_card_tables(const struct pw_card_backend_ops *ops, void *ctx,
                                 const struct pw_card_program *cp);

/* As pw_program_card_tables, but on a rejection fills `*diag` (if non-NULL)
 * with the concrete numbers instead of only a status code -- e.g. a program
 * asking for more measured flow rows than the device implements
 * (num_local_flows) reports "card0: 33 flow rows requested but device supports
 * 32 (num_local_flows); reduce measured flows or mark some background". Lets a
 * caller (daemon config.load / CLI) surface the actual capacity to the user
 * rather than a bare "out of resources". pw_program_card_tables() is the
 * diag==NULL case. */
pw_status pw_program_card_tables_diag(const struct pw_card_backend_ops *ops,
                                      void *ctx, const struct pw_card_program *cp,
                                      struct pw_diag *diag);

#endif
