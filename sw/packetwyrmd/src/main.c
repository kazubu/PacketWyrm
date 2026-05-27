/* packetwyrmd: load config, open backends, create TAPs, run the
 * host packet plane until SIGINT/SIGTERM. The full control socket
 * + per-card workers ship later; this is the minimum that
 * presents PacketWyrm to the rest of the host (Linux sees TAPs,
 * fake or real backend sees flow programming). */

#include <errno.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <json-c/json.h>

#include "packetwyrm/packetwyrm.h"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

#define MAX_CARDS PW_MAX_CARDS

struct card_runtime {
    struct pw_card_backend backend;
    const char            *which;
    bool                   open;
};

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [-c CONFIG] [-n] [-v] [-s INTERVAL_MS] [-p PROMETHEUS_PORT]\n"
        "  -c CONFIG         path to packetwyrm.yaml\n"
        "  -n                dry run: parse + validate + compile, exit\n"
        "  -v                verbose\n"
        "  -s INTERVAL_MS    stats print interval (default 5000, 0 = off)\n"
        "  -p PORT           bind a Prometheus /metrics exporter on this TCP\n"
        "                    port; 0 (default) leaves it disabled\n",
        prog);
}

static void print_summary(const struct pw_config *cfg, const struct pw_program *prog) {
    printf("packetwyrmd %s\n", pw_version_string());
    printf("system: %s (mode=%s, speed=%s)\n",
           cfg->system.name, cfg->system.mode, cfg->system.default_speed);
    printf("cards: %zu, logical_interfaces: %zu, flows: %zu\n",
           cfg->n_cards, cfg->n_logical_if, cfg->n_flows);
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        printf("  flow id=%u tx=p%u rx=p%u latency_valid=%s\n",
               f->id, f->tx_global_port, f->rx_global_port,
               m->latency_valid ? "yes" : "no (cross-card)");
    }
}

static void open_all_backends(const struct pw_config *cfg,
                              struct card_runtime cards[]) {
    for (size_t i = 0; i < cfg->n_cards; i++) {
        cards[i].which = "bar";
        pw_status br = pw_bar_backend_open(cfg->cards[i].pci, &cards[i].backend);
        if (br != PW_OK) {
            cards[i].which = "fake";
            br = pw_fake_backend_open(cfg->cards[i].pci, &cards[i].backend);
        }
        cards[i].open = (br == PW_OK);
        if (!cards[i].open) {
            fprintf(stderr, "could not open backend for %s (%s): %s\n",
                    cfg->cards[i].pci, cfg->cards[i].name, pw_strerror(br));
        }
    }
}

static void close_all_backends(const struct pw_config *cfg,
                               struct card_runtime cards[]) {
    for (size_t i = 0; i < cfg->n_cards; i++)
        if (cards[i].open) pw_card_backend_close(&cards[i].backend);
}

/* Pick the backend that owns a given global_port via the config. */
static struct pw_card_backend *backend_for_lif(
        const struct pw_config *cfg,
        struct card_runtime cards[],
        const struct pw_logical_if *lif,
        uint8_t *out_egress_local_port) {
    struct pwfpga_port_ref ref;
    if (pw_config_resolve_port(cfg, lif->global_port, &ref) != PW_OK) return NULL;
    for (size_t i = 0; i < cfg->n_cards; i++) {
        if (cfg->cards[i].id == ref.card_id && cards[i].open) {
            if (out_egress_local_port) *out_egress_local_port = ref.local_port_id;
            return &cards[i].backend;
        }
    }
    return NULL;
}

struct tap_handle {
    int      fd;
    uint32_t lif_id;
    char     name[PW_TAP_IFNAME_MAX];
};

static int setup_taps(const struct pw_config *cfg,
                      struct card_runtime cards[],
                      struct pw_host_plane *hps[MAX_CARDS],
                      struct tap_handle    *taps,
                      bool verbose) {
    int n_taps = 0;
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        const struct pw_logical_if *lif = &cfg->logical_if[i];
        uint8_t egress_lp = 0;
        struct pw_card_backend *b = backend_for_lif(cfg, cards, lif, &egress_lp);
        if (!b) {
            fprintf(stderr, "logical_if %s: no backend (port unresolved)\n", lif->name);
            continue;
        }
        int fd = -1;
        char actual[PW_TAP_IFNAME_MAX] = {0};
        pw_status r = pw_tap_open(lif->name, &fd, actual);
        if (r != PW_OK) {
            fprintf(stderr, "logical_if %s: pw_tap_open failed: %s\n",
                    lif->name, pw_strerror(r));
            continue;
        }
        pw_tap_set_mac(actual, lif->mac);
        if (lif->mtu) pw_tap_set_mtu(actual, lif->mtu);
        pw_tap_set_up(actual, true);

        /* Find the host_plane belonging to this lif's card. */
        size_t card_index = SIZE_MAX;
        for (size_t k = 0; k < cfg->n_cards; k++)
            if (&cards[k].backend == b) { card_index = k; break; }
        if (card_index >= MAX_CARDS) { pw_tap_close(fd); continue; }

        if (!hps[card_index]) {
            hps[card_index] = calloc(1, sizeof(*hps[card_index]));
            pw_host_plane_init(hps[card_index], b);
        }
        pw_status br = pw_host_plane_bind(hps[card_index], lif->id, fd, egress_lp);
        if (br != PW_OK) {
            fprintf(stderr, "logical_if %s: bind failed: %s\n",
                    lif->name, pw_strerror(br));
            pw_tap_close(fd);
            continue;
        }
        taps[n_taps] = (struct tap_handle){ .fd = fd, .lif_id = lif->id };
        snprintf(taps[n_taps].name, sizeof(taps[n_taps].name), "%s", actual);
        if (verbose)
            printf("  tap %-16s lif_id=%u egress_local=%u backend=%s\n",
                   actual, lif->id, egress_lp,
                   &cards[card_index].backend == b ? cards[card_index].which : "?");
        n_taps++;
    }
    return n_taps;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/* ---- JSON RPC ----------------------------------------------------- */

static struct json_object *build_version(void) {
    struct json_object *r = json_object_new_object();
    json_object_object_add(r, "version", json_object_new_string(pw_version_string()));
    return r;
}

static struct json_object *build_cards(const struct pw_config *cfg,
                                       struct card_runtime cards[]) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_cards; i++) {
        struct json_object *c = json_object_new_object();
        json_object_object_add(c, "id",       json_object_new_int(cfg->cards[i].id));
        json_object_object_add(c, "name",     json_object_new_string(cfg->cards[i].name));
        json_object_object_add(c, "pci",      json_object_new_string(cfg->cards[i].pci));
        json_object_object_add(c, "backend",  json_object_new_string(
            cards[i].open ? cards[i].which : "absent"));
        json_object_object_add(c, "open",     json_object_new_boolean(cards[i].open));
        json_object_array_add(arr, c);
    }
    json_object_object_add(r, "cards", arr);
    return r;
}

static struct json_object *build_ports(const struct pw_config *cfg) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        for (size_t p = 0; p < c->n_ports; p++) {
            struct json_object *po = json_object_new_object();
            json_object_object_add(po, "name",        json_object_new_string(c->ports[p].name));
            json_object_object_add(po, "card_id",     json_object_new_int(c->id));
            json_object_object_add(po, "local_port",  json_object_new_int(c->ports[p].local_port));
            json_object_object_add(po, "global_port", json_object_new_int(c->ports[p].global_port));
            json_object_array_add(arr, po);
        }
    }
    json_object_object_add(r, "ports", arr);
    return r;
}

static struct json_object *build_flows(const struct pw_config *cfg,
                                       const struct pw_program *prog) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        struct json_object *fl = json_object_new_object();
        json_object_object_add(fl, "id",            json_object_new_int64(f->id));
        json_object_object_add(fl, "name",          json_object_new_string(f->name));
        json_object_object_add(fl, "tx_global_port",json_object_new_int(f->tx_global_port));
        json_object_object_add(fl, "rx_global_port",json_object_new_int(f->rx_global_port));
        json_object_object_add(fl, "tx_card_id",    json_object_new_int(m->tx_card_id));
        json_object_object_add(fl, "rx_card_id",    json_object_new_int(m->rx_card_id));
        json_object_object_add(fl, "latency_valid", json_object_new_boolean(m->latency_valid));
        json_object_array_add(arr, fl);
    }
    json_object_object_add(r, "flows", arr);
    return r;
}

static struct json_object *build_stats(const struct pw_config *cfg,
                                       struct card_runtime cards[],
                                       struct pw_host_plane *hps[MAX_CARDS],
                                       int filter_card_id) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_cards; i++) {
        if (filter_card_id >= 0 && (int)cfg->cards[i].id != filter_card_id) continue;
        struct json_object *c = json_object_new_object();
        json_object_object_add(c, "card_id", json_object_new_int(cfg->cards[i].id));
        json_object_object_add(c, "open",    json_object_new_boolean(cards[i].open));
        json_object_object_add(c, "backend", json_object_new_string(
            cards[i].open ? cards[i].which : "absent"));
        uint64_t pok = 0, pdrop = 0, tok = 0, tdrop = 0;
        if (hps[i]) {
            for (size_t j = 0; j < hps[i]->n_bindings; j++) {
                pok   += hps[i]->punt_to_tap_ok[j];
                pdrop += hps[i]->punt_to_tap_dropped[j];
                tok   += hps[i]->tap_to_fpga_ok[j];
                tdrop += hps[i]->tap_to_fpga_dropped[j];
            }
        }
        json_object_object_add(c, "punt_to_tap_ok",      json_object_new_int64((int64_t)pok));
        json_object_object_add(c, "punt_to_tap_dropped", json_object_new_int64((int64_t)pdrop));
        json_object_object_add(c, "tap_to_fpga_ok",      json_object_new_int64((int64_t)tok));
        json_object_object_add(c, "tap_to_fpga_dropped", json_object_new_int64((int64_t)tdrop));
        json_object_object_add(c, "punt_unknown_lif",
            json_object_new_int64(hps[i] ? (int64_t)hps[i]->punt_unknown_lif : 0));
        json_object_array_add(arr, c);
    }
    json_object_object_add(r, "stats", arr);
    return r;
}

static struct json_object *build_error(const char *msg) {
    struct json_object *r = json_object_new_object();
    json_object_object_add(r, "error", json_object_new_string(msg));
    return r;
}

/* Handle one connection: read one request frame, dispatch, write
 * one response frame. */
static void handle_client(int cfd,
                          const struct pw_config *cfg,
                          const struct pw_program *prog,
                          struct card_runtime cards[],
                          struct pw_host_plane *hps[MAX_CARDS]) {
    uint8_t buf[PW_IPC_FRAME_MAX];
    size_t  got = 0;
    if (pw_ipc_read_frame(cfd, buf, sizeof(buf), &got) != PW_OK) return;

    struct json_tokener *tok = json_tokener_new();
    struct json_object  *req = json_tokener_parse_ex(tok, (char *)buf, (int)got);
    json_tokener_free(tok);

    struct json_object *resp = NULL;
    if (!req) {
        resp = build_error("invalid JSON");
    } else {
        struct json_object *rpc;
        const char *name = NULL;
        if (json_object_object_get_ex(req, "rpc", &rpc)) {
            name = json_object_get_string(rpc);
        }
        if      (!name)                     resp = build_error("missing rpc");
        else if (!strcmp(name, "version"))  resp = build_version();
        else if (!strcmp(name, "cards"))    resp = build_cards(cfg, cards);
        else if (!strcmp(name, "ports"))    resp = build_ports(cfg);
        else if (!strcmp(name, "flows"))    resp = build_flows(cfg, prog);
        else if (!strcmp(name, "stats")) {
            struct json_object *jc;
            int card_filter = -1;
            if (json_object_object_get_ex(req, "card", &jc)) {
                card_filter = json_object_get_int(jc);
            }
            resp = build_stats(cfg, cards, hps, card_filter);
        } else {
            resp = build_error("unknown rpc");
        }
        json_object_put(req);
    }

    const char *out = json_object_to_json_string_ext(resp, JSON_C_TO_STRING_PLAIN);
    pw_ipc_write_frame(cfd, out, strlen(out));
    json_object_put(resp);
}

/* ---- Prometheus exporter --------------------------------------------- */

static int promex_listen(int port, int *out_fd) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_ANY),
        .sin_port = htons((uint16_t)port),
    };
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    *out_fd = fd;
    return 0;
}

static size_t promex_build_body(char *out, size_t cap,
                                const struct pw_config *cfg,
                                struct card_runtime cards[],
                                struct pw_host_plane *hps[MAX_CARDS]) {
    size_t n = 0;
    #define APPENDF(...) do { \
        int _w = snprintf(out + n, cap - n, __VA_ARGS__); \
        if (_w > 0 && (size_t)_w < cap - n) n += (size_t)_w; \
    } while (0)
    APPENDF("# HELP packetwyrm_build_info Build info\n");
    APPENDF("# TYPE packetwyrm_build_info gauge\n");
    APPENDF("packetwyrm_build_info{version=\"%s\"} 1\n", pw_version_string());
    APPENDF("# HELP packetwyrm_card_open Whether the card backend is open\n");
    APPENDF("# TYPE packetwyrm_card_open gauge\n");
    APPENDF("# HELP packetwyrm_punt_to_tap_ok Total punt frames forwarded to TAPs\n");
    APPENDF("# TYPE packetwyrm_punt_to_tap_ok counter\n");
    APPENDF("# HELP packetwyrm_punt_to_tap_dropped Total punt frames dropped on TAP write\n");
    APPENDF("# TYPE packetwyrm_punt_to_tap_dropped counter\n");
    APPENDF("# HELP packetwyrm_tap_to_fpga_ok Total TAP-read frames forwarded to slow-path TX\n");
    APPENDF("# TYPE packetwyrm_tap_to_fpga_ok counter\n");
    APPENDF("# HELP packetwyrm_tap_to_fpga_dropped Total TAP-read frames dropped\n");
    APPENDF("# TYPE packetwyrm_tap_to_fpga_dropped counter\n");
    APPENDF("# HELP packetwyrm_punt_unknown_lif Total punts with an unbound logical_if_id\n");
    APPENDF("# TYPE packetwyrm_punt_unknown_lif counter\n");

    for (size_t i = 0; i < cfg->n_cards; i++) {
        uint64_t pok=0, pdrop=0, tok2=0, tdrop=0, unk=0;
        if (hps[i]) {
            for (size_t j = 0; j < hps[i]->n_bindings; j++) {
                pok   += hps[i]->punt_to_tap_ok[j];
                pdrop += hps[i]->punt_to_tap_dropped[j];
                tok2  += hps[i]->tap_to_fpga_ok[j];
                tdrop += hps[i]->tap_to_fpga_dropped[j];
            }
            unk = hps[i]->punt_unknown_lif;
        }
        unsigned id = cfg->cards[i].id;
        APPENDF("packetwyrm_card_open{card=\"%u\"} %d\n", id, cards[i].open ? 1 : 0);
        APPENDF("packetwyrm_punt_to_tap_ok{card=\"%u\"} %lu\n",       id, (unsigned long)pok);
        APPENDF("packetwyrm_punt_to_tap_dropped{card=\"%u\"} %lu\n",  id, (unsigned long)pdrop);
        APPENDF("packetwyrm_tap_to_fpga_ok{card=\"%u\"} %lu\n",       id, (unsigned long)tok2);
        APPENDF("packetwyrm_tap_to_fpga_dropped{card=\"%u\"} %lu\n",  id, (unsigned long)tdrop);
        APPENDF("packetwyrm_punt_unknown_lif{card=\"%u\"} %lu\n",     id, (unsigned long)unk);
    }
    #undef APPENDF
    return n;
}

static void promex_handle(int cfd,
                          const struct pw_config *cfg,
                          struct card_runtime cards[],
                          struct pw_host_plane *hps[MAX_CARDS]) {
    /* Read until \r\n\r\n or some limit; we don't actually parse the
     * request, just acknowledge any GET and respond. */
    char req[1024];
    ssize_t n = read(cfd, req, sizeof(req) - 1);
    if (n <= 0) return;
    req[n] = 0;

    char body[16384];
    size_t bn = promex_build_body(body, sizeof(body), cfg, cards, hps);

    char hdr[256];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain; version=0.0.4\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n", bn);
    if (hn > 0 && write(cfd, hdr, (size_t)hn) < 0) return;
    ssize_t w = write(cfd, body, bn);
    (void)w;
}

/* ---- end Prometheus exporter ----------------------------------------- */

/* ---- end JSON RPC ----------------------------------------------------- */

static void print_stats(const struct pw_config *cfg,
                        struct card_runtime cards[],
                        struct pw_host_plane *hps[MAX_CARDS]) {
    printf("--- stats @ %.3f s ---\n", (double)now_ms() / 1000.0);
    for (size_t i = 0; i < cfg->n_cards; i++) {
        if (!cards[i].open) continue;
        printf("  card%u(%s) backend=%s",
               (unsigned)cfg->cards[i].id, cfg->cards[i].name, cards[i].which);
        if (hps[i]) {
            uint64_t pok = 0, pdrop = 0, tok = 0, tdrop = 0;
            for (size_t j = 0; j < hps[i]->n_bindings; j++) {
                pok   += hps[i]->punt_to_tap_ok[j];
                pdrop += hps[i]->punt_to_tap_dropped[j];
                tok   += hps[i]->tap_to_fpga_ok[j];
                tdrop += hps[i]->tap_to_fpga_dropped[j];
            }
            printf("  punts=%lu/%lu  injects=%lu/%lu  unknown_lif=%lu",
                   (unsigned long)pok, (unsigned long)pdrop,
                   (unsigned long)tok, (unsigned long)tdrop,
                   (unsigned long)hps[i]->punt_unknown_lif);
        }
        printf("\n");
    }
}

int main(int argc, char **argv) {
    const char *cfg_path = "/etc/packetwyrm/packetwyrm.yaml";
    bool dry_run        = false;
    bool verbose        = false;
    int  stats_interval = 5000;
    int  prom_port      = 0;

    int opt;
    while ((opt = getopt(argc, argv, "c:nvs:p:h")) != -1) {
        switch (opt) {
        case 'c': cfg_path = optarg; break;
        case 'n': dry_run = true; break;
        case 'v': verbose = true; break;
        case 's': stats_interval = atoi(optarg); break;
        case 'p': prom_port = atoi(optarg); break;
        case 'h': default: usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }

    struct pw_config  *cfg  = pw_config_new();
    struct pw_program *prog = pw_program_new();
    struct pw_diag     diag = {0};
    pw_status r;

    if ((r = pw_config_parse_file(cfg_path, cfg, &diag)) != PW_OK) {
        fprintf(stderr, "parse: %s at %s: %s\n", pw_strerror(r), diag.path, diag.message);
        return 1;
    }
    if ((r = pw_config_validate(cfg, &diag)) != PW_OK) {
        fprintf(stderr, "validate: %s at %s: %s\n", pw_strerror(r), diag.path, diag.message);
        return 1;
    }
    if ((r = pw_flow_compile(cfg, prog, &diag)) != PW_OK) {
        fprintf(stderr, "compile: %s at %s: %s\n", pw_strerror(r), diag.path, diag.message);
        return 1;
    }
    if (verbose || dry_run) print_summary(cfg, prog);
    if (dry_run) { pw_program_free(prog); pw_config_free(cfg); return 0; }

    struct card_runtime  cards[MAX_CARDS] = {0};
    struct pw_host_plane *hps[MAX_CARDS]  = {0};
    struct tap_handle    taps[PW_HOST_PLANE_MAX_BINDINGS] = {0};

    open_all_backends(cfg, cards);
    int n_taps = setup_taps(cfg, cards, hps, taps, true);
    if (n_taps == 0) {
        fprintf(stderr, "warning: no TAPs were created\n");
    }

    /* Control socket. Path comes from config; fall back to the
     * library default. Permissions 0666 in the dev container so
     * tests run without group setup. Production deployments will
     * tighten this via udev / the daemon's own user/group. */
    int ipc_listen_fd = -1;
    const char *sock_path = cfg->system.control_socket[0]
        ? cfg->system.control_socket
        : PW_IPC_DEFAULT_PATH;
    pw_status sr = pw_ipc_listen(sock_path, 0666, &ipc_listen_fd);
    if (sr != PW_OK) {
        fprintf(stderr, "warning: control socket on %s unavailable: %s\n",
                sock_path, pw_strerror(sr));
    } else if (verbose) {
        printf("  control socket listening on %s\n", sock_path);
    }

    int prom_fd = -1;
    if (prom_port > 0) {
        if (promex_listen(prom_port, &prom_fd) < 0) {
            fprintf(stderr, "warning: Prometheus listener on :%d failed\n", prom_port);
            prom_fd = -1;
        } else if (verbose) {
            printf("  Prometheus exporter on :%d/metrics\n", prom_port);
        }
    }

    struct sigaction sa = { .sa_handler = on_signal };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    uint64_t last_stats = now_ms();
    while (!g_stop) {
        /* Poll TAP fds + the control-socket listen fd. */
        struct pollfd pfds[PW_HOST_PLANE_MAX_BINDINGS + 1];
        size_t np = 0;
        for (int i = 0; i < n_taps; i++)
            pfds[np++] = (struct pollfd){ .fd = taps[i].fd, .events = POLLIN };
        size_t listen_idx = (size_t)-1, prom_idx = (size_t)-1;
        if (ipc_listen_fd >= 0) {
            listen_idx = np;
            pfds[np++] = (struct pollfd){ .fd = ipc_listen_fd, .events = POLLIN };
        }
        if (prom_fd >= 0) {
            prom_idx = np;
            pfds[np++] = (struct pollfd){ .fd = prom_fd, .events = POLLIN };
        }
        (void)poll(np ? pfds : NULL, np, 100);

        if (listen_idx != (size_t)-1 && (pfds[listen_idx].revents & POLLIN)) {
            int cfd = accept(ipc_listen_fd, NULL, NULL);
            if (cfd >= 0) {
                handle_client(cfd, cfg, prog, cards, hps);
                close(cfd);
            }
        }
        if (prom_idx != (size_t)-1 && (pfds[prom_idx].revents & POLLIN)) {
            int cfd = accept(prom_fd, NULL, NULL);
            if (cfd >= 0) {
                promex_handle(cfd, cfg, cards, hps);
                close(cfd);
            }
        }

        for (size_t i = 0; i < cfg->n_cards; i++)
            if (hps[i]) pw_host_plane_step(hps[i], 16);

        if (stats_interval > 0 &&
            (int)(now_ms() - last_stats) >= stats_interval) {
            print_stats(cfg, cards, hps);
            last_stats = now_ms();
        }
    }

    fprintf(stderr, "shutting down ...\n");
    if (prom_fd >= 0) close(prom_fd);
    if (ipc_listen_fd >= 0) {
        close(ipc_listen_fd);
        unlink(sock_path);
    }
    for (int i = 0; i < n_taps; i++) pw_tap_close(taps[i].fd);
    for (size_t i = 0; i < MAX_CARDS; i++) free(hps[i]);
    close_all_backends(cfg, cards);
    pw_program_free(prog);
    pw_config_free(cfg);
    return 0;
}
