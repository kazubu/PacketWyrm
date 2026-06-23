/* PacketWyrm: card-backend abstraction.
 *
 * The same higher-level code paths run against:
 *   - the fake backend (in-memory model, used in unit tests),
 *   - the real BAR-mmap backend on Linux (Phase 4+).
 *
 * The interface is intentionally narrow: register reads / writes, table
 * commits, and a stats snapshot pull. Anything richer goes through the
 * documented CSR map. */
#ifndef PACKETWYRM_BACKEND_H
#define PACKETWYRM_BACKEND_H

#include "packetwyrm/csr.h"
#include "packetwyrm/types.h"

struct pw_card_backend;

struct pw_card_info {
    uint32_t device_id;
    uint32_t version;
    uint32_t build_id;
    uint32_t git_hash;
    uint32_t capabilities;
    uint16_t num_local_ports;
    uint16_t num_local_flows;
    uint16_t num_logical_interfaces;
    uint16_t num_classifier_entries;
};

struct pw_port_stats {
    uint64_t rx_frames;
    uint64_t rx_bytes;
    uint64_t rx_fcs_error;
    uint64_t rx_bad_frame;
    uint64_t rx_oversize;
    uint64_t rx_undersize;
    uint64_t tx_frames;
    uint64_t tx_bytes;
    uint32_t link_up_count;
    uint32_t link_down_count;
    uint32_t block_lock_loss;
};

struct pw_flow_stats {
    uint64_t tx_frames;
    uint64_t tx_bytes;
    uint64_t rx_frames;
    uint64_t rx_bytes;
    uint64_t expected_sequence;
    uint64_t sequence_gap_count;
    uint64_t lost_packets_estimated;
    uint64_t duplicate_count;
    uint64_t out_of_order_count;
    uint64_t late_packet_count;
    uint32_t min_latency;
    uint32_t max_latency;
    uint64_t sum_latency;
    uint64_t sample_count;
    uint32_t jitter_min;
    uint32_t jitter_max;
    uint64_t jitter_sum;
};

struct pw_card_backend_ops {
    pw_status (*read32)(void *ctx, uint32_t offset, uint32_t *out);
    pw_status (*write32)(void *ctx, uint32_t offset, uint32_t v);

    pw_status (*card_info)(void *ctx, struct pw_card_info *out);

    /* (The legacy classifier_write/commit ops are retired -- the field+UDF /
     * hash / flow-id-map classifiers are programmed register-wise via write32.) */

    pw_status (*flow_write)(void *ctx, uint32_t row,
                            const struct pwfpga_flow_config *f);
    pw_status (*flow_commit)(void *ctx);

    pw_status (*stats_snapshot)(void *ctx);
    pw_status (*port_stats_read)(void *ctx, uint8_t local_port,
                                 struct pw_port_stats *out);
    pw_status (*flow_stats_read)(void *ctx, uint32_t local_flow_id,
                                 struct pw_flow_stats *out);

    /* Read up to `n_buckets` per-flow latency histogram buckets.
     * On success, *n_buckets_out is set to the actual number of
     * buckets the FPGA reports. May be NULL on backends without a
     * histogram window. */
    pw_status (*flow_hist_read)(void *ctx, uint32_t local_flow_id,
                                uint64_t *buckets, size_t n_buckets,
                                size_t *n_buckets_out);

    /* Slow-path RX (FPGA -> host). Pops one frame if available.
     * Returns: > 0  = bytes copied into buf (and *out_lif_id set; *out_rx_ts,
     *               if non-NULL, gets the frame's RX wire timestamp -- the
     *               free-running counter latched at the frame's SOF, for a PTP
     *               servo's RX events);
     *         == 0  = no frame waiting;
     *         <  0  = pw_status error code. May be NULL on backends
     *               that do not implement the slow path yet. */
    int       (*slow_path_rx)(void *ctx, void *buf, size_t buflen,
                              uint32_t *out_lif_id, uint64_t *out_rx_ts);

    /* Slow-path TX (host -> FPGA). Enqueues one frame for the FPGA's
     * TX arbiter to send out the given egress local port. May be
     * NULL on backends that do not implement the slow path yet. */
    pw_status (*slow_path_tx)(void *ctx,
                              const void *frame, size_t len,
                              uint32_t logical_if_id,
                              uint8_t  egress_local_port);

    void      (*close)(void *ctx);
};

struct pw_card_backend {
    const struct pw_card_backend_ops *ops;
    void                             *ctx;
    char                              pci_bdf[PW_PCI_BDF_MAX];
    uint16_t                          card_id;
};

/* Fake backend: a software model that responds plausibly to register
 * accesses and tracks programmed flows. Used by unit tests and by the
 * daemon when no real hardware is attached (e.g. on a developer
 * laptop). */
pw_status pw_fake_backend_open(const char *pci_bdf, struct pw_card_backend *out);

/* Fake-backend-only helpers exercised by the host_plane tests:
 *
 *   pw_fake_backend_inject_punt  - simulate an FPGA punt event; the
 *                                  next slow_path_rx() returns this
 *                                  frame.
 *   pw_fake_backend_drain_tx     - pop one frame the host_plane
 *                                  injected via slow_path_tx().
 */
pw_status pw_fake_backend_inject_punt(struct pw_card_backend *b,
                                      uint32_t logical_if_id,
                                      const void *frame, size_t len);

int       pw_fake_backend_drain_tx(struct pw_card_backend *b,
                                   void *buf, size_t buflen,
                                   uint32_t *out_lif_id,
                                   uint8_t  *out_egress_local_port);

/* Real backend: opens /sys/bus/pci/devices/<bdf>/resource0, mmaps it,
 * and drives the CSRs. Phase 4+. */
pw_status pw_bar_backend_open(const char *pci_bdf, struct pw_card_backend *out);

/* Variant taking an arbitrary file path - used by unit tests against
 * a tmpfs file, and by debugging tools that want to point the
 * backend at a captured / synthesised BAR image. */
pw_status pw_bar_backend_open_path(const char *path, struct pw_card_backend *out);

/* VFIO variant: maps the CSR BAR through vfio-pci (IOMMU-mediated),
 * the access path that works under Secure Boot / kernel lockdown where
 * sysfs resource mmap is denied. The device must be bound to vfio-pci
 * (see pw_vfio_bind). pw_bar_backend_open() falls back to this
 * automatically when the sysfs mmap is refused. */
pw_status pw_bar_backend_open_vfio(const char *pci_bdf, struct pw_card_backend *out);

static inline void pw_card_backend_close(struct pw_card_backend *b) {
    if (b && b->ops && b->ops->close) b->ops->close(b->ctx);
    if (b) { b->ops = NULL; b->ctx = NULL; }
}

#endif
