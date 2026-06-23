/* Per-card CSR table programming: write a compiled pw_card_program's flow rows,
 * flow-id map, field+UDF classifier (comparators / UDFs / rules) and hash exact
 * table into a backend via its write ops. Shared by the daemon (program_backends)
 * and the unit tests, so the programming sequence has one source of truth and is
 * CI-coverable against the fake backend's per-window write recording.
 *
 * Returns the worst *hard* status seen. A backend that lacks a window returns
 * PW_E_NOT_IMPLEMENTED, treated as a soft (non-fatal) legacy case; a real fault
 * (BAR write error, card drop) is returned so the caller can report the FPGA is
 * out of sync. Does NOT touch the data-plane soft reset -- that quiesce is the
 * daemon's orchestration policy, applied around this call. */

#include "packetwyrm/flow_compiler.h"
#include "packetwyrm/backend.h"
#include "packetwyrm/csr.h"

pw_status pw_program_card_tables(const struct pw_card_backend_ops *ops, void *ctx,
                                 const struct pw_card_program *cp) {
    pw_status worst = PW_OK;
    if (!ops || !cp) return PW_E_INVAL;
    #define CHK(call) do { \
        pw_status _s = (call); \
        if (_s != PW_OK && _s != PW_E_NOT_IMPLEMENTED && worst == PW_OK) worst = _s; \
    } while (0)

    /* A backend that lacks an op the program needs can't be silently "ok" --
     * report NOT_IMPLEMENTED so an incomplete backend is visible (and a staging
     * flow_write whose commit never happens isn't passed off as programmed).
     * Flow rows need flow_write + flow_commit; map/classifier/hash need write32. */
    if (cp->n_flow_rows > 0 && (!ops->flow_write || !ops->flow_commit) && worst == PW_OK)
        worst = PW_E_NOT_IMPLEMENTED;
    if (!ops->write32 &&
        (cp->n_map_entries || cp->n_fc_cmps || cp->n_fc_udfs ||
         cp->n_fc_rules || cp->n_hash_entries) && worst == PW_OK)
        worst = PW_E_NOT_IMPLEMENTED;

    if (ops->flow_write)
        for (size_t r = 0; r < cp->n_flow_rows; r++)
            CHK(ops->flow_write(ctx, (uint32_t)r, &cp->flow_rows[r]));
    if (ops->flow_commit) CHK(ops->flow_commit(ctx));

    if (ops->write32) {
        /* TEST_RX flow-id map: one entry per structured test flow. */
        for (size_t m = 0; m < cp->n_map_entries; m++)
            CHK(ops->write32(ctx,
                PWFPGA_WIN_FLOWID_MAP + cp->map_entries[m].flow_id * 4u,
                PWFPGA_FLOWID_MAP_VALID | cp->map_entries[m].local_flow_id));

        /* Unified field+UDF classifier: comparators, UDFs, then rules. */
        for (size_t i = 0; i < cp->n_fc_cmps; i++) {
            const struct pw_fc_cmp *c = &cp->fc_cmps[i];
            CHK(ops->write32(ctx, PWFPGA_FC_CMP_SRC(PWFPGA_WIN_FC_CMP, i), c->src));
            CHK(ops->write32(ctx, PWFPGA_FC_CMP_MASK(PWFPGA_WIN_FC_CMP, i), c->mask));
            CHK(ops->write32(ctx, PWFPGA_FC_CMP_VALUE(PWFPGA_WIN_FC_CMP, i), c->value));
        }
        for (size_t i = 0; i < cp->n_fc_udfs; i++) {
            const struct pw_fc_udf *u = &cp->fc_udfs[i];
            CHK(ops->write32(ctx, PWFPGA_FC_UDF_OFFSET(PWFPGA_WIN_FC_UDF, i), u->offset));
            CHK(ops->write32(ctx, PWFPGA_FC_UDF_MASK(PWFPGA_WIN_FC_UDF, i), u->mask));
            CHK(ops->write32(ctx, PWFPGA_FC_UDF_VALUE(PWFPGA_WIN_FC_UDF, i), u->value));
        }
        for (size_t i = 0; i < cp->n_fc_rules; i++) {
            const struct pw_fc_rule *rl = &cp->fc_rules[i];
            CHK(ops->write32(ctx, PWFPGA_FC_RULE_WORD0(PWFPGA_WIN_FC_RULE, i),
                PWFPGA_FC_RULE_W0(rl->care, rl->action, rl->egress, rl->priority, 1)));
            CHK(ops->write32(ctx, PWFPGA_FC_RULE_LFID(PWFPGA_WIN_FC_RULE, i), rl->local_flow_id));
            CHK(ops->write32(ctx, PWFPGA_FC_RULE_LIF(PWFPGA_WIN_FC_RULE, i), rl->logical_if_id));
        }

        /* Hash exact table: mask words + seed, then each entry (key words, then
         * the control word commits at the SW-chosen bucket index). */
        if (cp->n_hash_entries > 0) {
            for (unsigned w = 0; w < PWFPGA_HASH_KEY_WORDS; w++)
                CHK(ops->write32(ctx, PWFPGA_HASH_MASK_WORD(PWFPGA_WIN_HASH_MASK, w),
                                 cp->hash_mask[w]));
            CHK(ops->write32(ctx, PWFPGA_REG_HASH_SEED, cp->hash_seed));
            for (size_t i = 0; i < cp->n_hash_entries; i++) {
                const struct pw_fc_hash_entry *he = &cp->hash_entries[i];
                for (unsigned w = 0; w < PWFPGA_HASH_KEY_WORDS; w++)
                    CHK(ops->write32(ctx, PWFPGA_HASH_KEY_WORD(PWFPGA_WIN_FC_HASH, he->index, w),
                                     he->key_word[w]));
                CHK(ops->write32(ctx, PWFPGA_HASH_CTRL(PWFPGA_WIN_FC_HASH, he->index),
                                 PWFPGA_HASH_CTRL_VALID | he->local_flow_id));
            }
        }
    }
    #undef CHK
    return worst;
}
