/* PacketWyrm: Linux TAP device control.
 *
 * Thin wrappers around the /dev/net/tun + ioctl interface that
 * packetwyrmd uses to create one virtual NIC per logical
 * interface. Requires CAP_NET_ADMIN. */
#ifndef PACKETWYRM_TAP_H
#define PACKETWYRM_TAP_H

#include <stdbool.h>
#include <stdint.h>

#include "packetwyrm/types.h"

#define PW_TAP_IFNAME_MAX 16   /* matches IFNAMSIZ */

/* Open a TAP device.
 *
 *   requested_name: desired kernel netdev name (e.g. "tap-pw-p0-v100").
 *                   May be NULL for kernel auto-allocation.
 *   out_fd:         on success, the TAP file descriptor.
 *   out_name:       on success, the actual kernel name (may differ
 *                   from `requested_name` if the kernel adjusted it).
 *
 * The TAP is created with IFF_TAP | IFF_NO_PI (raw L2 frames, no
 * 4-byte protocol prefix). Caller is responsible for calling
 * pw_tap_close() when done. */
pw_status pw_tap_open(const char *requested_name,
                      int *out_fd,
                      char out_name[PW_TAP_IFNAME_MAX]);

void      pw_tap_close(int fd);

pw_status pw_tap_set_up(const char *name, bool up);
pw_status pw_tap_set_mac(const char *name, const uint8_t mac[6]);
pw_status pw_tap_set_mtu(const char *name, uint16_t mtu);

#define PW_TAP_ADDR_MAX     8    /* IP addresses reported per TAP */
#define PW_TAP_ADDR_STR_MAX 46   /* fits INET6_ADDRSTRLEN */

/* Live kernel-side state of a TAP netdev, for status/statistics display.
 * admin_up = IFF_UP (configured up); oper_up = IFF_RUNNING (carrier/oper).
 * The rx/tx/dropped counters are the KERNEL netdev stats (from the host's
 * point of view: rx = frames the kernel received from the TAP = frames the
 * daemon punted into it). addrs are the IP addresses the host assigned. */
struct pw_tap_state {
    bool     admin_up;
    bool     oper_up;
    uint64_t rx_packets, rx_bytes, rx_dropped;
    uint64_t tx_packets, tx_bytes, tx_dropped;
    int      n_addrs;
    char     addrs[PW_TAP_ADDR_MAX][PW_TAP_ADDR_STR_MAX];
};

/* Query a TAP netdev's live kernel state by name. Fills *out (zeroed first).
 * Returns PW_E_BACKEND if the interface cannot be queried. */
pw_status pw_tap_query(const char *name, struct pw_tap_state *out);

#endif
