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
        "usage: %s [-c CONFIG] [-n] [-v] [-s INTERVAL_MS]\n"
        "  -c CONFIG         path to packetwyrm.yaml\n"
        "  -n                dry run: parse + validate + compile, exit\n"
        "  -v                verbose\n"
        "  -s INTERVAL_MS    stats print interval (default 5000, 0 = off)\n",
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

    int opt;
    while ((opt = getopt(argc, argv, "c:nvs:h")) != -1) {
        switch (opt) {
        case 'c': cfg_path = optarg; break;
        case 'n': dry_run = true; break;
        case 'v': verbose = true; break;
        case 's': stats_interval = atoi(optarg); break;
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

    struct sigaction sa = { .sa_handler = on_signal };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    uint64_t last_stats = now_ms();
    while (!g_stop) {
        /* Build a poll set from all bound TAP fds so we wake on
         * any TAP read activity. The 100 ms timeout doubles as the
         * pacing for slow-path RX draining. */
        struct pollfd pfds[PW_HOST_PLANE_MAX_BINDINGS];
        size_t np = 0;
        for (int i = 0; i < n_taps; i++) {
            pfds[np++] = (struct pollfd){ .fd = taps[i].fd, .events = POLLIN };
        }
        int pr = poll(np ? pfds : NULL, np, 100);
        (void)pr;

        for (size_t i = 0; i < cfg->n_cards; i++)
            if (hps[i]) pw_host_plane_step(hps[i], 16);

        if (stats_interval > 0 &&
            (int)(now_ms() - last_stats) >= stats_interval) {
            print_stats(cfg, cards, hps);
            last_stats = now_ms();
        }
    }

    fprintf(stderr, "shutting down ...\n");
    for (int i = 0; i < n_taps; i++) pw_tap_close(taps[i].fd);
    for (size_t i = 0; i < MAX_CARDS; i++) free(hps[i]);
    close_all_backends(cfg, cards);
    pw_program_free(prog);
    pw_config_free(cfg);
    return 0;
}
