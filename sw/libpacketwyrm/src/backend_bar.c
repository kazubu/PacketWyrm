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
#include <sys/mman.h>
#include <unistd.h>

/* --- DMA slow-path state (CAP_HAS_DMA build; XDMA AXI-Stream) -----------
 * H2C (inject): single descriptor, RUN + poll per frame (host-driven, one at a
 * time). C2H (punt): a CIRCULAR descriptor ring the engine runs continuously --
 * never stopped/re-armed per frame. That matters because a per-frame stop->run
 * wedges/settles the engine (an earlier single-descriptor-inline-rearm attempt
 * hit 100% loss), and a deferred re-arm left a ~100 ms unarmed gap that dropped
 * punt frames -> cRPD retransmits -> multi-second RTT + no OSPF/IS-IS adjacency.
 * With a circular ring the engine always has posted buffers; the host reaps by a
 * consumer index vs the completed-descriptor count (each frame exactly once). */
#define PW_DMA_FRAME_CAP  9216u   /* jumbo frame buffer (matches RTL inject/punt) */
#define PW_DMA_HDR_LEN    8u      /* pw_dma_slowpath in-band metadata header */
#define PW_DMA_RX_RING    16u     /* C2H circular ring depth (descriptors + buffers) */

struct dma_state {
    void    *xdma_regs;       /* mmap of BAR1 = XDMA DMA/SGDMA control registers */
    size_t   xdma_regs_len;
    void    *pool;            /* one page-aligned, DMA-mapped region */
    size_t   pool_len;
    uint64_t pool_iova;       /* identity IOVA of pool (== (uintptr_t)pool) */
    /* sub-regions carved out of pool (host VA + device IOVA) */
    struct pwfpga_xdma_desc *h2c_desc;  uint64_t h2c_desc_iova;
    uint8_t *tx_buf;   uint64_t tx_iova;   /* H2C (inject) frame buffer */
    struct pwfpga_xdma_desc *c2h_ring; uint64_t c2h_ring_iova;  /* [PW_DMA_RX_RING], circular */
    uint8_t *rx_bufs;  uint64_t rx_bufs_iova;                   /* N * FRAME_CAP */
    uint32_t h2c_cmpl_base;   /* completed-desc-count baseline (H2C) */
    uint32_t c2h_cmpl_base;   /* completed-desc-count at ring arm (C2H) */
    uint32_t rx_consumed;     /* C2H frames reaped since arm */
    int      c2h_armed;       /* the C2H ring is running */
};

struct bar_ctx {
    void          *base;
    size_t         size;
    volatile uint32_t *reg;
    /* CSR window offset within BAR0: 0 on the legacy 64 KB BAR, or
     * PWFPGA_CSR_DMA_OFFSET (0x10000) on the DMA build where the XDMA control
     * registers occupy the low half. Added to every CSR (reg_at) access. */
    uint32_t              csr_off;
    /* When use_vfio is set, the mapping is owned by `vfio` and torn
     * down with pw_vfio_close(); otherwise it came from sysfs mmap. */
    int                   use_vfio;
    struct pw_vfio_handle vfio;
    /* Non-NULL when the XDMA DMA slow path is active (DMA build + vfio). */
    struct dma_state     *dma;
};

/* CSR-window accessor: the AXI-Lite CSR sits at base + csr_off + off. */
static volatile uint32_t *reg_at(struct bar_ctx *c, uint32_t off) {
    return (volatile uint32_t *)((volatile uint8_t *)c->base + c->csr_off + off);
}

static pw_status bar_read32(void *vctx, uint32_t off, uint32_t *out) {
    struct bar_ctx *c = vctx;
    if (!out) return PW_E_INVAL;
    if ((size_t)c->csr_off + off + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *out = *reg_at(c, off);
    return PW_OK;
}

static pw_status bar_write32(void *vctx, uint32_t off, uint32_t v) {
    struct bar_ctx *c = vctx;
    if ((size_t)c->csr_off + off + 4 > c->size) return PW_E_OUT_OF_RANGE;
    *reg_at(c, off) = v;
    return PW_OK;
}

/* XDMA control-register accessors: the XDMA DMA/SGDMA registers live on a
 * SEPARATE BAR (BAR1, mapped into dma->xdma_regs), NOT in the CSR BAR (BAR0).
 * Verified on silicon 2026-07-04: BAR0[0]=0xa502beef (CSR), BAR1[0]=0x1fc08006
 * (XDMA channel id). Only valid when c->dma is set. */
static void xdma_wr(struct bar_ctx *c, uint32_t off, uint32_t v) {
    *(volatile uint32_t *)((volatile uint8_t *)c->dma->xdma_regs + off) = v;
}
static uint32_t xdma_rd(struct bar_ctx *c, uint32_t off) {
    return *(volatile uint32_t *)((volatile uint8_t *)c->dma->xdma_regs + off);
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
_Static_assert(sizeof(struct pwfpga_xdma_desc) == 32,
               "XDMA SG descriptor must be exactly 32 bytes (PG195)");

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

/* ==================== XDMA AXI-Stream DMA slow path ====================
 * Carve a single DMA-mapped pool into two descriptors + two jumbo frame
 * buffers; drive the XDMA H2C (inject) / C2H (punt) channels in poll mode. */

static void desc_fill(struct pwfpga_xdma_desc *dsc, uint32_t ctrl_flags,
                      uint32_t bytes, uint64_t src, uint64_t dst) {
    dsc->control     = PWFPGA_XDMA_DESC_MAGIC | ctrl_flags;
    dsc->bytes       = bytes;
    dsc->src_addr_lo = (uint32_t)src;         dsc->src_addr_hi = (uint32_t)(src >> 32);
    dsc->dst_addr_lo = (uint32_t)dst;         dsc->dst_addr_hi = (uint32_t)(dst >> 32);
    dsc->next_lo     = 0;                      dsc->next_hi     = 0;
}

static pw_status dma_setup(struct bar_ctx *c) {
    /* Map BAR1 (the XDMA control-register BAR) on the already-open vfio device.
     * The XDMA channel/SGDMA registers live here, distinct from the BAR0 CSR. */
    void  *xregs = NULL;
    size_t xlen  = 0;
    pw_status rr = pw_vfio_map_region(&c->vfio, 1, &xregs, &xlen);
    if (rr != PW_OK) return rr;

    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) ps = 4096;
    /* h2c_desc + c2h_ring[N] descriptors (<=1 KB), then TX buffer + N RX buffers */
    size_t need = 1024 + (1u + PW_DMA_RX_RING) * (size_t)PW_DMA_FRAME_CAP;
    size_t len  = ((need + (size_t)ps - 1) / (size_t)ps) * (size_t)ps;
    void *pool = NULL;
    if (posix_memalign(&pool, (size_t)ps, len) != 0 || !pool) {
        munmap(xregs, xlen); return PW_E_NO_RESOURCES;
    }
    memset(pool, 0, len);
    uint64_t iova = 0;
    pw_status r = pw_vfio_map_dma(&c->vfio, pool, len, &iova);
    if (r != PW_OK) { free(pool); munmap(xregs, xlen); return r; }

    struct dma_state *d = calloc(1, sizeof(*d));
    if (!d) {
        pw_vfio_unmap_dma(&c->vfio, iova, len); free(pool); munmap(xregs, xlen);
        return PW_E_NO_RESOURCES;
    }
    d->xdma_regs = xregs; d->xdma_regs_len = xlen;
    d->pool = pool; d->pool_len = len; d->pool_iova = iova;
    uint8_t *p = pool;
    /* Layout (must NOT overlap): h2c_desc @0 (32 B), c2h_ring @64 (N*32 B), then
     * the TX buffer AFTER the whole ring (64 B-aligned), then N RX buffers. A
     * previous off_tx=512 overlapped ring descriptors 14/15 (64 + 16*32 = 576),
     * so injecting corrupted them and the ring broke once it wrapped past idx 13. */
    size_t off_ring   = 64;
    size_t ring_bytes = (size_t)PW_DMA_RX_RING * sizeof(struct pwfpga_xdma_desc);
    size_t off_tx     = ((off_ring + ring_bytes + 63) / 64) * 64;   /* 64B-aligned, past the ring */
    size_t off_rx     = off_tx + PW_DMA_FRAME_CAP;
    d->h2c_desc = (void *)(p + 0);         d->h2c_desc_iova = iova + 0;          /* 32 B */
    d->c2h_ring = (void *)(p + off_ring);  d->c2h_ring_iova = iova + off_ring;   /* N * 32 B */
    d->tx_buf   = p + off_tx;              d->tx_iova       = iova + off_tx;
    d->rx_bufs  = p + off_rx;              d->rx_bufs_iova  = iova + off_rx;
    c->dma = d;
    return PW_OK;
}

static void dma_teardown(struct bar_ctx *c) {
    if (!c->dma) return;
    struct dma_state *d = c->dma;
    xdma_wr(c, PWFPGA_XDMA_H2C_CHANNEL + PWFPGA_XDMA_CH_CONTROL, 0);
    xdma_wr(c, PWFPGA_XDMA_C2H_CHANNEL + PWFPGA_XDMA_CH_CONTROL, 0);
    if (d->pool) { pw_vfio_unmap_dma(&c->vfio, d->pool_iova, d->pool_len); free(d->pool); }
    if (d->xdma_regs) munmap(d->xdma_regs, d->xdma_regs_len);
    free(d);
    c->dma = NULL;
}

/* Inject (host -> FPGA) via the H2C channel: prepend the 8-byte in-band header
 * {egress in byte 0}, DMA the frame, poll the completed-descriptor count. */
static pw_status dma_slow_path_tx(struct bar_ctx *c, const void *frame, size_t len,
                                  uint8_t egress) {
    struct dma_state *d = c->dma;
    if (!frame || len == 0) return PW_E_INVAL;
    if (len + PW_DMA_HDR_LEN > PW_DMA_FRAME_CAP) return PW_E_INVAL;

    memset(d->tx_buf, 0, PW_DMA_HDR_LEN);
    d->tx_buf[0] = egress;                                 /* in-band header */
    memcpy(d->tx_buf + PW_DMA_HDR_LEN, frame, len);
    uint32_t total = (uint32_t)(PW_DMA_HDR_LEN + len);

    desc_fill(d->h2c_desc,
              PWFPGA_XDMA_DESC_STOP | PWFPGA_XDMA_DESC_EOP | PWFPGA_XDMA_DESC_COMPLETED,
              total, d->tx_iova, 0);

    xdma_wr(c, PWFPGA_XDMA_H2C_SGDMA + PWFPGA_XDMA_SG_DESC_ADDR_LO, (uint32_t)d->h2c_desc_iova);
    xdma_wr(c, PWFPGA_XDMA_H2C_SGDMA + PWFPGA_XDMA_SG_DESC_ADDR_HI, (uint32_t)(d->h2c_desc_iova >> 32));
    xdma_wr(c, PWFPGA_XDMA_H2C_SGDMA + PWFPGA_XDMA_SG_DESC_ADJ, 0);
    xdma_wr(c, PWFPGA_XDMA_H2C_CHANNEL + PWFPGA_XDMA_CH_CONTROL, PWFPGA_XDMA_CTRL_RUN);

    /* The single-descriptor completed-count RESETS to 0 on RUN, then becomes 1
     * when the descriptor finishes. Wait for count != 0 WITHOUT reading a baseline:
     * reading a baseline has a race either way -- before RUN it latches the stale
     * 1 from the previous inject (false immediate completion, frame not DMA'd),
     * and after RUN a descriptor that completes before the baseline read latches
     * base=1 so count never changes (spin to timeout). count!=0 is unambiguous. */
    pw_status r = PW_E_IO;
    for (int i = 0; i < 1000000; i++)
        if (xdma_rd(c, PWFPGA_XDMA_H2C_CHANNEL + PWFPGA_XDMA_CH_COMPLETED_COUNT) != 0) { r = PW_OK; break; }
    xdma_wr(c, PWFPGA_XDMA_H2C_CHANNEL + PWFPGA_XDMA_CH_CONTROL, 0);   /* stop */
    return r;
}

/* Arm the C2H CIRCULAR ring: N descriptors, each -> its own RX buffer, linked
 * desc[i].next -> desc[(i+1)%N] with NO stop bit, so the engine runs forever and
 * always has posted buffers (no per-frame stop/re-arm -> no settle-wedge, no
 * unarmed gap). Armed ONCE; the completed-descriptor count then free-runs and the
 * host reaps by a consumer index. */
static void dma_arm_c2h(struct bar_ctx *c) {
    struct dma_state *d = c->dma;
    for (uint32_t i = 0; i < PW_DMA_RX_RING; i++) {
        uint64_t dst  = d->rx_bufs_iova + (uint64_t)i * PW_DMA_FRAME_CAP;
        uint64_t nxt  = d->c2h_ring_iova + (uint64_t)((i + 1u) % PW_DMA_RX_RING)
                                            * sizeof(struct pwfpga_xdma_desc);
        desc_fill(&d->c2h_ring[i], PWFPGA_XDMA_DESC_COMPLETED, PW_DMA_FRAME_CAP, 0, dst);
        d->c2h_ring[i].next_lo = (uint32_t)nxt;
        d->c2h_ring[i].next_hi = (uint32_t)(nxt >> 32);
    }
    d->rx_consumed = 0;
    /* Read the completed-count baseline BEFORE RUN. The ring runs continuously and
     * the count is cumulative (it does NOT reset per frame like the STOP-based
     * single-descriptor mode), so any completion after RUN is a new frame; reading
     * the baseline AFTER RUN could miss a frame that completes in the gap. */
    d->c2h_cmpl_base = xdma_rd(c, PWFPGA_XDMA_C2H_CHANNEL + PWFPGA_XDMA_CH_COMPLETED_COUNT);
    xdma_wr(c, PWFPGA_XDMA_C2H_SGDMA + PWFPGA_XDMA_SG_DESC_ADDR_LO, (uint32_t)d->c2h_ring_iova);
    xdma_wr(c, PWFPGA_XDMA_C2H_SGDMA + PWFPGA_XDMA_SG_DESC_ADDR_HI, (uint32_t)(d->c2h_ring_iova >> 32));
    xdma_wr(c, PWFPGA_XDMA_C2H_SGDMA + PWFPGA_XDMA_SG_DESC_ADJ, 0);
    xdma_wr(c, PWFPGA_XDMA_C2H_CHANNEL + PWFPGA_XDMA_CH_CONTROL, PWFPGA_XDMA_CTRL_RUN);
    d->c2h_armed = 1;
}

/* Derive the punted Ethernet frame's true length from its own headers. The XDMA
 * AXI-Stream C2H engine does NOT write the received length back into desc.bytes
 * (it stays at the programmed capacity, confirmed on HW), and there is no in-band
 * length field in the v1 punt header, so we recover it from L2/L3 -- which is
 * exact for every protocol the slow path punts (ARP / IPv4 / IPv6 / IS-IS-over-
 * LLC). Returns 0 if unrecognised (caller falls back to a cap). Assumes untagged
 * frames (the lab uses untagged lifs; add VLAN skip here if tagged punt lands). */
static uint32_t punt_frame_len(const uint8_t *f, uint32_t cap) {
    uint32_t et = ((uint32_t)f[12] << 8) | f[13];
    uint32_t len;
    if (et < 0x0600u)              len = 14u + et;                       /* 802.3 len (IS-IS/LLC) */
    else if (et == 0x0800u)        len = 14u + (((uint32_t)f[16] << 8) | f[17]);        /* IPv4 total_length */
    else if (et == 0x86DDu)        len = 14u + 40u + (((uint32_t)f[18] << 8) | f[19]);  /* IPv6 payload_length */
    else if (et == 0x0806u)        len = 42u;                            /* ARP: eth(14)+arp(28) */
    else                           len = 0u;                             /* unknown */
    if (len > cap) len = cap;
    return len;
}

/* Punt (FPGA -> host) via the C2H circular ring: reap the next completed frame.
 * The engine runs continuously; a consumer index vs the completed-descriptor
 * count delivers each frame exactly once (no dups) and buffers stay posted (no
 * loss). Length comes from the frame's own headers (punt_frame_len). Returns
 * bytes copied, 0 if none, <0 on error. */
static int dma_slow_path_rx(struct bar_ctx *c, void *buf, size_t buflen,
                            uint32_t *out_lif, uint64_t *out_rx_ts) {
    struct dma_state *d = c->dma;
    if (!buf) return PW_E_INVAL;
    if (!d->c2h_armed) dma_arm_c2h(c);

    uint32_t cnt  = xdma_rd(c, PWFPGA_XDMA_C2H_CHANNEL + PWFPGA_XDMA_CH_COMPLETED_COUNT);
    uint32_t done = cnt - d->c2h_cmpl_base;    /* frames completed since arm (unsigned wrap ok) */
    if (d->rx_consumed >= done) return 0;      /* no new punt frame */

    /* If we fell more than a ring behind, the engine wrapped and overwrote the
     * oldest buffers; skip to the freshest N to avoid reading stale data. */
    if (done - d->rx_consumed > PW_DMA_RX_RING)
        d->rx_consumed = done - PW_DMA_RX_RING;

    uint32_t idx = d->rx_consumed % PW_DMA_RX_RING;
    uint8_t *rb  = d->rx_bufs + (size_t)idx * PW_DMA_FRAME_CAP;
    uint32_t lif = (uint32_t)rb[0]        | ((uint32_t)rb[1] << 8)
                 | ((uint32_t)rb[2] << 16) | ((uint32_t)rb[3] << 24);
    const uint8_t *fr = rb + PW_DMA_HDR_LEN;
    /* Prefer the frame length carried in the in-band header (byte 5-6, LE) -- the
     * RTL SAF measures it, so it is exact for any frame incl. VLAN/QinQ/unknown
     * ethertype. Fall back to the L2/L3 header parse when it is 0 (an older
     * bitstream whose punt header did not carry a length). */
    uint32_t hdr_len = (uint32_t)rb[5] | ((uint32_t)rb[6] << 8);
    uint32_t payload = hdr_len ? hdr_len
                               : punt_frame_len(fr, PW_DMA_FRAME_CAP - PW_DMA_HDR_LEN);
    if (payload > PW_DMA_FRAME_CAP - PW_DMA_HDR_LEN) payload = PW_DMA_FRAME_CAP - PW_DMA_HDR_LEN;
    if (getenv("PW_DMA_DEBUG"))
        fprintf(stderr, "[dma rx] cnt=%u done=%u consumed=%u idx=%u len=%u lif=%u et=%02x%02x\n",
                cnt, done, d->rx_consumed, idx, payload, lif, fr[12], fr[13]);
    size_t copy = (payload > buflen) ? buflen : payload;
    if (copy) memcpy(buf, fr, copy);
    d->rx_consumed++;

    if (out_lif)   *out_lif   = lif;
    if (out_rx_ts) *out_rx_ts = 0;         /* rx_ts not carried in the v1 8B header */
    return (int)copy;
}

/* Slow-path RX (FPGA -> host): drain one punted frame from the punt RX
 * window. Polls PUNT_STATUS; if a frame is waiting, reads its metadata +
 * bytes, releases the slot (PUNT_POP) and returns the byte count. */
static int bar_slow_path_rx(void *vctx, void *buf, size_t buflen,
                            uint32_t *out_lif_id, uint64_t *out_rx_ts) {
    struct bar_ctx *c = vctx;
    if (c->dma) return dma_slow_path_rx(c, buf, buflen, out_lif_id, out_rx_ts);
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
    if (c->dma) return dma_slow_path_tx(c, frame, len, egress_local_port);
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
    dma_teardown(c);                       /* stop channels + unmap DMA pool (if any) */
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

    /* CSR window offset. On the DMA build (verified on silicon 2026-07-04) the
     * IP exposes TWO 64 KB BARs -- BAR0 = AXI-Lite CSR at offset 0 (UNCHANGED
     * from the legacy build), BAR1 = XDMA control registers -- NOT one 128 KB
     * split BAR0. So the CSR base does not move: csr_off = 0. (The probe below
     * still self-selects if a future build ever puts the CSR at +0x10000 in a
     * single big BAR.) */
    c->csr_off = 0;
    if (sz >= (size_t)PWFPGA_CSR_DMA_OFFSET + 0x1000) {
        volatile uint32_t *b = base;
        uint32_t at0  = b[PWFPGA_REG_DEVICE_ID / 4];
        uint32_t athi = b[(PWFPGA_CSR_DMA_OFFSET + PWFPGA_REG_DEVICE_ID) / 4];
        if ((athi >> 16) == 0xA502u && (at0 >> 16) != 0xA502u)
            c->csr_off = PWFPGA_CSR_DMA_OFFSET;
    }

    /* Bring up the XDMA slow path when the bitstream advertises HAS_DMA. It needs
     * vfio (bus-master DMA over the IOMMU; dma_setup maps BAR1 + the ring pool).
     * On a DMA build, having HAS_DMA set but the DMA path NOT up is a broken state
     * -- the CSR-window punt/inject were removed from the RTL, so there is no
     * fallback. So FAIL the attach if HAS_DMA and DMA didn't come up (sysfs path
     * has no vfio, or dma_setup failed). pw_bar_backend_open then falls back to
     * the vfio path (which brings DMA up); a genuine dma_setup failure surfaces
     * as an open error instead of a silently dead slow path. */
    uint32_t caps = *reg_at(c, PWFPGA_REG_CAPABILITIES);
    if (caps & PWFPGA_CAP_HAS_DMA) {
        if (vfio) (void)dma_setup(c);
        if (!c->dma) {
            if (vfio) pw_vfio_close(vfio);
            else      pw_pci_close_bar0(base, sz);
            free(c);
            return PW_E_BACKEND;
        }
    }

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
    if (r == PW_OK) {
        pw_status ar = bar_backend_attach(base, sz, pci_bdf, NULL, out);
        if (ar == PW_OK) return PW_OK;
        /* sysfs mmap worked but attach was rejected -- on a DMA build (HAS_DMA)
         * the sysfs path has no vfio, so bus-master DMA can't be set up and
         * attach returns PW_E_BACKEND (it already released the sysfs mapping).
         * Fall back to vfio (which brings the DMA path up) unless sysfs is forced. */
        if (force && strcmp(force, "sysfs") == 0) return ar;
        pw_status rv = pw_bar_backend_open_vfio(pci_bdf, out);
        return (rv == PW_OK) ? PW_OK : ar;
    }

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
