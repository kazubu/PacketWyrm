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
#include "packetwyrm/vfio.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct bar_ctx {
    void          *base;
    size_t         size;
    volatile uint32_t *reg;
    /* When use_vfio is set, the mapping is owned by `vfio` and torn
     * down with pw_vfio_close(); otherwise it came from sysfs mmap. */
    int                   use_vfio;
    struct pw_vfio_handle vfio;
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
    /* Make commit SYNCHRONOUS w.r.t. the hardware commit walk. The BRAM-staged
     * flow table (pw_flow_table_bram) reads its staging one 32-bit word per
     * dp_clk cycle on commit, so the walk takes num_flows * (PWFPGA_FLOW_STRIDE/4)
     * cycles -- worst case 32 * 64 = 2048 cycles ~= 13.1 us at 156.25 MHz. Unlike
     * the old register double-buffer (atomic shadow->live promote), the staging
     * is BOTH the write target and the walk source, so a flow_write() that lands
     * DURING the walk would tear the in-flight commit (unwalked rows pick up the
     * new data). Block here until the walk has certainly finished so the contract
     * "flow_commit() returns => safe to write the next config" holds. A read-back
     * posts the commit write first. 200 us covers the walk with a wide margin
     * (and far more flows than 32) and is negligible vs config time. */
    (void)*reg_at(c, PWFPGA_REG_FLOW_COMMIT);   /* barrier: post the commit write */
    usleep(200);
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

/* Slow-path RX (FPGA -> host): drain one punted frame from the punt RX
 * window. Polls PUNT_STATUS; if a frame is waiting, reads its metadata +
 * bytes, releases the slot (PUNT_POP) and returns the byte count. */
static int bar_slow_path_rx(void *vctx, void *buf, size_t buflen,
                            uint32_t *out_lif_id, uint64_t *out_rx_ts) {
    struct bar_ctx *c = vctx;
    if (!buf) return PW_E_INVAL;
    if ((size_t)PWFPGA_PUNT_DATA > c->size) return PW_E_OUT_OF_RANGE;

    uint32_t st = *reg_at(c, PWFPGA_REG_PUNT_STATUS);
    if (!(st & PWFPGA_PUNT_STATUS_VALID)) return 0;   /* no frame waiting */

    uint32_t info = *reg_at(c, PWFPGA_REG_PUNT_INFO);
    uint32_t len  = info & PWFPGA_PUNT_INFO_LEN_MASK;
    uint32_t lif  = *reg_at(c, PWFPGA_REG_PUNT_LIF);
    /* RX wire timestamp (servo-facing) -- read before POP releases the slot. */
    uint64_t rx_ts = (uint64_t)*reg_at(c, PWFPGA_REG_PUNT_RX_TS_LOW)
                   | ((uint64_t)*reg_at(c, PWFPGA_REG_PUNT_RX_TS_HIGH) << 32);
    if (len > PWFPGA_PUNT_MAX_FRAME) len = PWFPGA_PUNT_MAX_FRAME;  /* defensive */

    size_t copy = (len > buflen) ? buflen : len;
    uint8_t *p  = buf;
    size_t nwords = (copy + 3) / 4;
    for (size_t w = 0; w < nwords; w++) {
        uint32_t d = *reg_at(c, (uint32_t)(PWFPGA_PUNT_DATA + w * 4));
        for (int b = 0; b < 4 && (w * 4 + (size_t)b) < copy; b++)
            p[w * 4 + b] = (uint8_t)(d >> (8 * b));
    }

    *reg_at(c, PWFPGA_REG_PUNT_POP) = 1u;             /* release the slot */
    if (out_lif_id) *out_lif_id = lif;
    if (out_rx_ts)  *out_rx_ts  = rx_ts;
    return (int)copy;
}

/* Slow-path TX (host -> FPGA): inject one frame out the given egress port
 * via the inject window. Writes the frame words, sets INFO (len + egress),
 * pulses GO, and waits for the window to drain (busy clears). */
static pw_status bar_slow_path_tx(void *vctx, const void *frame, size_t len,
                                  uint32_t logical_if_id, uint8_t egress_local_port) {
    struct bar_ctx *c = vctx;
    (void)logical_if_id;                              /* TX inject targets a port, not a lif */
    if (!frame || len == 0) return PW_E_INVAL;
    if (len > PWFPGA_INJECT_MAX_FRAME) return PW_E_INVAL;
    if ((size_t)PWFPGA_INJECT_DATA + ((len + 3) & ~3u) > c->size) return PW_E_OUT_OF_RANGE;

    /* Wait for a previous inject to finish (bounded spin). */
    for (int i = 0; i < 100000; i++)
        if (!(*reg_at(c, PWFPGA_REG_INJECT_CTRL) & PWFPGA_INJECT_STATUS_BUSY)) break;
    if (*reg_at(c, PWFPGA_REG_INJECT_CTRL) & PWFPGA_INJECT_STATUS_BUSY) return PW_E_IO;

    /* Frame words (little-endian; tail bytes zero-padded to a word). */
    const uint8_t *p = frame;
    size_t nwords = (len + 3) / 4;
    for (size_t w = 0; w < nwords; w++) {
        uint32_t v = 0;
        for (int b = 0; b < 4 && (w * 4 + (size_t)b) < len; b++)
            v |= (uint32_t)p[w * 4 + b] << (8 * b);
        *reg_at(c, (uint32_t)(PWFPGA_INJECT_DATA + w * 4)) = v;
    }

    *reg_at(c, PWFPGA_REG_INJECT_INFO) =
        ((uint32_t)egress_local_port << PWFPGA_INJECT_INFO_EGRESS_SHIFT) | (uint32_t)(len & 0x3FFF);
    *reg_at(c, PWFPGA_REG_INJECT_CTRL) = PWFPGA_INJECT_CTRL_GO;

    /* Wait for the frame to drain. */
    for (int i = 0; i < 100000; i++)
        if (!(*reg_at(c, PWFPGA_REG_INJECT_CTRL) & PWFPGA_INJECT_STATUS_BUSY)) return PW_OK;
    return PW_E_IO;
}

static void bar_close(void *vctx) {
    struct bar_ctx *c = vctx;
    if (!c) return;
    if (c->use_vfio) pw_vfio_close(&c->vfio);
    else             pw_pci_close_bar0(c->base, c->size);
    free(c);
}

static const struct pw_card_backend_ops bar_ops = {
    .read32              = bar_read32,
    .write32             = bar_write32,
    .card_info           = bar_card_info,
    .flow_write          = bar_flow_write,
    .flow_commit         = bar_flow_commit,
    .stats_snapshot      = bar_stats_snapshot,
    .port_stats_read     = bar_port_stats_read,
    .flow_stats_read     = bar_flow_stats_read,
    .flow_hist_read      = bar_flow_hist_read,
    .slow_path_rx        = bar_slow_path_rx,
    .slow_path_tx        = bar_slow_path_tx,
    .close               = bar_close,
};

/* Attach the backend ops to a freshly mapped BAR. If `vfio` is
 * non-NULL the mapping is owned by VFIO (and closed via pw_vfio_close);
 * otherwise it is a sysfs mmap closed via pw_pci_close_bar0. */
static pw_status bar_backend_attach(void *base, size_t sz,
                                    const char *bdf,
                                    struct pw_vfio_handle *vfio,
                                    struct pw_card_backend *out) {
    struct bar_ctx *c = calloc(1, sizeof(*c));
    if (!c) {
        if (vfio) pw_vfio_close(vfio);
        else      pw_pci_close_bar0(base, sz);
        return PW_E_NO_RESOURCES;
    }
    c->base = base;
    c->size = sz;
    c->reg  = (volatile uint32_t *)base;
    if (vfio) { c->use_vfio = 1; c->vfio = *vfio; }
    out->ops = &bar_ops;
    out->ctx = c;
    if (bdf) snprintf(out->pci_bdf, sizeof(out->pci_bdf), "%s", bdf);
    out->card_id = 0;
    return PW_OK;
}

/* CSR BAR index for the xdma DMA-mode build: BAR0 carries the AXI-Lite
 * master CSR window. Override with PW_CSR_BAR if a build maps it
 * elsewhere. */
static int csr_bar_index(void) {
    const char *e = getenv("PW_CSR_BAR");
    if (e && *e) {
        int v = atoi(e);
        if (v >= 0 && v <= 5) return v;
    }
    return 0;
}

pw_status pw_bar_backend_open_vfio(const char *pci_bdf,
                                   struct pw_card_backend *out) {
    if (!pci_bdf || !out) return PW_E_INVAL;
    struct pw_vfio_handle vh;
    pw_status r = pw_vfio_open_bar(pci_bdf, csr_bar_index(), &vh);
    if (r != PW_OK) return r;
    return bar_backend_attach(vh.base, vh.size, pci_bdf, &vh, out);
}

pw_status pw_bar_backend_open(const char *pci_bdf, struct pw_card_backend *out) {
    if (!pci_bdf || !out) return PW_E_INVAL;

    /* Pin D0 + enable PCI memory decoding BEFORE either mmap path -- otherwise a
     * runtime-suspended (D3) or fresh-bound (Mem-) card reads all-1s on BOTH the
     * sysfs-resource and vfio mmaps, looking like a dead card. Must run here
     * (not just in the vfio path): on some hosts the sysfs-resource mmap
     * succeeds even while vfio-bound, so the vfio fallback never runs. */
    pw_vfio_prep_device(pci_bdf);

    /* PW_BACKEND=vfio|sysfs forces a path; default auto-selects sysfs
     * and falls back to VFIO when the sysfs resource mmap is denied
     * (e.g. kernel lockdown under Secure Boot). */
    const char *force = getenv("PW_BACKEND");
    if (force && strcmp(force, "vfio") == 0)
        return pw_bar_backend_open_vfio(pci_bdf, out);

    void  *base = NULL;
    size_t sz   = 0;
    pw_status r = pw_pci_open_bar0(pci_bdf, &base, &sz);
    if (r == PW_OK)
        return bar_backend_attach(base, sz, pci_bdf, NULL, out);

    if (force && strcmp(force, "sysfs") == 0)
        return r;  /* caller pinned sysfs; report its error */

    /* Auto fallback: sysfs mmap failed (often EPERM under lockdown) --
     * try VFIO before giving up. */
    pw_status rv = pw_bar_backend_open_vfio(pci_bdf, out);
    return (rv == PW_OK) ? PW_OK : r;  /* prefer the original error */
}

pw_status pw_bar_backend_open_path(const char *path, struct pw_card_backend *out) {
    if (!path || !out) return PW_E_INVAL;
    void  *base = NULL;
    size_t sz   = 0;
    pw_status r = pw_pci_open_bar0_path(path, &base, &sz);
    if (r != PW_OK) return r;
    return bar_backend_attach(base, sz, NULL, NULL, out);
}
