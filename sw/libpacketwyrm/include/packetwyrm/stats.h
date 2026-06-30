/* PacketWyrm: aggregated global statistics. */
#ifndef PACKETWYRM_STATS_H
#define PACKETWYRM_STATS_H

#include "packetwyrm/backend.h"
#include "packetwyrm/flow_compiler.h"

struct pw_global_flow_stats {
    uint32_t global_flow_id;
    uint64_t tx_frames;
    uint64_t tx_bytes;
    uint64_t rx_frames;
    uint64_t rx_bytes;
    uint64_t lost_est;
    uint64_t duplicate;
    uint64_t out_of_order;
    uint64_t late;
    uint64_t sequence_gap_count;

    /* Latency / jitter. Now valid for BOTH same-card (counter-direct, exact)
     * and cross-card flows -- cross-card is corrected per sample in hardware via
     * the lat_correction CSR + J5 GPIO sync, so the values below are the true
     * one-way latency in either case and latency_valid is true for both.
     * cross_card distinguishes the source (true = the HW-corrected path; the
     * absolute number then also carries a fixed J5-sync-path calibration bias). */
    bool     latency_valid;
    bool     cross_card;
    uint32_t min_latency_ns;
    uint32_t max_latency_ns;
    uint64_t sum_latency_ns;
    uint64_t sample_count;
    uint32_t jitter_min_ns;
    uint32_t jitter_max_ns;
    uint64_t jitter_sum_ns;
};

struct pw_global_port_stats {
    uint16_t global_port_id;
    uint16_t card_id;
    uint8_t  local_port_id;
    struct pw_port_stats raw;
};

/* Aggregate one snapshot from each card into the global view. */
pw_status pw_stats_aggregate(const struct pw_program *prog,
                             const struct pw_flow_stats *per_card_flow_stats /* indexed by program order */,
                             size_t n_flow_stats,
                             struct pw_global_flow_stats *out,
                             size_t n_out);

#endif
