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

/* Compile-time sanity: the packed wire structs must fit in their
 * window row stride. */
_Static_assert(sizeof(struct pwfpga_classifier_entry) <= PWFPGA_CLASSIFIER_STRIDE,
               "classifier_entry exceeds PWFPGA_CLASSIFIER_STRIDE");
_Static_assert(sizeof(struct pwfpga_flow_config) <= PWFPGA_FLOW_STRIDE,
               "flow_config exceeds PWFPGA_FLOW_STRIDE");

/* Helper: word-by-word memcpy into the BAR. The BAR may be marked
 * uncached / require aligned accesses, so use volatile uint32_t
 * dst writes rather than memcpy. */
static void bar_copy_words(volatile uint32_t *dst,
                           const void *src, size_t nbytes) {
    const uint8_t *p = src;
    size_t i = 0;
    /* whole words */
    for (; i + 4 <= nbytes; i += 4) {
        uint32_t v;
        memcpy(&v, p + i, 4);
        *dst++ = v;
    }
    /* tail bytes (zero-padded to a full word) */
    if (i < nbytes) {
        uint8_t tail[4] = {0};
        memcpy(tail, p + i, nbytes - i);
        uint32_t v;
        memcpy(&v, tail, 4);
        *dst = v;
    }
}

static void bar_copy_words_out(void *dst, volatile const uint32_t *src,
                               size_t nbytes) {
    uint8_t *p = dst;
    size_t i = 0;
    for (; i + 4 <= nbytes; i += 4) {
        uint32_t v = *src++;
        memcpy(p + i, &v, 4);
    }
    if (i < nbytes) {
        uint32_t v = *src;
        uint8_t tail[4];
        memcpy(tail, &v, 4);
        memcpy(p + i, tail, nbytes - i);
    }
}

static pw_status bar_classifier_write(void *vctx, uint32_t row,
                                      const struct pwfpga_classifier_entry *e) {
    struct bar_ctx *c = vctx;
    if (!e) return PW_E_INVAL;
    uint32_t base = PWFPGA_WIN_CLASSIFIER + row * PWFPGA_CLASSIFIER_STRIDE;
    if ((size_t)base + PWFPGA_CLASSIFIER_STRIDE > c->size) return PW_E_OUT_OF_RANGE;
    bar_copy_words(reg_at(c, base), e, sizeof(*e));
    return PW_OK;
}

static pw_status bar_classifier_commit(void *vctx) {
    struct bar_ctx *c = vctx;
    if (PWFPGA_REG_CLASSIFIER_COMMIT + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *reg_at(c, PWFPGA_REG_CLASSIFIER_COMMIT) = 1u;
    return PW_OK;
}

static pw_status bar_flow_write(void *vctx, uint32_t row,
                                const struct pwfpga_flow_config *f) {
    struct bar_ctx *c = vctx;
    if (!f) return PW_E_INVAL;
    uint32_t base = PWFPGA_WIN_FLOW_TABLE + row * PWFPGA_FLOW_STRIDE;
    if ((size_t)base + PWFPGA_FLOW_STRIDE > c->size) return PW_E_OUT_OF_RANGE;
    bar_copy_words(reg_at(c, base), f, sizeof(*f));
    return PW_OK;
}

static pw_status bar_flow_commit(void *vctx) {
    struct bar_ctx *c = vctx;
    if (PWFPGA_REG_FLOW_COMMIT + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *reg_at(c, PWFPGA_REG_FLOW_COMMIT) = 1u;
    return PW_OK;
}

static pw_status bar_stats_snapshot(void *vctx) {
    struct bar_ctx *c = vctx;
    if (PWFPGA_REG_STATS_SNAPSHOT_TRIGGER + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *reg_at(c, PWFPGA_REG_STATS_SNAPSHOT_TRIGGER) = 1u;
    return PW_OK;
}

static pw_status bar_port_stats_read(void *vctx, uint8_t local_port,
                                     struct pw_port_stats *out) {
    struct bar_ctx *c = vctx;
    if (!out || local_port >= PW_PORTS_PER_CARD) return PW_E_INVAL;
    uint32_t base = PWFPGA_WIN_STATS_SNAPSHOT + local_port * PWFPGA_PORT_STATS_STRIDE;
    if ((size_t)base + sizeof(*out) > c->size) return PW_E_OUT_OF_RANGE;
    bar_copy_words_out(out, reg_at(c, base), sizeof(*out));
    return PW_OK;
}

static pw_status bar_flow_stats_read(void *vctx, uint32_t lfid,
                                     struct pw_flow_stats *out) {
    struct bar_ctx *c = vctx;
    if (!out) return PW_E_INVAL;
    uint32_t base = PWFPGA_WIN_STATS_SNAPSHOT + PWFPGA_FLOW_STATS_BASE
                  + lfid * PWFPGA_FLOW_STATS_STRIDE;
    if ((size_t)base + sizeof(*out) > c->size) return PW_E_OUT_OF_RANGE;
    bar_copy_words_out(out, reg_at(c, base), sizeof(*out));
    return PW_OK;
}

static pw_status bar_flow_hist_read(void *vctx, uint32_t lfid,
                                    uint64_t *buckets, size_t n_buckets,
                                    size_t *n_buckets_out) {
    struct bar_ctx *c = vctx;
    if (!buckets || !n_buckets_out) return PW_E_INVAL;
    uint32_t base = PWFPGA_WIN_HISTOGRAM + lfid * PWFPGA_FLOW_HIST_STRIDE;
    /* The window holds up to 64 buckets of 64 bits. */
    size_t cap = PWFPGA_FLOW_HIST_STRIDE / sizeof(uint64_t);
    if (n_buckets > cap) n_buckets = cap;
    if ((size_t)base + n_buckets * sizeof(uint64_t) > c->size) return PW_E_OUT_OF_RANGE;
    bar_copy_words_out(buckets, reg_at(c, base), n_buckets * sizeof(uint64_t));
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
