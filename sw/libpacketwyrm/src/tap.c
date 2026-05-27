/* TAP device control via /dev/net/tun + ioctl. */

#include "packetwyrm/tap.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <net/if.h>
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
