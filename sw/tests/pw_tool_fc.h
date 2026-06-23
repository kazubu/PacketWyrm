/* Small helper for the standalone HW test tools: program one field-classifier
 * rule keyed on {ingress_port, udp_dst} -> {action, egress, lfid, lif}. Replaces
 * the retired classifier_write path (the legacy pw_classifier is gone; 0x2000 is
 * now the field-classifier window). Uses field comparators cmp0 (ingress) +
 * cmp0+1 (udp_dst) and rule rule_i. */
#ifndef PW_TOOL_FC_H
#define PW_TOOL_FC_H

#include "packetwyrm/backend.h"
#include "packetwyrm/csr.h"

/* Returns the worst write status (PW_OK if all writes succeeded). Callers should
 * check it -- a failed BAR write here means the classifier wasn't programmed, so
 * proceeding to "measure" would report misleading HW diagnostics. */
static inline pw_status pw_tool_fc_ing_udp(const struct pw_card_backend_ops *o, void *ctx,
                                           unsigned cmp0, unsigned rule_i,
                                           uint8_t ingress, uint16_t udp_dst,
                                           uint8_t action, uint8_t egress,
                                           uint32_t lfid, uint32_t lif) {
    if (!o->write32) return PW_E_NOT_IMPLEMENTED;
    pw_status s = PW_OK, r;
    #define PW_FC_W(call) do { r = (call); if (r != PW_OK && s == PW_OK) s = r; } while (0)
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_SRC(PWFPGA_WIN_FC_CMP, cmp0),     PWFPGA_FC_SRC_INGRESS));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_MASK(PWFPGA_WIN_FC_CMP, cmp0),    0xFu));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_VALUE(PWFPGA_WIN_FC_CMP, cmp0),   ingress));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_SRC(PWFPGA_WIN_FC_CMP, cmp0 + 1),  PWFPGA_FC_SRC_L4_DST));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_MASK(PWFPGA_WIN_FC_CMP, cmp0 + 1), 0xFFFFu));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_CMP_VALUE(PWFPGA_WIN_FC_CMP, cmp0 + 1), udp_dst));
    uint16_t care = (uint16_t)((1u << cmp0) | (1u << (cmp0 + 1)));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_RULE_WORD0(PWFPGA_WIN_FC_RULE, rule_i),
                       PWFPGA_FC_RULE_W0(care, action, egress, 5u, 1u)));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_RULE_LFID(PWFPGA_WIN_FC_RULE, rule_i), lfid));
    PW_FC_W(o->write32(ctx, PWFPGA_FC_RULE_LIF(PWFPGA_WIN_FC_RULE, rule_i), lif));
    #undef PW_FC_W
    return s;
}

#endif
