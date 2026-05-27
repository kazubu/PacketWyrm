/* Fake card backend: pure-software model used by unit tests and as a
 * stand-in when no real hardware is attached. Mimics the documented
 * CSR semantics closely enough that flow compilation and stats
 * aggregation can be exercised end to end on a laptop. */

#include "packetwyrm/backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FAKE_NUM_FLOWS      256
#define FAKE_NUM_CLASSIFIER 256
#define FAKE_NUM_HIST_BINS  64

struct fake_ctx {
    char     pci[PW_PCI_BDF_MAX];
    uint32_t global_ctl;
    uint32_t global_status;

    uint64_t timestamp;

    struct pw_port_stats port[PW_PORTS_PER_CARD];

    struct pwfpga_flow_config       flow[FAKE_NUM_FLOWS];
    struct pwfpga_flow_config       flow_staged[FAKE_NUM_FLOWS];
    struct pwfpga_classifier_entry  cls[FAKE_NUM_CLASSIFIER];
    struct pwfpga_classifier_entry  cls_staged[FAKE_NUM_CLASSIFIER];

    struct pw_flow_stats            flow_stats[FAKE_NUM_FLOWS];
    struct pw_flow_stats            flow_stats_snapshot[FAKE_NUM_FLOWS];
};

static pw_status fake_read32(void *vctx, uint32_t off, uint32_t *out) {
    struct fake_ctx *c = vctx;
    if (!out) return PW_E_INVAL;
    switch (off) {
    case PWFPGA_REG_DEVICE_ID:      *out = 0xA502BEEF; return PW_OK;
    case PWFPGA_REG_VERSION:        *out = 0x00010000; return PW_OK;
    case PWFPGA_REG_BUILD_ID:       *out = 0xFACE0000; return PW_OK;
    case PWFPGA_REG_GIT_HASH:       *out = 0xDEADBEEF; return PW_OK;
    case PWFPGA_REG_CAPABILITIES:   *out = PWFPGA_CAP_HAS_HISTOGRAM; return PW_OK;
    case PWFPGA_REG_NUM_LOCAL_PORTS:    *out = PW_PORTS_PER_CARD; return PW_OK;
    case PWFPGA_REG_NUM_LOCAL_FLOWS:    *out = FAKE_NUM_FLOWS; return PW_OK;
    case PWFPGA_REG_NUM_LOGICAL_IFS:    *out = 256; return PW_OK;
    case PWFPGA_REG_NUM_CLASSIFIER:     *out = FAKE_NUM_CLASSIFIER; return PW_OK;
    case PWFPGA_REG_NUM_HIST_BINS:      *out = FAKE_NUM_HIST_BINS; return PW_OK;
    case PWFPGA_REG_GLOBAL_CONTROL:     *out = c->global_ctl; return PW_OK;
    case PWFPGA_REG_GLOBAL_STATUS:      *out = c->global_status; return PW_OK;
    case PWFPGA_REG_TIMESTAMP_LOW:      *out = (uint32_t)c->timestamp; return PW_OK;
    case PWFPGA_REG_TIMESTAMP_HIGH:     *out = (uint32_t)(c->timestamp >> 32); return PW_OK;
    }
    *out = 0;
    return PW_OK;
}

static pw_status fake_write32(void *vctx, uint32_t off, uint32_t v) {
    struct fake_ctx *c = vctx;
    switch (off) {
    case PWFPGA_REG_GLOBAL_CONTROL:
        c->global_ctl = v;
        if (v & PWFPGA_GCTL_ENABLE) c->global_status |= PWFPGA_GSTAT_READY;
        if (v & PWFPGA_GCTL_ARM)    c->global_status |= PWFPGA_GSTAT_ARMED;
        if (v & PWFPGA_GCTL_RESET_COUNTERS) {
            memset(c->port, 0, sizeof(c->port));
            memset(c->flow_stats, 0, sizeof(c->flow_stats));
        }
        return PW_OK;
    case PWFPGA_REG_ERROR_STATUS:
    case PWFPGA_REG_IRQ_STATUS:
        /* W1C; nothing sticky in fake model */
        return PW_OK;
    }
    return PW_OK;
}

static pw_status fake_card_info(void *vctx, struct pw_card_info *out) {
    (void)vctx;
    if (!out) return PW_E_INVAL;
    out->device_id = 0xA502BEEF;
    out->version   = 0x00010000;
    out->build_id  = 0xFACE0000;
    out->git_hash  = 0xDEADBEEF;
    out->capabilities = PWFPGA_CAP_HAS_HISTOGRAM;
    out->num_local_ports = PW_PORTS_PER_CARD;
    out->num_local_flows = FAKE_NUM_FLOWS;
    out->num_logical_interfaces = 256;
    out->num_classifier_entries = FAKE_NUM_CLASSIFIER;
    return PW_OK;
}

static pw_status fake_classifier_write(void *vctx, uint32_t row,
                                       const struct pwfpga_classifier_entry *e) {
    struct fake_ctx *c = vctx;
    if (row >= FAKE_NUM_CLASSIFIER) return PW_E_OUT_OF_RANGE;
    c->cls_staged[row] = *e;
    return PW_OK;
}

static pw_status fake_classifier_commit(void *vctx) {
    struct fake_ctx *c = vctx;
    memcpy(c->cls, c->cls_staged, sizeof(c->cls));
    return PW_OK;
}

static pw_status fake_flow_write(void *vctx, uint32_t row,
                                 const struct pwfpga_flow_config *f) {
    struct fake_ctx *c = vctx;
    if (row >= FAKE_NUM_FLOWS) return PW_E_OUT_OF_RANGE;
    c->flow_staged[row] = *f;
    return PW_OK;
}

static pw_status fake_flow_commit(void *vctx) {
    struct fake_ctx *c = vctx;
    memcpy(c->flow, c->flow_staged, sizeof(c->flow));
    return PW_OK;
}

static pw_status fake_stats_snapshot(void *vctx) {
    struct fake_ctx *c = vctx;
    memcpy(c->flow_stats_snapshot, c->flow_stats, sizeof(c->flow_stats));
    return PW_OK;
}

static pw_status fake_port_stats_read(void *vctx, uint8_t local_port,
                                      struct pw_port_stats *out) {
    struct fake_ctx *c = vctx;
    if (!out || local_port >= PW_PORTS_PER_CARD) return PW_E_INVAL;
    *out = c->port[local_port];
    return PW_OK;
}

static pw_status fake_flow_stats_read(void *vctx, uint32_t lfid,
                                      struct pw_flow_stats *out) {
    struct fake_ctx *c = vctx;
    if (!out || lfid >= FAKE_NUM_FLOWS) return PW_E_INVAL;
    *out = c->flow_stats_snapshot[lfid];
    return PW_OK;
}

static void fake_close(void *vctx) { free(vctx); }

static const struct pw_card_backend_ops fake_ops = {
    .read32              = fake_read32,
    .write32             = fake_write32,
    .card_info           = fake_card_info,
    .classifier_write    = fake_classifier_write,
    .classifier_commit   = fake_classifier_commit,
    .flow_write          = fake_flow_write,
    .flow_commit         = fake_flow_commit,
    .stats_snapshot      = fake_stats_snapshot,
    .port_stats_read     = fake_port_stats_read,
    .flow_stats_read     = fake_flow_stats_read,
    .close               = fake_close,
};

pw_status pw_fake_backend_open(const char *pci_bdf, struct pw_card_backend *out) {
    if (!out) return PW_E_INVAL;
    struct fake_ctx *c = calloc(1, sizeof(*c));
    if (!c) return PW_E_NO_RESOURCES;
    if (pci_bdf) snprintf(c->pci, sizeof(c->pci), "%s", pci_bdf);
    out->ops = &fake_ops;
    out->ctx = c;
    if (pci_bdf) snprintf(out->pci_bdf, sizeof(out->pci_bdf), "%s", pci_bdf);
    out->card_id = 0;
    return PW_OK;
}

pw_status pw_bar_backend_open(const char *pci_bdf, struct pw_card_backend *out) {
    (void)pci_bdf;
    (void)out;
    /* Phase 4 will implement this against
     * /sys/bus/pci/devices/<bdf>/resource0 mmap. */
    return PW_E_NOT_IMPLEMENTED;
}
