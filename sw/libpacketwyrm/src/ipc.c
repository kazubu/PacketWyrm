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
        /* MSG_NOSIGNAL: the fd is always a socket here, and a peer that closed
         * mid-write must surface as EPIPE/-1 (-> PW_E_IO), never SIGPIPE-kill the
         * caller -- libpacketwyrm can't assume every user ignores SIGPIPE. */
        ssize_t n = send(fd, p, left, MSG_NOSIGNAL);
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

/* Fill sa->sun_path from `path`, REJECTING a path that doesn't fit sun_path
 * (Linux ~108 B) instead of silently truncating. pw_system.control_socket is
 * 128 B, so a configured path can fit the struct but not the socket API; a
 * silent truncation would bind/connect to a DIFFERENT socket than configured. */
static pw_status fill_sockaddr_un(const char *path, struct sockaddr_un *sa) {
    size_t n = strnlen(path, sizeof(sa->sun_path));
    if (n >= sizeof(sa->sun_path)) return PW_E_OUT_OF_RANGE;
    sa->sun_family = AF_UNIX;
    memcpy(sa->sun_path, path, n + 1);
    return PW_OK;
}

pw_status pw_ipc_connect(const char *path, int *out_fd) {
    if (!path || !out_fd) return PW_E_INVAL;
    struct sockaddr_un sa = {0};
    pw_status r = fill_sockaddr_un(path, &sa);
    if (r != PW_OK) return r;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return PW_E_IO;   /* errno from socket() left for the caller */
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        /* Preserve connect()'s errno across close() (which can clobber it) so
         * the caller can strerror(errno) + pw_ipc_connect_hint(errno). */
        int e = errno;
        close(fd);
        errno = e;
        return PW_E_IO;
    }
    *out_fd = fd;
    return PW_OK;
}

const char *pw_ipc_connect_hint(int err) {
    switch (err) {
    case ECONNREFUSED:
        return "daemon not running or wrong --socket path";
    case ENOENT:
        return "socket path does not exist -- is packetwyrmd running?";
    case EACCES:
    case EPERM:
        return "permission denied -- run as root or join the 'packetwyrm' "
               "group (socket is 0660 root:packetwyrm)";
    case ENOTSOCK:
        return "path exists but is not a socket -- check the --socket path";
    case ETIMEDOUT:
        return "connect timed out -- daemon may be hung or unreachable";
    default:
        return "unable to connect to the control socket";
    }
}

/* Create the parent directory of `path` (mkdir -p style), best-effort. On a
 * fresh boot /run/packetwyrm (the default socket dir) may not exist yet, so
 * bind() would fail with ENOENT and the daemon would come up without a control
 * socket. Creating the tree here lets it start with no manual setup. The socket
 * FILE itself is chmod'd to the caller's `mode` below (in production the daemon
 * passes 0660 and group-owns it root:packetwyrm; dev/CI -F uses 0666) -- that is
 * its access ACL; the directories are 0755 (traversable, not the ACL). */
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
    /* Validate the path length FIRST -- before touching the filesystem -- so an
     * unbindable (too-long) path can't cause an unlink of a same-named file. */
    struct sockaddr_un sa = {0};
    pw_status r = fill_sockaddr_un(path, &sa);
    if (r != PW_OK) return r;
    /* Make sure the socket's directory exists before we bind into it. */
    ensure_parent_dir(path);
    /* Remove ONLY a stale socket. A leftover from a prior run is a socket;
     * anything else at this path (a regular file, a dir) is a misconfiguration
     * we must NOT silently destroy -- the daemon often runs as root. */
    struct stat st;
    if (lstat(path, &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) return PW_E_IO;   /* refuse to clobber a non-socket */
        unlink(path);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return PW_E_IO;
    /* Create the socket file owner-only (umask 0077 -> 0700) and only widen it
     * to the requested mode AFTER listen(): the file mode IS the access ACL
     * when no secret is configured, and a chmod applied after bind()+listen()
     * left a window where a raced connect could slip in under a permissive
     * umask default. Restrict-then-widen closes it. */
    mode_t old_umask = umask(0077);
    int bind_rc = bind(fd, (struct sockaddr *)&sa, sizeof(sa));
    umask(old_umask);
    if (bind_rc < 0) {
        close(fd);
        return PW_E_IO;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return PW_E_IO;
    }
    /* The mode IS the access ACL when no secret is set, so a failure to apply it
     * must not leave the socket at the umask default -- treat it like the other
     * listen failures (fatal to the caller). */
    if (chmod(path, mode) != 0) {
        close(fd);
        unlink(path);
        return PW_E_IO;
    }
    *out_fd = fd;
    return PW_OK;
}
