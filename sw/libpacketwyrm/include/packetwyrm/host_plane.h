/* PacketWyrm: host packet plane.
 *
 * Bridges the FPGA slow-path RX / TX (via the pw_card_backend
 * abstraction) to per-logical-interface TAP file descriptors.
 *
 *   FPGA  --(punt frame, lif_id=K)-->  card_backend.slow_path_rx
 *         ----------------- bridge ----------------->  TAP fd for K
 *
 *   TAP fd for K  --read-->  card_backend.slow_path_tx(lif_id=K)
 *         ----------------- bridge ----------------->  FPGA
 *
 * The host plane is a pure data-mover. Logical-interface binding
 * (id -> fd, MAC, MTU, VLAN, ...) is set up by the daemon using
 * pw_tap_* before constructing this object. */
#ifndef PACKETWYRM_HOST_PLANE_H
#define PACKETWYRM_HOST_PLANE_H

#include "packetwyrm/backend.h"
#include "packetwyrm/types.h"

#include <stdatomic.h>

#define PW_HOST_PLANE_MAX_BINDINGS 32

struct pw_host_binding {
    uint32_t logical_if_id;
    int      fd;                       /* TAP fd, socketpair, ... */
    uint8_t  egress_local_port;        /* used for TAP->FPGA injects */
};

struct pw_host_plane {
    struct pw_card_backend *backend;
    struct pw_host_binding  bindings[PW_HOST_PLANE_MAX_BINDINGS];
    size_t                  n_bindings;

    /* Per-binding counters. Atomic because the card worker thread increments
     * them (`x++`, a well-defined atomic RMW on an _Atomic lvalue) while the
     * main thread reads them for stats (an atomic load) -- a plain uint64_t
     * would be a C data race (UB / torn 64-bit reads on some ABIs). Ordering
     * isn't relied on: they are independent monotonic counters shown in a
     * best-effort snapshot, not a synchronisation signal. */
    _Atomic uint64_t punt_to_tap_ok      [PW_HOST_PLANE_MAX_BINDINGS];
    _Atomic uint64_t punt_to_tap_dropped [PW_HOST_PLANE_MAX_BINDINGS];
    _Atomic uint64_t tap_to_fpga_ok      [PW_HOST_PLANE_MAX_BINDINGS];
    _Atomic uint64_t tap_to_fpga_dropped [PW_HOST_PLANE_MAX_BINDINGS];

    /* tracker for unrecognised punt logical_if_ids */
    _Atomic uint64_t punt_unknown_lif;
};

pw_status pw_host_plane_init(struct pw_host_plane *hp,
                             struct pw_card_backend *backend);

pw_status pw_host_plane_bind(struct pw_host_plane *hp,
                             uint32_t logical_if_id,
                             int      fd,
                             uint8_t  egress_local_port);

/* One iteration of the bidirectional bridge:
 *   - drain up to `max_per_dir` frames in each direction.
 * Non-blocking: returns immediately when neither side has work.
 * Returns the total number of frames moved (both directions). */
int pw_host_plane_step(struct pw_host_plane *hp, int max_per_dir);

#endif
