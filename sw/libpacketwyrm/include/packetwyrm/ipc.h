/* PacketWyrm: control-socket IPC between packetwyrmd and pktwyrm.
 *
 * Wire format: 4-byte big-endian length prefix followed by a JSON
 * UTF-8 body. One request -> one response, then the connection
 * closes. Phase 0/1 RPCs:
 *
 *   { "rpc": "version" }
 *   { "rpc": "cards" }
 *   { "rpc": "ports" }
 *   { "rpc": "flows" }
 *   { "rpc": "stats" }                # aggregated flow + port stats
 *   { "rpc": "stats", "card": <id> }  # one card
 *
 * Responses are JSON objects. Errors look like
 *   { "error": "...", "code": "PW_E_..." }
 *
 * Authentication is the `system.secret` model (constant-time secret
 * check; with no secret configured, the socket file permissions are
 * the ACL). In production the daemon creates the socket 0660
 * root:packetwyrm (root, or the packetwyrm group -- e.g. the
 * packetwyrm-proxyd gateway); dev/CI (-F) uses 0666. See main.c. */
#ifndef PACKETWYRM_IPC_H
#define PACKETWYRM_IPC_H

#include <sys/types.h>

#include "packetwyrm/types.h"

#define PW_IPC_DEFAULT_PATH "/var/run/packetwyrm/packetwyrmd.sock"
#define PW_IPC_FRAME_MAX    65536

/* Read a length-prefixed frame from `fd` into `buf`. On success,
 * `*out_len` is set and PW_OK is returned. Closes nothing. */
pw_status pw_ipc_read_frame(int fd, void *buf, size_t buflen, size_t *out_len);

/* Write a length-prefixed frame to `fd`. PW_OK on full success. */
pw_status pw_ipc_write_frame(int fd, const void *buf, size_t len);

/* Connect to a daemon control socket. Caller is responsible for
 * close() on the returned fd. */
pw_status pw_ipc_connect(const char *path, int *out_fd);

/* Create + bind + listen a Unix domain socket suitable for the
 * daemon's control surface. Sets SO_REUSEADDR, removes a stale
 * leftover socket file, applies `mode` permissions. */
pw_status pw_ipc_listen(const char *path, mode_t mode, int *out_fd);

#endif
