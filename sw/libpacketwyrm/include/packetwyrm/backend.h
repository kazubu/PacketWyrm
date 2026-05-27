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

    pw_status (*classifier_write)(void *ctx, uint32_t row,
                                  const struct pwfpga_classifier_entry *e);
    pw_status (*classifier_commit)(void *ctx);

    pw_status (*flow_write)(void *ctx, uint32_t row,
                            const struct pwfpga_flow_config *f);
    pw_status (*flow_commit)(void *ctx);

    pw_status (*stats_snapshot)(void *ctx);
    pw_status (*port_stats_read)(void *ctx, uint8_t local_port,
                                 struct pw_port_stats *out);
    pw_status (*flow_stats_read)(void *ctx, uint32_t local_flow_id,
                                 struct pw_flow_stats *out);

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

/* Real backend: opens /sys/bus/pci/devices/<bdf>/resource0, mmaps it,
 * and drives the CSRs. Phase 4. */
pw_status pw_bar_backend_open(const char *pci_bdf, struct pw_card_backend *out);

static inline void pw_card_backend_close(struct pw_card_backend *b) {
    if (b && b->ops && b->ops->close) b->ops->close(b->ctx);
    if (b) { b->ops = NULL; b->ctx = NULL; }
}

#endif
