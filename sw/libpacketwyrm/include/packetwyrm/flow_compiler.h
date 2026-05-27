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

struct pw_card_program {
    uint16_t card_id;

    struct pwfpga_classifier_entry *classifier_rows;
    size_t                          n_classifier_rows;

    struct pwfpga_flow_config      *flow_rows;
    size_t                          n_flow_rows;
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
