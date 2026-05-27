/* PacketWyrm: real BAR-mmap card backend.
 *
 * Drives a PacketWyrm FPGA over BAR0 from userspace. The mapping
 * comes from /sys/bus/pci/devices/<bdf>/resource0 in production,
 * and from any other file path (e.g. a tmpfs file) in tests.
 *
 * Phase 1 bitstream only ships the identity / control / timestamp
 * registers and the placeholder error register. Classifier / flow
 * table windows are not implemented yet in RTL, so the backend
 * returns PW_E_NOT_IMPLEMENTED on those writes - honest rather
 * than silently dropping configuration. Phase 5 turns these on
 * when the RTL grows the windows. */

#include "packetwyrm/backend.h"
#include "packetwyrm/csr.h"
#include "packetwyrm/pci.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct bar_ctx {
    void          *base;
    size_t         size;
    volatile uint32_t *reg;
};

static volatile uint32_t *reg_at(struct bar_ctx *c, uint32_t off) {
    return (volatile uint32_t *)((volatile uint8_t *)c->base + off);
}

static pw_status bar_read32(void *vctx, uint32_t off, uint32_t *out) {
    struct bar_ctx *c = vctx;
    if (!out) return PW_E_INVAL;
    if (off + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *out = *reg_at(c, off);
    return PW_OK;
}

static pw_status bar_write32(void *vctx, uint32_t off, uint32_t v) {
    struct bar_ctx *c = vctx;
    if (off + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *reg_at(c, off) = v;
    return PW_OK;
}

static pw_status bar_card_info(void *vctx, struct pw_card_info *out) {
    struct bar_ctx *c = vctx;
    if (!out) return PW_E_INVAL;
    out->device_id              = *reg_at(c, PWFPGA_REG_DEVICE_ID);
    out->version                = *reg_at(c, PWFPGA_REG_VERSION);
    out->build_id               = *reg_at(c, PWFPGA_REG_BUILD_ID);
    out->git_hash               = *reg_at(c, PWFPGA_REG_GIT_HASH);
    out->capabilities           = *reg_at(c, PWFPGA_REG_CAPABILITIES);
    out->num_local_ports        = (uint16_t)*reg_at(c, PWFPGA_REG_NUM_LOCAL_PORTS);
    out->num_local_flows        = (uint16_t)*reg_at(c, PWFPGA_REG_NUM_LOCAL_FLOWS);
    out->num_logical_interfaces = (uint16_t)*reg_at(c, PWFPGA_REG_NUM_LOGICAL_IFS);
    out->num_classifier_entries = (uint16_t)*reg_at(c, PWFPGA_REG_NUM_CLASSIFIER);
    return PW_OK;
}

/* Classifier / flow table windows are not yet present in the Phase 1
 * RTL. Return PW_E_NOT_IMPLEMENTED honestly so packetwyrmd surfaces
 * the gap instead of silently dropping configuration. */
static pw_status bar_classifier_write(void *vctx, uint32_t row,
                                      const struct pwfpga_classifier_entry *e) {
    (void)vctx; (void)row; (void)e;
    return PW_E_NOT_IMPLEMENTED;
}
static pw_status bar_classifier_commit(void *vctx) {
    (void)vctx;
    return PW_E_NOT_IMPLEMENTED;
}
static pw_status bar_flow_write(void *vctx, uint32_t row,
                                const struct pwfpga_flow_config *f) {
    (void)vctx; (void)row; (void)f;
    return PW_E_NOT_IMPLEMENTED;
}
static pw_status bar_flow_commit(void *vctx) {
    (void)vctx;
    return PW_E_NOT_IMPLEMENTED;
}

static pw_status bar_stats_snapshot(void *vctx) {
    /* No-op in Phase 1: stats snapshot window is not yet implemented. */
    (void)vctx;
    return PW_OK;
}

static pw_status bar_port_stats_read(void *vctx, uint8_t local_port,
                                     struct pw_port_stats *out) {
    (void)vctx;
    if (!out || local_port >= PW_PORTS_PER_CARD) return PW_E_INVAL;
    /* Phase 1 has no MAC; counters read zero. The structure is valid
     * once Phase 2 populates port[0/1]_* in BAR0. */
    memset(out, 0, sizeof(*out));
    return PW_OK;
}

static pw_status bar_flow_stats_read(void *vctx, uint32_t lfid,
                                     struct pw_flow_stats *out) {
    (void)vctx; (void)lfid;
    if (!out) return PW_E_INVAL;
    memset(out, 0, sizeof(*out));
    return PW_OK;
}

static pw_status bar_flow_hist_read(void *vctx, uint32_t lfid,
                                    uint64_t *buckets, size_t n_buckets,
                                    size_t *n_buckets_out) {
    (void)vctx; (void)lfid;
    if (!buckets || !n_buckets_out) return PW_E_INVAL;
    /* Phase 1 RTL has no histogram window yet. Return zeros so the
     * RPC shape is stable; the real implementation reads the CSR
     * histogram window once Phase 3 RTL ships. */
    for (size_t i = 0; i < n_buckets; i++) buckets[i] = 0;
    *n_buckets_out = n_buckets;
    return PW_OK;
}

static void bar_close(void *vctx) {
    struct bar_ctx *c = vctx;
    if (!c) return;
    pw_pci_close_bar0(c->base, c->size);
    free(c);
}

static const struct pw_card_backend_ops bar_ops = {
    .read32              = bar_read32,
    .write32             = bar_write32,
    .card_info           = bar_card_info,
    .classifier_write    = bar_classifier_write,
    .classifier_commit   = bar_classifier_commit,
    .flow_write          = bar_flow_write,
    .flow_commit         = bar_flow_commit,
    .stats_snapshot      = bar_stats_snapshot,
    .port_stats_read     = bar_port_stats_read,
    .flow_stats_read     = bar_flow_stats_read,
    .flow_hist_read      = bar_flow_hist_read,
    .close               = bar_close,
};

static pw_status bar_backend_attach(void *base, size_t sz,
                                    const char *bdf,
                                    struct pw_card_backend *out) {
    struct bar_ctx *c = calloc(1, sizeof(*c));
    if (!c) { pw_pci_close_bar0(base, sz); return PW_E_NO_RESOURCES; }
    c->base = base;
    c->size = sz;
    c->reg  = (volatile uint32_t *)base;
    out->ops = &bar_ops;
    out->ctx = c;
    if (bdf) snprintf(out->pci_bdf, sizeof(out->pci_bdf), "%s", bdf);
    out->card_id = 0;
    return PW_OK;
}

pw_status pw_bar_backend_open(const char *pci_bdf, struct pw_card_backend *out) {
    if (!pci_bdf || !out) return PW_E_INVAL;
    void  *base = NULL;
    size_t sz   = 0;
    pw_status r = pw_pci_open_bar0(pci_bdf, &base, &sz);
    if (r != PW_OK) return r;
    return bar_backend_attach(base, sz, pci_bdf, out);
}

pw_status pw_bar_backend_open_path(const char *path, struct pw_card_backend *out) {
    if (!path || !out) return PW_E_INVAL;
    void  *base = NULL;
    size_t sz   = 0;
    pw_status r = pw_pci_open_bar0_path(path, &base, &sz);
    if (r != PW_OK) return r;
    return bar_backend_attach(base, sz, NULL, out);
}
