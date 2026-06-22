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

/* Generic slice-classifier programming (header-defined / payload-agnostic
 * flows). A slice config is one {offset,mask,value} exact-match unit over the
 * parser's inner-frame header window; a rule ANDs a set of slice-match bits
 * (care mask) into a TEST_RX result for a checker slot. The compiler dedups
 * identical slices and caps at PWFPGA_NUM_SLICE / PWFPGA_NUM_SRULE. */
struct pw_slice_config {
    uint16_t offset;        /* byte offset from the inner-frame (L3) base */
    uint32_t mask;
    uint32_t value;
};
struct pw_slice_rule {
    uint16_t care_mask;     /* bit i set -> slice i must match */
    uint8_t  action;        /* enum pwfpga_action (TEST_RX for measured flows) */
    uint8_t  egress;
    uint32_t local_flow_id;
    uint8_t  priority;      /* lower wins */
};

struct pw_card_program {
    uint16_t card_id;

    struct pwfpga_classifier_entry *classifier_rows;
    size_t                          n_classifier_rows;

    struct pwfpga_flow_config      *flow_rows;
    size_t                          n_flow_rows;

    struct pw_flowid_map_entry     *map_entries;
    size_t                          n_map_entries;

    struct pw_slice_config         *slice_cfgs;
    size_t                          n_slice_cfgs;
    struct pw_slice_rule           *slice_rules;
    size_t                          n_slice_rules;
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
