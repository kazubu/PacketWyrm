/* PacketWyrm: control-socket IPC primitives. */

#include "packetwyrm/ipc.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        left -= (size_t)n;
        p    += n;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = read(fd, p, left);
        if (n == 0) return -1;             /* EOF */
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        left -= (size_t)n;
        p    += n;
    }
    return 0;
}

pw_status pw_ipc_read_frame(int fd, void *buf, size_t buflen, size_t *out_len) {
    if (!buf || !out_len) return PW_E_INVAL;
    uint8_t hdr[4];
    if (read_all(fd, hdr, 4) < 0) return PW_E_IO;
    uint32_t n = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                 ((uint32_t)hdr[2] << 8)  |  (uint32_t)hdr[3];
    if (n == 0 || n > buflen || n > PW_IPC_FRAME_MAX) return PW_E_OUT_OF_RANGE;
    if (read_all(fd, buf, n) < 0) return PW_E_IO;
    *out_len = n;
    return PW_OK;
}

pw_status pw_ipc_write_frame(int fd, const void *buf, size_t len) {
    if (len == 0 || len > PW_IPC_FRAME_MAX) return PW_E_OUT_OF_RANGE;
    uint8_t hdr[4] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16),
        (uint8_t)(len >> 8),  (uint8_t)(len),
    };
    if (write_all(fd, hdr, 4) < 0) return PW_E_IO;
    if (write_all(fd, buf, len) < 0) return PW_E_IO;
    return PW_OK;
}

pw_status pw_ipc_connect(const char *path, int *out_fd) {
    if (!path || !out_fd) return PW_E_INVAL;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return PW_E_IO;
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return PW_E_IO;
    }
    *out_fd = fd;
    return PW_OK;
}

/* Create the parent directory of `path` (mkdir -p style), best-effort. On a
 * fresh boot /var/run/packetwyrm (the default socket dir) may not exist yet, so
 * bind() would fail with ENOENT and the daemon would come up without a control
 * socket. Creating the tree here lets it start with no manual setup. The socket
 * FILE itself is chmod'd to `mode` below (that 0666 is the access ACL); the
 * directories are 0755 (traversable, not the ACL). */
static void ensure_parent_dir(const char *path) {
    char buf[sizeof(((struct sockaddr_un *)0)->sun_path)];
    size_t n = strnlen(path, sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return;      /* empty or too long to bind */
    memcpy(buf, path, n + 1);
    char *slash = strrchr(buf, '/');
    if (!slash || slash == buf) return;          /* no dir part, or dir is "/" */
    *slash = '\0';                               /* strip the socket filename */
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; (void)mkdir(buf, 0755); *p = '/'; }
    }
    (void)mkdir(buf, 0755);
}

pw_status pw_ipc_listen(const char *path, mode_t mode, int *out_fd) {
    if (!path || !out_fd) return PW_E_INVAL;
    /* Make sure the socket's directory exists before we bind into it. */
    ensure_parent_dir(path);
    /* Best-effort: remove stale leftover */
    unlink(path);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return PW_E_IO;
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return PW_E_IO;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return PW_E_IO;
    }
    (void)chmod(path, mode);
    *out_fd = fd;
    return PW_OK;
}
