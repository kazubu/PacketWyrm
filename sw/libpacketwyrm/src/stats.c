/* Global stats aggregation. */

#include "packetwyrm/stats.h"

#include <stdint.h>
#include <string.h>

pw_status pw_stats_aggregate(const struct pw_program *prog,
                             const struct pw_flow_stats *per_card_flow_stats,
                             size_t n_flow_stats,
                             struct pw_global_flow_stats *out,
                             size_t n_out) {
    if (!prog || !out || !per_card_flow_stats) return PW_E_INVAL;
    if (prog->n_flow_meta && !prog->flow_meta) return PW_E_INVAL;
    /* Reject sizes that would wrap the derived byte/element counts below
     * (per_card_flow_stats is 2 per flow; out/memset is sizeof(*out) per flow),
     * so a corrupt n_flow_meta can't slip past the capacity checks into an OOB
     * read/write. Normal daemon inputs are tiny; this guards the API boundary. */
    if (prog->n_flow_meta > SIZE_MAX / 2) return PW_E_INVAL;
    if (prog->n_flow_meta > SIZE_MAX / sizeof(*out)) return PW_E_INVAL;
    if (n_out < prog->n_flow_meta) return PW_E_INVAL;
    if (n_flow_stats < prog->n_flow_meta * 2) return PW_E_INVAL;

    /* The contract: per_card_flow_stats is laid out as a pair per flow
     * (tx side, rx side) in the same order as prog->flow_meta. The
     * caller (daemon) fills both slots from the right card's snapshot;
     * for same-card flows both slots can point to the same data. */
    memset(out, 0, sizeof(*out) * prog->n_flow_meta);
    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        const struct pw_flow_stats *tx_s = &per_card_flow_stats[i * 2 + 0];
        const struct pw_flow_stats *rx_s = &per_card_flow_stats[i * 2 + 1];

        out[i].global_flow_id = m->global_flow_id;
        out[i].tx_frames = tx_s->tx_frames;
        out[i].tx_bytes  = tx_s->tx_bytes;
        out[i].rx_frames = rx_s->rx_frames;
        out[i].rx_bytes  = rx_s->rx_bytes;
        out[i].lost_est  = rx_s->lost_packets_estimated;
        out[i].duplicate = rx_s->duplicate_count;
        out[i].out_of_order = rx_s->out_of_order_count;
        out[i].late      = rx_s->late_packet_count;
        out[i].sequence_gap_count = rx_s->sequence_gap_count;

        /* Latency is now available for both same- and cross-card flows: the RX
         * checker stores the HW-corrected value for cross-card (lat_correction +
         * J5 sync), so rx_s already holds the true one-way latency either way.
         * latency_valid (= m->latency_valid) is repurposed as the same-card flag,
         * surfaced here as cross_card; the numbers are copied unconditionally. */
        out[i].latency_valid = true;
        out[i].cross_card    = !m->latency_valid;
        out[i].min_latency_ns = rx_s->min_latency;
        out[i].max_latency_ns = rx_s->max_latency;
        out[i].sum_latency_ns = rx_s->sum_latency;
        out[i].sample_count   = rx_s->sample_count;
        out[i].jitter_min_ns  = rx_s->jitter_min;
        out[i].jitter_max_ns  = rx_s->jitter_max;
        out[i].jitter_sum_ns  = rx_s->jitter_sum;
    }
    return PW_OK;
}
