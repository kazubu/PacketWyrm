/* Per-card CSR table programming: write a compiled pw_card_program's flow rows,
 * flow-id map, field+UDF classifier (comparators / UDFs / rules) and hash exact
 * table into a backend via its write ops. Shared by the daemon (program_backends)
 * and the unit tests, so the programming sequence has one source of truth and is
 * CI-coverable against the fake backend's per-window write recording.
 *
 * The resulting table state is FULLY DETERMINED by the program: every slot up to
 * capacity is written, the configured entries enabled and all others invalidated
 * (flow rows disabled, rules enable=0, hash buckets + flow-id-map entries
 * valid=0). Without this, a reload that shrinks the config would leave the old
 * (now-deleted) flows / rules / hash / map entries live, since the RTL commit
 * just copies shadow->live without invalidating un-written rows.
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

    /* Validate the program's counts/indices against the fixed CSR-window
     * capacities BEFORE any write. The daemon's compiler already constrains
     * these, but this is a public libpacketwyrm entry: a hand-built or corrupt
     * pw_card_program must not turn an out-of-range count/index into a CSR
     * offset that lands in a DIFFERENT (still in-BAR, so size-check-passing)
     * window -- e.g. a wild map flow_id indexing out of the flow-id map into
     * the classifier, or a hash index out of the hash window into the flow
     * table. Reject the whole program up front rather than mis-program. */
    if (cp->n_fc_cmps      > PWFPGA_NUM_CMP)          return PW_E_INVAL;
    if (cp->n_fc_udfs      > PWFPGA_NUM_UDF)          return PW_E_INVAL;
    if (cp->n_fc_rules     > PWFPGA_NUM_RULE)         return PW_E_INVAL;
    if (cp->n_hash_entries > PWFPGA_HASH_DEPTH)       return PW_E_INVAL;
    if (cp->n_flow_rows    && !cp->flow_rows)         return PW_E_INVAL;
    if (cp->n_map_entries  && !cp->map_entries)       return PW_E_INVAL;
    if (cp->n_fc_cmps      && !cp->fc_cmps)           return PW_E_INVAL;
    if (cp->n_fc_udfs      && !cp->fc_udfs)           return PW_E_INVAL;
    if (cp->n_fc_rules     && !cp->fc_rules)          return PW_E_INVAL;
    if (cp->n_hash_entries && !cp->hash_entries)      return PW_E_INVAL;
    for (size_t m = 0; m < cp->n_map_entries; m++)
        if (cp->map_entries[m].flow_id >= PWFPGA_FLOWID_MAP_DEPTH) return PW_E_INVAL;
    for (size_t i = 0; i < cp->n_hash_entries; i++)
        if (cp->hash_entries[i].index >= PWFPGA_HASH_DEPTH)        return PW_E_INVAL;

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

    /* Flow rows: configured rows, then disabled (zeroed) rows up to the card's
     * capacity so a shrunk config can't leave stale generators running. */
    if (ops->flow_write) {
        unsigned nflows = (unsigned)cp->n_flow_rows;
        struct pw_card_info info = {0};
        if (ops->card_info && ops->card_info(ctx, &info) == PW_OK &&
            info.num_local_flows > nflows)
            nflows = info.num_local_flows;
        struct pwfpga_flow_config zf = {0};
        for (unsigned r = 0; r < nflows; r++)
            CHK(ops->flow_write(ctx, r,
                                r < cp->n_flow_rows ? &cp->flow_rows[r] : &zf));
    }
    if (ops->flow_commit) CHK(ops->flow_commit(ctx));

    if (ops->write32) {
        /* TEST_RX flow-id map: invalidate every entry, then program the
         * configured (structured) test flows. */
        for (uint32_t i = 0; i < PWFPGA_FLOWID_MAP_DEPTH; i++)
            CHK(ops->write32(ctx, PWFPGA_WIN_FLOWID_MAP + i * 4u, 0u));
        for (size_t m = 0; m < cp->n_map_entries; m++)
            CHK(ops->write32(ctx,
                PWFPGA_WIN_FLOWID_MAP + cp->map_entries[m].flow_id * 4u,
                PWFPGA_FLOWID_MAP_VALID | cp->map_entries[m].local_flow_id));

        /* Field+UDF classifier: configured comparators / UDFs, then ALL rules
         * (configured enabled, the rest enable=0) so deleted punt/forward/
         * classify rules don't persist. Unused comparators/UDFs are harmless --
         * only an enabled rule's care mask references them. */
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
        for (unsigned i = 0; i < PWFPGA_NUM_RULE; i++) {
            if (i < cp->n_fc_rules) {
                const struct pw_fc_rule *rl = &cp->fc_rules[i];
                CHK(ops->write32(ctx, PWFPGA_FC_RULE_WORD0(PWFPGA_WIN_FC_RULE, i),
                    PWFPGA_FC_RULE_W0(rl->care, rl->action, rl->egress, rl->priority, 1)));
                CHK(ops->write32(ctx, PWFPGA_FC_RULE_LFID(PWFPGA_WIN_FC_RULE, i), rl->local_flow_id));
                CHK(ops->write32(ctx, PWFPGA_FC_RULE_LIF(PWFPGA_WIN_FC_RULE, i), rl->logical_if_id));
            } else {
                /* disabled rule (enable bit clear) */
                CHK(ops->write32(ctx, PWFPGA_FC_RULE_WORD0(PWFPGA_WIN_FC_RULE, i),
                    PWFPGA_FC_RULE_W0(0, 0, 0, 0, 0)));
            }
        }

        /* Hash exact table: invalidate every bucket, then (if any) write the
         * mask + seed + configured entries. Buckets are sparse-indexed, so a
         * shrunk config must clear all DEPTH buckets, not just the new ones. */
        for (unsigned b = 0; b < PWFPGA_HASH_DEPTH; b++)
            CHK(ops->write32(ctx, PWFPGA_HASH_CTRL(PWFPGA_WIN_FC_HASH, b), 0u));
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
