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

#endif
