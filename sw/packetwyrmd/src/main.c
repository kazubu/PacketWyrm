/* packetwyrmd: load + compile the config, open backends, program the cards,
 * create TAPs, and serve control RPCs until SIGINT/SIGTERM. Runs one host-plane
 * worker thread per card (punt RX -> TAP, TAP -> slow-path inject), a JSON-RPC
 * control socket (config.load with rollback, flow/test control, stats/hist
 * reads), and an optional Prometheus exporter. Works against the real BAR
 * backend or, with -F, the no-op fake backend. */

#include <errno.h>
#include <getopt.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
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
#include "packetwyrm/spi_flash.h"
#include "packetwyrm/gpio_sync.h"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

#define MAX_CARDS PW_MAX_CARDS

struct card_runtime {
    struct pw_card_backend backend;
    const char            *which;
    bool                   open;
};

/* One worker per opened card: drains its TAP fds and runs the
 * host_plane bridge. The control socket and Prometheus listener
 * stay on the main thread, so the slow path latency on one card
 * cannot be starved by a busy control socket or by another card.
 *
 * The per-card host_plane has no shared mutable state with the
 * other workers; the slow_path_rx / slow_path_tx ops it calls
 * touch disjoint regions of the backend (and disjoint files for
 * the fake backend). The stats counters inside pw_host_plane are
 * read from the main thread for print_stats / build_stats; that's
 * a benign race (best-effort snapshot for a human-facing table),
 * documented in pw_host_plane.h. */
struct card_worker_ctx {
    struct pw_host_plane *hp;
    int                   fds[PW_HOST_PLANE_MAX_BINDINGS];
    int                   n_fds;
    atomic_bool           stop;
    pthread_t             tid;
    bool                  running;
};

static void *card_worker_main(void *arg) {
    struct card_worker_ctx *w = arg;
    struct pollfd pfds[PW_HOST_PLANE_MAX_BINDINGS];
    while (!atomic_load_explicit(&w->stop, memory_order_relaxed)) {
        for (int i = 0; i < w->n_fds; i++)
            pfds[i] = (struct pollfd){ .fd = w->fds[i], .events = POLLIN };
        /* 100 ms cap so the stop flag is observed promptly even
         * when no traffic flows. */
        (void)poll(w->n_fds ? pfds : NULL, w->n_fds, 100);
        pw_host_plane_step(w->hp, 16);
    }
    return NULL;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [-c CONFIG] [-n] [-v] [-s INTERVAL_MS] [-p PROMETHEUS_PORT] [-F]\n"
        "  -c CONFIG         path to packetwyrm.yaml\n"
        "  -n                dry run: parse + validate + compile, exit\n"
        "  -v                verbose\n"
        "  -s INTERVAL_MS    stats print interval (default 5000, 0 = off)\n"
        "  -p PORT           bind a Prometheus /metrics exporter on this TCP\n"
        "                    port; 0 (default) leaves it disabled\n"
        "  -F                allow falling back to the no-op fake backend when a\n"
        "                    card's BAR cannot be opened (dev/CI; default: error)\n",
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
        printf("  flow id=%u tx=p%u rx=p%u latency=%s\n",
               f->id, f->tx_global_port, f->rx_global_port,
               m->latency_valid ? "same-card" : "gpio-corrected (cross-card)");
    }
}

static void open_all_backends(const struct pw_config *cfg,
                              struct card_runtime cards[], bool allow_fake) {
    for (size_t i = 0; i < cfg->n_cards; i++) {
        cards[i].which = "bar";
        pw_status br = pw_bar_backend_open(cfg->cards[i].pci, &cards[i].backend);
        if (br != PW_OK && allow_fake) {
            /* Only fall back to the no-op fake backend when explicitly asked
             * (--allow-fake / -F). Falling back by default produced a daemon
             * that looks healthy but silently drops all CSR writes -- "running
             * but not transmitting". On real deployments a BAR-open failure is
             * an error the operator must see. */
            fprintf(stderr, "warning: %s (%s): BAR open failed (%s); "
                    "using fake backend (--allow-fake)\n",
                    cfg->cards[i].pci, cfg->cards[i].name, pw_strerror(br));
            cards[i].which = "fake";
            br = pw_fake_backend_open(cfg->cards[i].pci, &cards[i].backend);
        }
        cards[i].open = (br == PW_OK);
        if (!cards[i].open) {
            fprintf(stderr, "could not open backend for %s (%s): %s%s\n",
                    cfg->cards[i].pci, cfg->cards[i].name, pw_strerror(br),
                    allow_fake ? "" : " (pass --allow-fake to use the no-op backend)");
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

/* ---- Backend programming -------------------------------------------- */

/* Push the compiled per-card program into each open backend. Returns the worst
 * *hard* status seen (PW_OK if all writes succeeded or only returned
 * NOT_IMPLEMENTED, which is the legacy soft case for a bitstream lacking a
 * window). A real fault (BAR write error, card drop) is returned so the caller
 * can report that the FPGA is NOT in sync with the daemon's config. The table
 * write sequence itself lives in libpacketwyrm (pw_program_card_tables) so it is
 * shared with the unit tests; here we add the per-card data-plane quiesce. */
/* If any flow crosses cards, bring up the J5 time-sync so cross-card latency
 * can be offset-corrected: one master drives the shared edge, every other card
 * latches it. A single master suffices -- offset(any pair) = txcard_ts - rxcard_ts
 * since both latch the same edge. (Cross-wired J5; the master drives out pin 1,
 * slaves listen on in pin 0; period_log2=15.) Best-effort. */
static void setup_gpio_sync(const struct pw_config *cfg,
                            const struct pw_program *prog,
                            struct card_runtime cards[]) {
    bool any_cross = false;
    for (size_t i = 0; i < prog->n_flow_meta; i++)
        if (prog->flow_meta[i].tx_card_id != prog->flow_meta[i].rx_card_id) { any_cross = true; break; }
    int master_ci = -1;
    for (size_t ci = 0; ci < cfg->n_cards; ci++)
        if (cards[ci].open) { master_ci = (int)ci; break; }
    if (master_ci < 0) return;
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (!cards[ci].open) continue;
        if (!any_cross) {
            pw_gpio_sync_disable(&cards[ci].backend);
            /* No cross-card flow -> reset the HW latency correction to 0 so any
             * leftover offset from a previous config can't bias same-card or
             * fresh measurements. The servo only writes nonzero for cross-card. */
            pw_gpio_sync_write_correction(&cards[ci].backend, 0);
        } else if ((int)ci == master_ci) pw_gpio_sync_master(&cards[ci].backend, 1, 15);
        else                          pw_gpio_sync_slave(&cards[ci].backend, 0);
    }
}

/* Cross-card latency servo. For every open card, write its desired HW latency
 * correction to the lat_correction CSR: 0 if the card is not the RX side of any
 * cross-card flow, else the current inter-card counter offset (tx_cnt - rx_cnt)
 * so the RX checker accumulates the TRUE one-way latency per sample (the ~ppm
 * skew is re-tracked each tick, so min/max/avg/histogram stay un-smeared). Run
 * ~10x/s from the main loop. STAGE 1 is global-per-RX-card: a card that receives
 * BOTH a cross-card and a same-card flow would apply the correction to both --
 * the validated rigs don't do that; per-flow correction is a later stage. */
static void servo_lat_correction(const struct pw_config *cfg,
                                 const struct pw_program *prog,
                                 struct card_runtime cards[]) {
    for (size_t rx_ci = 0; rx_ci < cfg->n_cards; rx_ci++) {
        if (!cards[rx_ci].open) continue;
        /* Find this card's single cross-card TX source (stage-1: at most one,
         * enforced by the validator). */
        size_t tx_ci = (size_t)-1;
        for (size_t i = 0; i < prog->n_flow_meta; i++) {
            const struct pw_flow_meta *m = &prog->flow_meta[i];
            if (m->tx_card_id == m->rx_card_id) continue;        /* same-card: no corr */
            if (cfg->cards[rx_ci].id != m->rx_card_id) continue; /* not this RX card */
            for (size_t ci = 0; ci < cfg->n_cards; ci++)
                if (cfg->cards[ci].id == m->tx_card_id) { tx_ci = ci; break; }
            break;   /* one cross-card source per RX card (stage-1 assumption) */
        }
        if (tx_ci == (size_t)-1) {                  /* not a cross-card RX card */
            pw_gpio_sync_write_correction(&cards[rx_ci].backend, 0);
            continue;
        }
        if (!cards[tx_ci].open) continue;
        int64_t corr = 0;
        /* Only write an EDGE-COHERENT offset; on an incoherent read (an edge fell
         * mid-sample -> a ~1-period-wrong value) skip this tick and keep the
         * current correction, rather than briefly corrupt the latency. */
        if (pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &corr))
            pw_gpio_sync_write_correction(&cards[rx_ci].backend, corr);
    }
}

/* One-shot priming of the HW latency correction after (re)programming, to close
 * the window where cross-card flows would accumulate raw (correction-0) latency.
 * No cross-card flow -> nothing to do (correction stays 0; setup_gpio_sync also
 * zeroed it). Otherwise, per cross-card RX card: write a CONFIRMED edge-coherent
 * correction (retrying while the J5 sync comes up), and only THEN stats-clear
 * that card so its polluted startup samples are discarded against a known-good
 * correction. If no coherent offset materialises in the budget, the card is left
 * un-cleared (NOT started "clean" on a stale/0 correction) and a warning is
 * logged; the main-loop servo keeps trying and converges, and a later
 * stats.clear / test.arm gives the clean baseline. */
static void prime_lat_correction(const struct pw_config *cfg,
                                 const struct pw_program *prog,
                                 struct card_runtime cards[]) {
    bool any_cross = false;
    for (size_t i = 0; i < prog->n_flow_meta; i++)
        if (prog->flow_meta[i].tx_card_id != prog->flow_meta[i].rx_card_id) { any_cross = true; break; }
    if (!any_cross) return;

    /* Zero the correction on every non-cross-card-RX card up front (a sync slave
     * that only carries same-card flows must not keep a stale correction). */
    servo_lat_correction(cfg, prog, cards);

    for (size_t rx_ci = 0; rx_ci < cfg->n_cards; rx_ci++) {
        if (!cards[rx_ci].open) continue;
        /* this card's single cross-card TX source (stage-1: at most one) */
        size_t tx_ci = (size_t)-1;
        for (size_t i = 0; i < prog->n_flow_meta; i++) {
            const struct pw_flow_meta *m = &prog->flow_meta[i];
            if (m->tx_card_id == m->rx_card_id) continue;
            if (cfg->cards[rx_ci].id != m->rx_card_id) continue;
            for (size_t ci = 0; ci < cfg->n_cards; ci++)
                if (cfg->cards[ci].id == m->tx_card_id) { tx_ci = ci; break; }
            break;
        }
        if (tx_ci == (size_t)-1 || !cards[tx_ci].open) continue;   /* not a cross-card RX */

        /* Retry for the J5 sync to come up (period ~210us; 200x1ms = 200ms of
         * headroom) and a coherent offset to be readable; write it, then clear. */
        bool wrote = false;
        for (int tries = 0; tries < 200 && !wrote; tries++) {
            int64_t corr;
            if (pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &corr)) {
                pw_gpio_sync_write_correction(&cards[rx_ci].backend, corr);
                wrote = true;
                break;
            }
            usleep(1000);
        }
        if (wrote) {
            if (cards[rx_ci].backend.ops->write32)
                (void)cards[rx_ci].backend.ops->write32(
                    cards[rx_ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
        } else {
            fprintf(stderr, "warning: card%u cross-card latency correction not "
                    "ready (no coherent J5 offset); stats left as-is, the servo "
                    "will converge -- stats.clear once it's up for a clean run\n",
                    (unsigned)cfg->cards[rx_ci].id);
        }
    }
}

static pw_status program_backends(const struct pw_program *prog,
                                  const struct pw_config *cfg,
                                  struct card_runtime cards[]) {
    pw_status worst = PW_OK;
    for (size_t ci = 0; ci < prog->n_cards; ci++) {
        const struct pw_card_program *cp = &prog->per_card[ci];
        if (!cards[ci].open) continue;
        const struct pw_card_backend *b = &cards[ci].backend;
        /* Soft-reset the data plane before (re)writing the tables: quiesce the
         * generators / SAF / arbiters (and flush the MAC-TX CDC FIFO + ts_insert
         * via the CDC'd pulse) so reprogramming over a running data plane cannot
         * wedge it (configuration is preserved; the commit below re-applies it).
         * Note: this does not reset the MAC/PCS/GT or a stopped TX clock. */
        if (b->ops->write32) {
            pw_status s = b->ops->write32(b->ctx, PWFPGA_REG_DP_RESET, 1u);
            if (s != PW_OK && s != PW_E_NOT_IMPLEMENTED && worst == PW_OK) worst = s;
        }
        pw_status s = pw_program_card_tables(b->ops, b->ctx, cp);
        if (s != PW_OK && worst == PW_OK) worst = s;
    }
    /* Bring up J5 time-sync for cross-card flows (latency offset correction). */
    setup_gpio_sync(cfg, prog, cards);
    /* Close the startup window: programming above already enabled the flow
     * generators (tx_enable in the rows), so the RX checker is ALREADY counting
     * -- with lat_correction still 0. For a cross-card flow that means the first
     * samples accumulate the raw (wrong-timebase, huge-wrap) latency into
     * max/sum/histogram. So once the J5 sync has produced a valid edge, write
     * the initial correction and stats-clear every card, so accumulation starts
     * from the corrected baseline. (The main-loop servo then maintains it.) */
    prime_lat_correction(cfg, prog, cards);
    return worst;
}

/* Look up the (tx) row index for a given global_flow_id. */
static int find_tx_row(const struct pw_program *prog,
                       uint32_t global_flow_id,
                       int *out_card_idx, uint32_t *out_row) {
    const struct pw_flow_meta *m = NULL;
    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        if (prog->flow_meta[i].global_flow_id == global_flow_id) {
            m = &prog->flow_meta[i];
            break;
        }
    }
    if (!m) return -1;
    for (size_t ci = 0; ci < prog->n_cards; ci++) {
        if (prog->per_card[ci].card_id != m->tx_card_id) continue;
        const struct pw_card_program *cp = &prog->per_card[ci];
        for (size_t r = 0; r < cp->n_flow_rows; r++) {
            if (cp->flow_rows[r].local_flow_id == m->tx_local_flow_id) {
                *out_card_idx = (int)ci;
                *out_row      = (uint32_t)r;
                return 0;
            }
        }
    }
    return -1;
}

/* Re-write the TX flow row of `global_flow_id` with `enable` set
 * accordingly, then commit. */
static pw_status set_flow_enable(struct pw_program *prog,
                                 struct card_runtime cards[],
                                 uint32_t global_flow_id,
                                 bool enable) {
    int      ci  = -1;
    uint32_t row = 0;
    if (find_tx_row(prog, global_flow_id, &ci, &row) < 0) return PW_E_INVAL;
    if (!cards[ci].open) return PW_E_NO_CARD;
    struct pwfpga_flow_config *fc = &prog->per_card[ci].flow_rows[row];
    fc->enable    = enable ? 1 : 0;
    fc->tx_enable = enable ? 1 : 0;
    const struct pw_card_backend *b = &cards[ci].backend;
    pw_status s = b->ops->flow_write
        ? b->ops->flow_write(b->ctx, row, fc)
        : PW_E_NOT_IMPLEMENTED;
    if (s == PW_OK && b->ops->flow_commit)
        s = b->ops->flow_commit(b->ctx);
    return s;
}

/* ---- end backend programming ---------------------------------------- */

static struct json_object *build_error(const char *msg);

/* Attempt a live program swap from a YAML string. Returns a JSON
 * response describing success or the failure mode. On any failure
 * before the actual swap, the in-flight program stays live; the
 * previous configuration is undisturbed.
 *
 * V1 constraint: the new config must declare the same set of cards
 * and logical_ifs as the running one (same counts and same id->name
 * mapping). Changes to TAP / backend binding require a full daemon
 * restart, since live unplugging a TAP / backend mid-traffic isn't
 * safe yet. */
static bool same_topology(const struct pw_config *a,
                          const struct pw_config *b) {
    if (a->n_cards != b->n_cards) return false;
    if (a->n_logical_if != b->n_logical_if) return false;
    for (size_t i = 0; i < a->n_cards; i++) {
        if (a->cards[i].id != b->cards[i].id) return false;
    }
    for (size_t i = 0; i < a->n_logical_if; i++) {
        if (a->logical_if[i].id != b->logical_if[i].id) return false;
    }
    return true;
}

static struct json_object *do_config_load(struct pw_config  **cfg_pp,
                                          struct pw_program **prog_pp,
                                          struct card_runtime cards[],
                                          struct json_object *req) {
    struct json_object *jy;
    if (!json_object_object_get_ex(req, "yaml", &jy) ||
        json_object_get_type(jy) != json_type_string) {
        return build_error("missing yaml");
    }
    const char *yaml = json_object_get_string(jy);
    size_t yaml_len  = strlen(yaml);

    struct pw_config  *new_cfg  = pw_config_new();
    struct pw_program *new_prog = pw_program_new();
    struct pw_diag     diag = {0};
    struct json_object *resp = NULL;

    pw_status r = pw_config_parse_string(yaml, yaml_len, new_cfg, &diag);
    if (r != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "parse: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }
    if ((r = pw_config_validate(new_cfg, &diag)) != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "validate: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }
    if (!same_topology(*cfg_pp, new_cfg)) {
        resp = build_error("topology change (cards / logical_ifs) requires restart");
        goto fail;
    }
    if ((r = pw_flow_compile(new_cfg, new_prog, &diag)) != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "compile: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }

    /* Stop running flows on the live program so we don't briefly
     * dual-program two distinct flow sets. Best-effort: failures here
     * don't block the swap; the new program's commit will override
     * any stale row anyway. */
    for (size_t k = 0; k < (*prog_pp)->n_flow_meta; k++) {
        (void)set_flow_enable(*prog_pp, cards,
                              (*prog_pp)->flow_meta[k].global_flow_id, false);
    }

    /* Stage: program the new config into every open backend. On a hard fault
     * (card drop / BAR error) ROLL BACK -- re-program the previous config so the
     * FPGA matches the daemon's unchanged view, keep the old config running, and
     * reject the load. A half-applied config (daemon view != FPGA) is the worst
     * failure mode for a tester; see docs/design/daemon.md. */
    pw_status prog_st = program_backends(new_prog, new_cfg, cards);
    if (prog_st != PW_OK) {
        fprintf(stderr, "load: stage failed (%s) -- rolling back to the previous "
                "config (still running)\n", pw_strerror(prog_st));
        (void)program_backends(*prog_pp, *cfg_pp, cards);   /* restore the FPGA */
        pw_program_free(new_prog);
        pw_config_free(new_cfg);
        char msg[160];
        snprintf(msg, sizeof msg,
                 "stage failed (%s); rolled back, previous config still running",
                 pw_strerror(prog_st));
        return build_error(msg);
    }

    /* Success: swap the daemon's view to the new (now-programmed) config. */
    pw_program_free(*prog_pp);
    pw_config_free(*cfg_pp);
    *cfg_pp  = new_cfg;
    *prog_pp = new_prog;

    resp = json_object_new_object();
    json_object_object_add(resp, "ok", json_object_new_boolean(true));
    json_object_object_add(resp, "n_flows",
                           json_object_new_int((int)new_cfg->n_flows));
    {
        size_t total_rules = 0;
        for (size_t ci = 0; ci < new_prog->n_cards; ci++)
            total_rules += new_prog->per_card[ci].n_fc_rules;
        /* Key name matches the CLI + docs/design/rpc-protocol.md contract;
         * a prior n_classifier_rules typo made the CLI print 0 rows. */
        json_object_object_add(resp, "n_classifier_rows",
                               json_object_new_int((int)total_rules));
    }
    return resp;

fail:
    pw_program_free(new_prog);
    pw_config_free(new_cfg);
    return resp;
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
        /* Latency is now available for BOTH same-card (counter-direct) and
         * cross-card (HW lat_correction + J5 sync) flows, so latency_valid is
         * true for either; latency_method tells them apart (matches flow.stats).
         * m->latency_valid alone means "same-card exact" -- kept as the method. */
        bool xcard = (m->tx_card_id != m->rx_card_id);
        json_object_object_add(fl, "latency_valid", json_object_new_boolean(true));
        json_object_object_add(fl, "latency_method",
            json_object_new_string(xcard ? "gpio-corrected" : "same-card"));
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

/* Per-flow latency histogram. */
static struct json_object *build_flow_hist(const struct pw_config *cfg,
                                           const struct pw_program *prog,
                                           struct card_runtime cards[],
                                           int flow_id) {
    struct json_object *r = json_object_new_object();
    const struct pw_flow_meta *m = NULL;
    for (size_t i = 0; i < prog->n_flow_meta; i++)
        if ((int)prog->flow_meta[i].global_flow_id == flow_id) {
            m = &prog->flow_meta[i];
            break;
        }
    if (!m) {
        json_object_object_add(r, "error", json_object_new_string("unknown flow"));
        return r;
    }
    /* Cross-card histogram is now supported: the HW bins the per-sample
     * latency AFTER the lat_correction offset (the servo keeps it current), so
     * the buckets hold the true one-way latency, same as same-card. (Previously
     * punted: the HW binned the raw, uncorrected latency.) */
    size_t rx_ci = (size_t)-1;
    for (size_t ci = 0; ci < cfg->n_cards; ci++)
        if (cfg->cards[ci].id == m->rx_card_id) { rx_ci = ci; break; }
    if (rx_ci == (size_t)-1 || !cards[rx_ci].open ||
        !cards[rx_ci].backend.ops->flow_hist_read) {
        json_object_object_add(r, "error", json_object_new_string("backend not ready"));
        return r;
    }
    uint64_t buckets[64];
    size_t   n_buckets = 0;
    pw_status ss = cards[rx_ci].backend.ops->stats_snapshot(cards[rx_ci].backend.ctx);
    if (ss != PW_OK) {
        json_object_object_add(r, "error", json_object_new_string(pw_strerror(ss)));
        return r;
    }
    pw_status s = cards[rx_ci].backend.ops->flow_hist_read(
        cards[rx_ci].backend.ctx, m->rx_local_flow_id,
        buckets, sizeof(buckets) / sizeof(buckets[0]), &n_buckets);
    if (s != PW_OK) {
        json_object_object_add(r, "error", json_object_new_string(pw_strerror(s)));
        return r;
    }
    json_object_object_add(r, "id",        json_object_new_int(flow_id));
    json_object_object_add(r, "n_buckets", json_object_new_int((int)n_buckets));
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < n_buckets; i++)
        json_object_array_add(arr, json_object_new_int64((int64_t)buckets[i]));
    json_object_object_add(r, "buckets", arr);
    return r;
}

/* Per-flow stats: looks up each flow's RX card, asks for a
 * snapshot, and packs the resulting counters into JSON. */
static struct json_object *build_flow_stats(const struct pw_config *cfg,
                                            const struct pw_program *prog,
                                            struct card_runtime cards[],
                                            int filter_flow_id) {
    /* Trigger one snapshot per card so the counters are consistent
     * across the report. Cheap on the fake backend; the real BAR
     * backend writes the stats_snapshot_trigger CSR. */
    bool snap_ok[MAX_CARDS];
    for (size_t ci = 0; ci < cfg->n_cards && ci < MAX_CARDS; ci++) {
        snap_ok[ci] = true;
        if (cards[ci].open && cards[ci].backend.ops->stats_snapshot)
            snap_ok[ci] = (cards[ci].backend.ops->stats_snapshot(cards[ci].backend.ctx) == PW_OK);
    }

    struct json_object *r   = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        if (filter_flow_id >= 0 && (int)m->global_flow_id != filter_flow_id)
            continue;
        /* Find the RX card to pull stats from. */
        size_t rx_ci = (size_t)-1;
        for (size_t ci = 0; ci < cfg->n_cards; ci++)
            if (cfg->cards[ci].id == m->rx_card_id) { rx_ci = ci; break; }
        size_t tx_ci = (size_t)-1;
        for (size_t ci = 0; ci < cfg->n_cards; ci++)
            if (cfg->cards[ci].id == m->tx_card_id) { tx_ci = ci; break; }

        struct pw_flow_stats rs = {0}, ts = {0};
        /* read_ok=false whenever a counter source can't be read: card not found
         * for the flow, card not open, no stats op, or a failed snapshot/read.
         * Otherwise a dropped card / missing window reads as a genuine "0
         * traffic" result. (flow.hist reports the same via "backend not ready".) */
        bool read_ok = true;
        if (rx_ci != (size_t)-1 && cards[rx_ci].open &&
            cards[rx_ci].backend.ops->flow_stats_read) {
            read_ok &= (rx_ci < MAX_CARDS ? snap_ok[rx_ci] : true);
            read_ok &= (cards[rx_ci].backend.ops->flow_stats_read(
                cards[rx_ci].backend.ctx, m->rx_local_flow_id, &rs) == PW_OK);
        } else {
            read_ok = false;   // rx counters unreadable (no card / closed / no op)
        }
        if (tx_ci != (size_t)-1 && cards[tx_ci].open &&
            cards[tx_ci].backend.ops->flow_stats_read) {
            read_ok &= (tx_ci < MAX_CARDS ? snap_ok[tx_ci] : true);
            read_ok &= (cards[tx_ci].backend.ops->flow_stats_read(
                cards[tx_ci].backend.ctx, m->tx_local_flow_id, &ts) == PW_OK);
        } else {
            read_ok = false;   // tx counters unreadable
        }

        struct json_object *f = json_object_new_object();
        json_object_object_add(f, "id", json_object_new_int64(m->global_flow_id));
        json_object_object_add(f, "tx_card_id", json_object_new_int(m->tx_card_id));
        json_object_object_add(f, "rx_card_id", json_object_new_int(m->rx_card_id));
        /* read_ok=false => a snapshot/stats CSR read failed; the counters below
         * are stale/zero, NOT a genuine "0 traffic" result. */
        json_object_object_add(f, "read_ok", json_object_new_boolean(read_ok));
        json_object_object_add(f, "tx_frames", json_object_new_int64((int64_t)ts.tx_frames));
        json_object_object_add(f, "tx_bytes",  json_object_new_int64((int64_t)ts.tx_bytes));
        json_object_object_add(f, "rx_frames", json_object_new_int64((int64_t)rs.rx_frames));
        json_object_object_add(f, "rx_bytes",  json_object_new_int64((int64_t)rs.rx_bytes));
        json_object_object_add(f, "lost",      json_object_new_int64((int64_t)rs.lost_packets_estimated));
        json_object_object_add(f, "duplicate", json_object_new_int64((int64_t)rs.duplicate_count));
        json_object_object_add(f, "out_of_order", json_object_new_int64((int64_t)rs.out_of_order_count));
        json_object_object_add(f, "seq_gap",   json_object_new_int64((int64_t)rs.sequence_gap_count));
        json_object_object_add(f, "expected_seq", json_object_new_int64((int64_t)rs.expected_sequence));

        /* Cross-card latency is corrected PER SAMPLE in hardware: the daemon
         * servo writes the inter-card offset to each RX card's lat_correction
         * CSR, and the checker computes lat = (rx_wire_ts + offset) - tx_ts. So
         * min/max/sum/histogram already hold the true one-way latency here -- no
         * read-time correction, and avg (from the now-small 64-bit sum) is valid
         * for cross-card too. Same-card flows run with correction 0 (unchanged).
         * offset_ticks is reported for visibility (the live servo offset). */
        bool xcard = (m->tx_card_id != m->rx_card_id);
        bool lat_ok = m->latency_valid || (xcard && read_ok);
        json_object_object_add(f, "latency_valid", json_object_new_boolean(lat_ok));
        if (lat_ok) {
            json_object_object_add(f, "min_latency", json_object_new_int64((int64_t)(uint32_t)rs.min_latency));
            json_object_object_add(f, "max_latency", json_object_new_int64((int64_t)(uint32_t)rs.max_latency));
            int64_t avg = rs.sample_count ? (int64_t)(rs.sum_latency / rs.sample_count) : 0;
            json_object_object_add(f, "avg_latency", json_object_new_int64(avg));
            json_object_object_add(f, "sample_count",
                                   json_object_new_int64((int64_t)rs.sample_count));
            json_object_object_add(f, "jitter_min", json_object_new_int64((int64_t)rs.jitter_min));
            json_object_object_add(f, "jitter_max", json_object_new_int64((int64_t)rs.jitter_max));
            int64_t jit_avg = rs.sample_count
                ? (int64_t)(rs.jitter_sum / rs.sample_count)
                : 0;
            json_object_object_add(f, "jitter_avg", json_object_new_int64(jit_avg));
            json_object_object_add(f, "latency_method",
                json_object_new_string(xcard ? "gpio-corrected" : "same-card"));
            if (xcard && tx_ci != (size_t)-1 && rx_ci != (size_t)-1) {
                int64_t off = 0;   /* informational: the live (edge-coherent) servo offset */
                if (pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &off))
                    json_object_object_add(f, "offset_ticks", json_object_new_int64(off));
            }
        }
        json_object_array_add(arr, f);
    }
    json_object_object_add(r, "flows", arr);
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
                          struct pw_config  **cfg_pp,
                          struct pw_program **prog_pp,
                          struct card_runtime cards[],
                          struct pw_host_plane *hps[MAX_CARDS]) {
    const struct pw_config *cfg  = *cfg_pp;
    struct pw_program      *prog = *prog_pp;
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
        } else if (!strcmp(name, "flow.hist")) {
            struct json_object *jid;
            if (!json_object_object_get_ex(req, "id", &jid)) {
                resp = build_error("missing id");
            } else {
                resp = build_flow_hist(cfg, prog, cards,
                                       json_object_get_int(jid));
            }
        } else if (!strcmp(name, "flow.stats")) {
            struct json_object *jc;
            int filter = -1;
            if (json_object_object_get_ex(req, "id", &jc))
                filter = json_object_get_int(jc);
            resp = build_flow_stats(cfg, prog, cards, filter);
        } else if (!strcmp(name, "test.start") || !strcmp(name, "test.stop") ||
                   !strcmp(name, "test.arm")) {
            bool en = (strcmp(name, "test.start") == 0);
            int  changed = 0, failed = 0;
            /* test.arm pushes the compiled program again (idempotent
             * resync), then soft-clears the RX checker counters on each
             * card so a measurement run starts from zero (the data plane
             * has no auto-reset; only this CSR write or rst_n). test.start
             * / test.stop walk every flow and flip the enable bit. */
            if (!strcmp(name, "test.arm")) {
                if (program_backends(prog, cfg, cards) != PW_OK) failed++;
                for (size_t ci = 0; ci < cfg->n_cards; ci++) {
                    if (cards[ci].open && cards[ci].backend.ops->write32) {
                        pw_status s = cards[ci].backend.ops->write32(
                            cards[ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
                        if (s == PW_OK) changed++;
                        else            failed++;
                    }
                }
            } else {
                for (size_t k = 0; k < prog->n_flow_meta; k++) {
                    pw_status s = set_flow_enable(prog, cards,
                                                  prog->flow_meta[k].global_flow_id,
                                                  en);
                    if (s == PW_OK) changed++;
                    else            failed++;
                }
            }
            resp = json_object_new_object();
            json_object_object_add(resp, "action", json_object_new_string(name));
            json_object_object_add(resp, "changed", json_object_new_int(changed));
            json_object_object_add(resp, "failed",  json_object_new_int(failed));
        } else if (!strcmp(name, "stats.clear")) {
            /* Soft-clear all RX checker + per-port counters + histogram on
             * every card (same CSR as test.arm's clear) without re-pushing the
             * program -- a standalone re-baseline independent of arm/start/stop. */
            int changed = 0, failed = 0;
            for (size_t ci = 0; ci < cfg->n_cards; ci++) {
                if (cards[ci].open && cards[ci].backend.ops->write32) {
                    pw_status s = cards[ci].backend.ops->write32(
                        cards[ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
                    if (s == PW_OK) changed++; else failed++;
                }
            }
            resp = json_object_new_object();
            json_object_object_add(resp, "action", json_object_new_string("stats.clear"));
            json_object_object_add(resp, "changed", json_object_new_int(changed));
            json_object_object_add(resp, "failed",  json_object_new_int(failed));
        } else if (!strcmp(name, "config.load")) {
            resp = do_config_load(cfg_pp, prog_pp, cards, req);
            /* refresh local snapshots after a successful swap */
            cfg  = *cfg_pp;
            prog = *prog_pp;
        } else if (!strcmp(name, "flow.start") || !strcmp(name, "flow.stop")) {
            struct json_object *jid;
            if (!json_object_object_get_ex(req, "id", &jid)) {
                resp = build_error("missing id");
            } else {
                bool en = (strcmp(name, "flow.start") == 0);
                uint32_t id = (uint32_t)json_object_get_int64(jid);
                pw_status s = set_flow_enable(prog, cards, id, en);
                resp = json_object_new_object();
                json_object_object_add(resp, "id",     json_object_new_int64(id));
                json_object_object_add(resp, "enable", json_object_new_boolean(en));
                json_object_object_add(resp, "status", json_object_new_string(pw_strerror(s)));
            }
        } else if (!strcmp(name, "flash.id")) {
            int ci = -1;
            for (size_t i = 0; i < cfg->n_cards; i++) if (cards[i].open) { ci = (int)i; break; }
            if (ci < 0) resp = build_error("no open card");
            else {
                uint8_t id[3] = {0};
                pw_status s = pw_flash_read_id(cards[ci].backend.ops, cards[ci].backend.ctx, id);
                char idbuf[16]; snprintf(idbuf, sizeof idbuf, "%02x %02x %02x", id[0], id[1], id[2]);
                resp = json_object_new_object();
                json_object_object_add(resp, "jedec_id", json_object_new_string(idbuf));
                json_object_object_add(resp, "status",   json_object_new_string(pw_strerror(s)));
            }
        } else if (!strcmp(name, "flash.write")) {
            /* Live config-flash write: read the file (same host, root) and
             * program+verify it over the SPI engine while the data plane
             * keeps running. {path, offset?} -> {bytes, mismatch, verified}. */
            struct json_object *jp, *jo;
            int ci = -1;
            for (size_t i = 0; i < cfg->n_cards; i++) if (cards[i].open) { ci = (int)i; break; }
            if (!json_object_object_get_ex(req, "path", &jp)) {
                resp = build_error("missing path");
            } else if (ci < 0) {
                resp = build_error("no open card");
            } else {
                const char *path = json_object_get_string(jp);
                uint32_t off = 0x00E00000u;
                if (json_object_object_get_ex(req, "offset", &jo))
                    off = (uint32_t)json_object_get_int64(jo);
                FILE *f = fopen(path, "rb");
                if (!f) { resp = build_error("open file failed"); }
                else {
                    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
                    /* 16 MB cap (matches pw_flash): the boot image is ~12 MB now;
                     * the old 8 MB guard predates the full data-plane bitstream and
                     * rejected it. 16 MB = the 3-byte-addressable range of the flash. */
                    if (sz <= 0 || sz > (16 << 20)) { fclose(f); resp = build_error("bad file size"); }
                    /* 3-byte addressing wraps at 16 MB: a write whose END exceeds it
                     * clobbers the boot image at offset 0. The ~12 MB image only fits
                     * at offset 0; reject offset+len > 16 MB (default offset is the
                     * 14 MB dev-scratch region, only for small writes). */
                    else if ((uint64_t)off + (uint64_t)sz > 0x01000000u) {
                        fclose(f); resp = build_error("offset+size exceeds 16 MB (would wrap onto boot image); use offset 0 for a full image");
                    }
                    else {
                        uint8_t *img = malloc((size_t)sz);
                        size_t rd = fread(img, 1, (size_t)sz, f); fclose(f);
                        if (rd != (size_t)sz) { free(img); resp = build_error("file read failed"); }
                        else {
                            uint64_t mism = 0;
                            pw_status s = pw_flash_program(cards[ci].backend.ops,
                                                           cards[ci].backend.ctx,
                                                           off, img, (size_t)sz, &mism);
                            free(img);
                            resp = json_object_new_object();
                            json_object_object_add(resp, "bytes",    json_object_new_int64(sz));
                            json_object_object_add(resp, "offset",   json_object_new_int64(off));
                            json_object_object_add(resp, "mismatch", json_object_new_int64((int64_t)mism));
                            json_object_object_add(resp, "verified",
                                json_object_new_boolean(s == PW_OK && mism == 0));
                            json_object_object_add(resp, "status",   json_object_new_string(pw_strerror(s)));
                        }
                    }
                }
            }
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
    bool allow_fake     = false;
    int  stats_interval = 5000;
    int  prom_port      = 0;

    int opt;
    while ((opt = getopt(argc, argv, "c:nvs:p:Fh")) != -1) {
        switch (opt) {
        case 'c': cfg_path = optarg; break;
        case 'n': dry_run = true; break;
        case 'v': verbose = true; break;
        case 's': stats_interval = atoi(optarg); break;
        case 'p': prom_port = atoi(optarg); break;
        case 'F': allow_fake = true; break;
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

    open_all_backends(cfg, cards, allow_fake);
    if (program_backends(prog, cfg, cards) != PW_OK)
        fprintf(stderr, "warning: initial FPGA programming hard-failed -- "
                "device may not match config (check the card / BAR)\n");
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

    /* Spin up one worker per card that has a host_plane. The main
     * thread keeps the control socket and Prometheus listener.
     * Each worker owns the TAP fds of its card's bindings. */
    struct card_worker_ctx workers[MAX_CARDS] = {0};
    for (size_t i = 0; i < cfg->n_cards; i++) {
        if (!hps[i]) continue;
        workers[i].hp = hps[i];
        workers[i].n_fds = 0;
        for (size_t k = 0; k < hps[i]->n_bindings; k++) {
            if (workers[i].n_fds < PW_HOST_PLANE_MAX_BINDINGS) {
                workers[i].fds[workers[i].n_fds++] = hps[i]->bindings[k].fd;
            }
        }
        atomic_init(&workers[i].stop, false);
        if (pthread_create(&workers[i].tid, NULL,
                           card_worker_main, &workers[i]) == 0) {
            workers[i].running = true;
            if (verbose)
                printf("  card%u worker started (%d tap fds)\n",
                       (unsigned)cfg->cards[i].id, workers[i].n_fds);
        } else {
            fprintf(stderr, "card%u: pthread_create failed\n",
                    (unsigned)cfg->cards[i].id);
        }
    }

    uint64_t last_stats = now_ms();
    uint64_t last_servo = now_ms();
    while (!g_stop) {
        struct pollfd pfds[2];
        size_t np = 0;
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
                handle_client(cfd, &cfg, &prog, cards, hps);
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

        if (stats_interval > 0 &&
            (int)(now_ms() - last_stats) >= stats_interval) {
            print_stats(cfg, cards, hps);
            last_stats = now_ms();
        }

        /* Cross-card latency servo (~10x/s): track the inter-card offset into
         * the HW lat_correction CSR. cfg/prog are owned by this thread (the
         * config.load swap in handle_client runs here too), so no locking. */
        if ((int)(now_ms() - last_servo) >= 100) {
            servo_lat_correction(cfg, prog, cards);
            last_servo = now_ms();
        }
    }

    fprintf(stderr, "shutting down ...\n");
    for (size_t i = 0; i < MAX_CARDS; i++) {
        if (workers[i].running) {
            atomic_store_explicit(&workers[i].stop, true, memory_order_relaxed);
        }
    }
    for (size_t i = 0; i < MAX_CARDS; i++) {
        if (workers[i].running) {
            pthread_join(workers[i].tid, NULL);
        }
    }
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
