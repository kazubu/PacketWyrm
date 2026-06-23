/* Host packet plane: punt RX -> TAP / TAP -> FPGA TX bridge. */

#include "packetwyrm/host_plane.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define PW_HOST_FRAME_MAX 2048

pw_status pw_host_plane_init(struct pw_host_plane *hp,
                             struct pw_card_backend *backend) {
    if (!hp || !backend) return PW_E_INVAL;
    memset(hp, 0, sizeof(*hp));
    hp->backend = backend;
    return PW_OK;
}

static int find_binding(const struct pw_host_plane *hp, uint32_t lif) {
    for (size_t i = 0; i < hp->n_bindings; i++)
        if (hp->bindings[i].logical_if_id == lif) return (int)i;
    return -1;
}

pw_status pw_host_plane_bind(struct pw_host_plane *hp,
                             uint32_t logical_if_id,
                             int      fd,
                             uint8_t  egress_local_port) {
    if (!hp || fd < 0) return PW_E_INVAL;
    if (find_binding(hp, logical_if_id) >= 0) return PW_E_DUP_LOGICAL_IF;
    if (hp->n_bindings >= PW_HOST_PLANE_MAX_BINDINGS) return PW_E_NO_RESOURCES;

    /* Best-effort set fd non-blocking so the TAP-read drain loop
     * doesn't stall if the kernel has nothing for us. */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    hp->bindings[hp->n_bindings] = (struct pw_host_binding){
        .logical_if_id     = logical_if_id,
        .fd                = fd,
        .egress_local_port = egress_local_port,
    };
    hp->n_bindings++;
    return PW_OK;
}

int pw_host_plane_step(struct pw_host_plane *hp, int max_per_dir) {
    if (!hp || !hp->backend || !hp->backend->ops) return PW_E_INVAL;
    int moved = 0;
    uint8_t buf[PW_HOST_FRAME_MAX];

    /* punt RX -> TAP */
    if (hp->backend->ops->slow_path_rx) {
        for (int i = 0; i < max_per_dir; i++) {
            uint32_t lif = 0;
            int n = hp->backend->ops->slow_path_rx(hp->backend->ctx,
                                                   buf, sizeof(buf), &lif, NULL);
            if (n <= 0) break;
            int b = find_binding(hp, lif);
            if (b < 0) { hp->punt_unknown_lif++; continue; }
            ssize_t w = write(hp->bindings[b].fd, buf, (size_t)n);
            if (w == n)      { hp->punt_to_tap_ok[b]++; moved++; }
            else             { hp->punt_to_tap_dropped[b]++; }
        }
    }

    /* TAP -> FPGA TX */
    if (hp->backend->ops->slow_path_tx) {
        for (size_t b = 0; b < hp->n_bindings; b++) {
            for (int i = 0; i < max_per_dir; i++) {
                ssize_t n = read(hp->bindings[b].fd, buf, sizeof(buf));
                if (n <= 0) {
                    /* EAGAIN: no data right now; EBADF / other: also stop */
                    break;
                }
                pw_status r = hp->backend->ops->slow_path_tx(
                    hp->backend->ctx, buf, (size_t)n,
                    hp->bindings[b].logical_if_id,
                    hp->bindings[b].egress_local_port);
                if (r == PW_OK) { hp->tap_to_fpga_ok[b]++; moved++; }
                else            { hp->tap_to_fpga_dropped[b]++; }
            }
        }
    }

    return moved;
}
