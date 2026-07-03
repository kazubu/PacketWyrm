/* TAP device control via /dev/net/tun + ioctl. */

#include "packetwyrm/tap.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

pw_status pw_tap_open(const char *requested_name,
                      int *out_fd,
                      char out_name[PW_TAP_IFNAME_MAX]) {
    if (!out_fd || !out_name) return PW_E_INVAL;

    int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return PW_E_BACKEND;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    if (requested_name && *requested_name) {
        strncpy(ifr.ifr_name, requested_name, IFNAMSIZ - 1);
    }

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        close(fd);
        return PW_E_BACKEND;
    }

    /* Persist the device across this fd close-by-default; tests
     * want the netdev to disappear when the fd closes. */
    if (ioctl(fd, TUNSETPERSIST, 0) < 0) {
        /* Not fatal: kernels without persist support still work. */
    }

    /* Mark the tun carrier UP so the netdev reports operstate UP instead of the
     * tun default IF_OPER_UNKNOWN. A routing daemon attached to this TAP (e.g.
     * cRPD) requires the interface's physical link to be UP before it runs an IGP
     * on it: with OPER_UNKNOWN, OSPF/IS-IS silently skip the interface (BGP/ping
     * still work via the kernel route, but no OSPF/IS-IS adjacency forms). Using
     * TUNSETCARRIER switches the driver into explicit operstate tracking -> UP.
     * Best-effort (needs Linux >= 5.0); harmless where unsupported. */
#ifndef TUNSETCARRIER
#define TUNSETCARRIER _IOW('T', 226, int)
#endif
    {
        int carrier_on = 1;
        (void)ioctl(fd, TUNSETCARRIER, &carrier_on);
    }

    snprintf(out_name, PW_TAP_IFNAME_MAX, "%s", ifr.ifr_name);
    *out_fd = fd;
    return PW_OK;
}

void pw_tap_close(int fd) {
    if (fd >= 0) close(fd);
}

static int open_inet_ctl_socket(void) {
    return socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
}

pw_status pw_tap_set_up(const char *name, bool up) {
    if (!name) return PW_E_INVAL;
    int s = open_inet_ctl_socket();
    if (s < 0) return PW_E_BACKEND;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) { close(s); return PW_E_BACKEND; }

    if (up) ifr.ifr_flags |= IFF_UP;
    else    ifr.ifr_flags &= ~IFF_UP;

    pw_status r = (ioctl(s, SIOCSIFFLAGS, &ifr) < 0) ? PW_E_BACKEND : PW_OK;
    close(s);
    return r;
}

pw_status pw_tap_set_mac(const char *name, const uint8_t mac[6]) {
    if (!name || !mac) return PW_E_INVAL;
    int s = open_inet_ctl_socket();
    if (s < 0) return PW_E_BACKEND;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    ifr.ifr_hwaddr.sa_family = 1;  /* ARPHRD_ETHER */
    memcpy(ifr.ifr_hwaddr.sa_data, mac, 6);
    pw_status r = (ioctl(s, SIOCSIFHWADDR, &ifr) < 0) ? PW_E_BACKEND : PW_OK;
    close(s);
    return r;
}

pw_status pw_tap_set_mtu(const char *name, uint16_t mtu) {
    if (!name) return PW_E_INVAL;
    int s = open_inet_ctl_socket();
    if (s < 0) return PW_E_BACKEND;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    ifr.ifr_mtu = mtu;
    pw_status r = (ioctl(s, SIOCSIFMTU, &ifr) < 0) ? PW_E_BACKEND : PW_OK;
    close(s);
    return r;
}

pw_status pw_tap_query(const char *name, struct pw_tap_state *out) {
    if (!name || !out) return PW_E_INVAL;
    memset(out, 0, sizeof(*out));

    struct ifaddrs *ifa_head = NULL;
    if (getifaddrs(&ifa_head) < 0) return PW_E_BACKEND;

    bool found = false;
    for (struct ifaddrs *ifa = ifa_head; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || strcmp(ifa->ifa_name, name) != 0) continue;
        found = true;
        /* Flags come on every entry for the interface; latch them. */
        out->admin_up = (ifa->ifa_flags & IFF_UP)      != 0;
        out->oper_up  = (ifa->ifa_flags & IFF_RUNNING) != 0;

        if (!ifa->ifa_addr) continue;
        int fam = ifa->ifa_addr->sa_family;
        if (fam == AF_PACKET && ifa->ifa_data) {
            /* Kernel netdev stats (host's point of view). */
            const struct rtnl_link_stats *st = ifa->ifa_data;
            out->rx_packets = st->rx_packets;
            out->rx_bytes   = st->rx_bytes;
            out->rx_dropped = st->rx_dropped;
            out->tx_packets = st->tx_packets;
            out->tx_bytes   = st->tx_bytes;
            out->tx_dropped = st->tx_dropped;
        } else if ((fam == AF_INET || fam == AF_INET6)
                   && out->n_addrs < PW_TAP_ADDR_MAX) {
            char buf[PW_TAP_ADDR_STR_MAX] = {0};
            const void *src = (fam == AF_INET)
                ? (const void *)&((struct sockaddr_in  *)ifa->ifa_addr)->sin_addr
                : (const void *)&((struct sockaddr_in6 *)ifa->ifa_addr)->sin6_addr;
            if (inet_ntop(fam, src, buf, sizeof(buf))) {
                snprintf(out->addrs[out->n_addrs], PW_TAP_ADDR_STR_MAX, "%s", buf);
                out->n_addrs++;
            }
        }
    }

    freeifaddrs(ifa_head);
    return found ? PW_OK : PW_E_BACKEND;
}
