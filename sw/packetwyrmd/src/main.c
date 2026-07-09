/* packetwyrmd: load + compile the config, open backends, program the cards,
 * create TAPs, and serve control RPCs until SIGINT/SIGTERM. Runs one host-plane
 * worker thread per card (punt RX -> TAP, TAP -> slow-path inject), a JSON-RPC
 * control socket (config.load with rollback, flow/test control, stats/hist
 * reads), and an optional Prometheus exporter. Works against the real BAR
 * backend or, with -F, the no-op fake backend. */

#include <errno.h>
#include <getopt.h>
#include <math.h>
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
#include <fcntl.h>
#include <grp.h>
#include <libgen.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <json-c/json.h>

#include "packetwyrm/packetwyrm.h"
#include "packetwyrm/spi_flash.h"
#include "packetwyrm/gpio_sync.h"
#include "packetwyrm/sfp.h"
#include "packetwyrm/frame_preview.h"

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
        /* Short poll cap: the punt (C2H) direction has no fd to wake poll, so
         * host_plane_step must run frequently to reap punted frames promptly.
         * With a 100 ms cap, a punt reply sat up to 100 ms per hop when no TAP
         * was readable -> ARP/hello round-trips timed out and cascaded to loss.
         * 1 ms keeps punt latency low (MMIO completed-count reads are ~us) and
         * still observes the stop flag promptly. */
        (void)poll(w->n_fds ? pfds : NULL, w->n_fds, 1);
        pw_host_plane_step(w->hp, 16);
    }
    return NULL;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [-e ENV] [-t TEST] [-n] [-v] [-a] [-s INTERVAL_MS] [-S SERVO_MS] [-C CAL_TICKS] [-p PROMETHEUS_PORT] [-F]\n"
        "  -e ENV            environment config: system/cards/logical_interfaces/secret\n"
        "                    (default /etc/packetwyrm/packetwyrm.yaml; may also carry\n"
        "                    flows for a combined single-file setup). -c is an alias.\n"
        "  -t TEST           test config: flows/forwards, attached onto the env\n"
        "  -n                dry run: parse + validate + compile, exit\n"
        "  -v                verbose\n"
        "  -a, --autostart   begin generating traffic as soon as flows are programmed\n"
        "                    (legacy behavior). DEFAULT is now to program flows IDLE\n"
        "                    and wait for an explicit `pktwyrm test start`; a freshly\n"
        "                    loaded config emits nothing until then.\n"
        "  -s INTERVAL_MS    stats print interval (default 5000, 0 = off)\n"
        "  -S SERVO_MS       cross-card lat_correction servo period (default 10;\n"
        "                    smaller = less ~ppm-skew residual between updates --\n"
        "                    1.6 ppm x period; 10 ms ~= 16 ns, 1 ms ~= 1.6 ns. The\n"
        "                    J5 edge updates every ~210 us so below that is moot)\n"
        "  -C CAL_TICKS      cross-card one-way latency calibration (signed ticks,\n"
        "                    6.4 ns each; default 0). Added to the servo correction\n"
        "                    antisymmetrically by card-id order (tx<rx:+, tx>rx:-)\n"
        "                    to cancel the direction-asymmetric TX/RX capture bias\n"
        "                    so both directions read the true one-way latency. Set\n"
        "                    to ~half the measured inter-direction gap (2-card rig)\n"
        "  -p [ADDR:]PORT    bind a Prometheus /metrics exporter; ADDR defaults\n"
        "                    to 127.0.0.1 (loopback). Use 0.0.0.0:PORT to expose\n"
        "                    it on all interfaces (unauthenticated -- opt in\n"
        "                    deliberately). 0/unset leaves it disabled\n"
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

/* Open a backend for every configured card. Returns the number of cards that
 * could NOT be opened (0 = all good). With allow_fake a BAR-open failure falls
 * back to the no-op fake backend (so the count stays 0); without it a failure
 * leaves the card closed and is counted -- the caller turns a nonzero count
 * into a startup failure so a real deployment never comes up "alive but no
 * FPGA programmed". */
static int open_all_backends(const struct pw_config *cfg,
                             struct card_runtime cards[], bool allow_fake) {
    int n_failed = 0;
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
            n_failed++;
            fprintf(stderr, "could not open backend for %s (%s): %s%s\n",
                    cfg->cards[i].pci, cfg->cards[i].name, pw_strerror(br),
                    allow_fake ? "" : " (pass --allow-fake to use the no-op backend)");
        }
    }
    return n_failed;
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

/* Create + bind a TAP for every logical_if. Returns the number of TAPs bound,
 * or -1 if a configured logical_if could not be set up (unresolved port, TAP
 * open/MAC/MTU/up ioctl, or host-plane bind failure) AND allow_fake is false --
 * a missing/down TAP blackholes the control plane, so production (no -F) treats
 * it as fatal; -F (dev/CI, often non-root without CAP_NET_ADMIN) tolerates it
 * and just skips that binding. */
static int setup_taps(const struct pw_config *cfg,
                      struct card_runtime cards[],
                      struct pw_host_plane *hps[MAX_CARDS],
                      struct tap_handle    *taps, int max_taps,
                      bool verbose, bool allow_fake) {
    int n_taps = 0;
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        const struct pw_logical_if *lif = &cfg->logical_if[i];
        /* taps[] is a fixed max_taps-element array; per-card bind limits don't
         * bound the GLOBAL count (N cards * per-card limit can exceed it), so
         * guard here to avoid overrunning the array. */
        if (n_taps >= max_taps) {
            fprintf(stderr, "logical_if %s: TAP table full (max %d); "
                    "ignoring further logical_ifs\n", lif->name, max_taps);
            if (!allow_fake) goto fail;
            break;
        }
        uint8_t egress_lp = 0;
        struct pw_card_backend *b = backend_for_lif(cfg, cards, lif, &egress_lp);
        if (!b) {
            fprintf(stderr, "logical_if %s: no backend (port unresolved)\n", lif->name);
            if (!allow_fake) goto fail;
            continue;
        }
        int fd = -1;
        char actual[PW_TAP_IFNAME_MAX] = {0};
        pw_status r = pw_tap_open(lif->name, &fd, actual);
        if (r != PW_OK) {
            fprintf(stderr, "logical_if %s: pw_tap_open failed: %s\n",
                    lif->name, pw_strerror(r));
            if (!allow_fake) goto fail;
            continue;
        }
        /* MAC/MTU/up are part of "the TAP is usable"; a failure here is a
         * blackhole, so surface it (fatal in production). */
        pw_status mr = pw_tap_set_mac(actual, lif->mac);
        pw_status tr = lif->mtu ? pw_tap_set_mtu(actual, lif->mtu) : PW_OK;
        pw_status ur = pw_tap_set_up(actual, true);
        if ((mr != PW_OK || tr != PW_OK || ur != PW_OK) && !allow_fake) {
            fprintf(stderr, "logical_if %s: TAP config failed "
                    "(mac=%s mtu=%s up=%s)\n", lif->name,
                    pw_strerror(mr), pw_strerror(tr), pw_strerror(ur));
            pw_tap_close(fd);
            goto fail;
        }

        /* Find the host_plane belonging to this lif's card. */
        size_t card_index = SIZE_MAX;
        for (size_t k = 0; k < cfg->n_cards; k++)
            if (&cards[k].backend == b) { card_index = k; break; }
        if (card_index >= MAX_CARDS) { pw_tap_close(fd); continue; }

        if (!hps[card_index]) {
            hps[card_index] = calloc(1, sizeof(*hps[card_index]));
            if (!hps[card_index] ||
                pw_host_plane_init(hps[card_index], b) != PW_OK) {
                fprintf(stderr, "logical_if %s: host-plane init failed "
                        "(out of memory?)\n", lif->name);
                free(hps[card_index]); hps[card_index] = NULL;
                pw_tap_close(fd);
                if (!allow_fake) goto fail;
                continue;
            }
        }
        pw_status br = pw_host_plane_bind(hps[card_index], lif->id, fd, egress_lp);
        if (br != PW_OK) {
            fprintf(stderr, "logical_if %s: bind failed: %s\n",
                    lif->name, pw_strerror(br));
            pw_tap_close(fd);
            if (!allow_fake) goto fail;
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
fail:
    /* Production fatal path: rewind everything opened so far so the caller can
     * exit cleanly (the fds/host-planes are otherwise only reclaimed by process
     * exit). taps[] own the TAP fds; the host-planes only reference them (bind
     * does not dup), so close the fds once and free the host-plane structs. */
    for (int t = 0; t < n_taps; t++) pw_tap_close(taps[t].fd);
    for (size_t k = 0; k < cfg->n_cards && k < MAX_CARDS; k++) {
        if (hps[k]) { free(hps[k]); hps[k] = NULL; }
    }
    return -1;
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
        if (!any_cross)                pw_gpio_sync_disable(&cards[ci].backend);
        else if ((int)ci == master_ci) pw_gpio_sync_master(&cards[ci].backend, 1, 15);
        else                          pw_gpio_sync_slave(&cards[ci].backend, 0);
    }
    /* Per-flow corrections (including zeroing same-card slots) are written by
     * prime_lat_correction / the servo, not here. */
}

/* Map a config card id -> cards[] index, or -1. */
static int card_idx_by_id(const struct pw_config *cfg, uint16_t card_id) {
    for (size_t ci = 0; ci < cfg->n_cards; ci++)
        if (cfg->cards[ci].id == card_id) return (int)ci;
    return -1;
}

/* Cross-card one-way latency calibration (Phase 2). The GPIO sync offset is
 * measured in the dp_clk (core) domain, but the TX frame stamp (MAC-TX domain,
 * pw_ts_insert) and RX wire-stamp (MAC-RX domain) capture points carry a small
 * DIRECTION-ASYMMETRIC bias the offset can't see, so the two directions of a
 * card pair read ~2*bias apart (e.g. 63 vs 19 ticks; true ~= midpoint). This is
 * a signed per-rig constant (ticks, 1 tick = 6.4 ns) set with -C: it is ADDED to
 * the servo/prime correction, antisymmetrically by card-id order (tx<rx: +cal,
 * tx>rx: -cal), so both directions converge to the true one-way latency. 0
 * disables (default). NOTE: the antisymmetric-by-id model is exact for a 2-card
 * pair; a >2-card rig with per-card capture skews would need a per-card table. */
static int g_xcard_lat_cal_ticks = 0;

/* Explicit-start gate. DEFAULT false: flows are programmed into the FPGA IDLE
 * (generators disabled) and stay silent until an explicit `test.start`, so
 * starting the daemon or loading a config never puts traffic on the wire by
 * surprise. -a/--autostart restores the legacy "generate as soon as programmed"
 * behavior. The run-state lives in the staged flow rows (which test.start/stop
 * and flow.start/stop already toggle); we just change their INITIAL value. */
static bool g_gen_autostart = false;

static int64_t xcard_cal_bias(const struct pw_flow_meta *m) {
    if (g_xcard_lat_cal_ticks == 0 || m->tx_card_id == m->rx_card_id) return 0;
    return (m->tx_card_id < m->rx_card_id) ? (int64_t)g_xcard_lat_cal_ticks
                                           : -(int64_t)g_xcard_lat_cal_ticks;
}

/* Cross-card latency servo (PER FLOW). For each cross-card flow, write the
 * current inter-card offset (tx_cnt - rx_cnt) to that flow's slot
 * (rx_local_flow_id) in the RX card's correction table, so the checker
 * accumulates the TRUE one-way latency per sample (the ~ppm skew is re-tracked
 * each -S period, keeping min/max/avg/histogram un-smeared). Same-card slots are
 * 0 and set once in prime (not touched here). Per-flow means one RX card can mix
 * same-card and cross-card flows, and take cross-card from multiple TX cards --
 * each slot gets its own offset. Run every -S ms from the main loop. */
static void servo_lat_correction(const struct pw_config *cfg,
                                 const struct pw_program *prog,
                                 struct card_runtime cards[]) {
    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        if (!m->rx_slot_valid) continue;                /* background (TX-only): no RX slot to correct */
        if (m->tx_card_id == m->rx_card_id) continue;   /* same-card slot: stays 0 */
        int rx_ci = card_idx_by_id(cfg, m->rx_card_id);
        int tx_ci = card_idx_by_id(cfg, m->tx_card_id);
        if (rx_ci < 0 || tx_ci < 0 || !cards[rx_ci].open || !cards[tx_ci].open) continue;
        int64_t corr;
        /* Only write an EDGE-COHERENT offset; on an incoherent read skip this
         * tick (keep the current correction) rather than briefly corrupt it. */
        if (pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &corr))
            pw_gpio_sync_write_correction(&cards[rx_ci].backend, m->rx_local_flow_id,
                                          corr + xcard_cal_bias(m));
    }
}

/* True when every cross-card flow already has a coherent J5 GPIO offset, i.e.
 * the servo has converged enough to correct cross-card latency. Returns true
 * trivially when there are no cross-card flows (nothing to converge). Used to
 * warn an operator who arms/starts a cross-card measurement before J5 sync has
 * produced a valid edge -- those first samples would carry the raw wrong-
 * timebase latency. */
static bool servo_converged(const struct pw_config *cfg,
                            const struct pw_program *prog,
                            struct card_runtime cards[]) {
    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        if (!m->rx_slot_valid || m->tx_card_id == m->rx_card_id) continue;
        int rx_ci = card_idx_by_id(cfg, m->rx_card_id);
        int tx_ci = card_idx_by_id(cfg, m->tx_card_id);
        if (rx_ci < 0 || tx_ci < 0 || !cards[rx_ci].open || !cards[tx_ci].open) continue;
        int64_t corr;
        if (!pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &corr))
            return false;
    }
    return true;
}

/* The servo runs in its OWN thread so no slow control RPC (notably sfp.info's
 * ~0.3 s/module I2C bit-bang, which the GUI polls at ~1 Hz) can starve it on the
 * single-threaded main loop -- starvation let the ~1.6 ppm inter-card skew drift
 * the correction stale (~140 ticks over a ~0.5 s stall) and smeared cross-card
 * latency to min=0 / huge tails. g_servo_lock serialises the servo's use of
 * cfg/prog against config.load's swap+free of them (see do_config_load). */
static pthread_mutex_t g_servo_lock = PTHREAD_MUTEX_INITIALIZER;

struct servo_args {
    struct pw_config  **cfgp;   /* main's cfg/prog, swapped by config.load */
    struct pw_program **progp;
    struct card_runtime *cards;
    int interval_ms;
};

static void *servo_thread_fn(void *arg) {
    struct servo_args *a = arg;
    while (!g_stop) {
        pthread_mutex_lock(&g_servo_lock);
        servo_lat_correction(*a->cfgp, *a->progp, a->cards);
        pthread_mutex_unlock(&g_servo_lock);
        usleep((useconds_t)a->interval_ms * 1000);
    }
    return NULL;
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
    /* Per RX card: did it have a cross-card flow, and did every such flow get a
     * confirmed coherent correction? Only stats.clear a card once all its
     * cross-card slots are primed (so it doesn't start "clean" on a stale/0
     * correction); same-card-only cards need no clear (their slots are 0). */
    bool has_cross[MAX_CARDS] = {false};
    bool cross_ok[MAX_CARDS];
    for (size_t i = 0; i < MAX_CARDS; i++) cross_ok[i] = true;

    for (size_t i = 0; i < prog->n_flow_meta; i++) {
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        if (!m->rx_slot_valid) continue;    /* background (TX-only): no RX slot to prime */
        int rx_ci = card_idx_by_id(cfg, m->rx_card_id);
        if (rx_ci < 0 || !cards[rx_ci].open) continue;
        unsigned slot = m->rx_local_flow_id;

        if (m->tx_card_id == m->rx_card_id) {
            pw_gpio_sync_write_correction(&cards[rx_ci].backend, slot, 0);  /* same-card */
            continue;
        }
        int tx_ci = card_idx_by_id(cfg, m->tx_card_id);
        if (tx_ci < 0 || !cards[tx_ci].open) continue;
        has_cross[rx_ci] = true;

        /* Retry for the J5 sync to come up (period ~210us; 200x1ms = 200ms) and a
         * coherent offset to be readable; write this flow's slot. */
        bool wrote = false;
        for (int tries = 0; tries < 200 && !wrote; tries++) {
            int64_t corr;
            if (pw_gpio_sync_offset_coherent(&cards[tx_ci].backend, &cards[rx_ci].backend, &corr)) {
                pw_gpio_sync_write_correction(&cards[rx_ci].backend, slot,
                                              corr + xcard_cal_bias(m));
                wrote = true;
                break;
            }
            usleep(1000);
        }
        if (!wrote) cross_ok[rx_ci] = false;
    }

    /* Discard the polluted startup samples on each fully-primed cross-card RX. */
    for (size_t ci = 0; ci < cfg->n_cards && ci < MAX_CARDS; ci++) {
        if (!cards[ci].open || !has_cross[ci]) continue;
        if (cross_ok[ci]) {
            if (cards[ci].backend.ops->write32)
                (void)cards[ci].backend.ops->write32(
                    cards[ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
        } else {
            fprintf(stderr, "warning: card%u: a cross-card flow's latency "
                    "correction is not ready (no coherent J5 offset); stats left "
                    "as-is, the servo will converge -- stats.clear once it's up\n",
                    (unsigned)cfg->cards[ci].id);
        }
    }
}

/* diag (may be NULL) is filled with the concrete detail of the FIRST card that
 * fails to program -- e.g. the capacity rejection's "N requested but device
 * supports M" -- so config.load can surface numbers, not a bare status. */
static pw_status program_backends_diag(const struct pw_program *prog,
                                       const struct pw_config *cfg,
                                       struct card_runtime cards[],
                                       struct pw_diag *diag) {
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
        pw_status s = pw_program_card_tables_diag(b->ops, b->ctx, cp,
                                                  worst == PW_OK ? diag : NULL);
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

/* Back-compat wrapper for the call sites that don't surface a diag. */
static pw_status program_backends(const struct pw_program *prog,
                                  const struct pw_config *cfg,
                                  struct card_runtime cards[]) {
    return program_backends_diag(prog, cfg, cards, NULL);
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

/* Stage the generator run-state of every flow's TX row in `prog` IN MEMORY
 * (no FPGA write): the next program_backends() commits it. Called right after
 * a compile (startup + config.load) so the freshly compiled rows -- which the
 * compiler marks enable=1 -- are forced idle before they ever reach the card,
 * unless autostart. From then on test.start/stop and flow.start/stop own the
 * run-state via set_flow_enable (they mutate these same staged rows), so a
 * test.arm re-push honors the current state instead of silently re-enabling. */
static void stage_flow_run_state(struct pw_program *prog, bool running) {
    for (size_t k = 0; k < prog->n_flow_meta; k++) {
        int ci = -1; uint32_t row = 0;
        if (find_tx_row(prog, prog->flow_meta[k].global_flow_id, &ci, &row) < 0)
            continue;
        struct pwfpga_flow_config *fc = &prog->per_card[ci].flow_rows[row];
        fc->enable    = running ? 1 : 0;
        fc->tx_enable = running ? 1 : 0;
    }
}

/* Re-write the TX flow row of `global_flow_id` with `enable` set accordingly,
 * then commit. When `persist` is true the daemon's authoritative staged row is
 * updated to match (flow.start/stop/test.*); when false the write goes to the
 * FPGA only and the staged row is left untouched -- used by the config.load
 * quiesce so a rollback re-programs the EXACT prior enable state (mutating the
 * staged row there would make "rolled back, previous config still running"
 * restore all-flows-disabled). */
static pw_status set_flow_enable(struct pw_program *prog,
                                 struct card_runtime cards[],
                                 uint32_t global_flow_id,
                                 bool enable, bool persist) {
    int      ci  = -1;
    uint32_t row = 0;
    if (find_tx_row(prog, global_flow_id, &ci, &row) < 0) return PW_E_INVAL;
    if (!cards[ci].open) return PW_E_NO_CARD;
    struct pwfpga_flow_config *fc = &prog->per_card[ci].flow_rows[row];
    /* Write a COPY to the backend first; only update the staged row (which
     * flows/flow.stats report as `enabled`) after the write+commit succeed, so
     * the reported state can't diverge from the FPGA on a failed write. */
    struct pwfpga_flow_config tmp = *fc;
    tmp.enable    = enable ? 1 : 0;
    tmp.tx_enable = enable ? 1 : 0;
    const struct pw_card_backend *b = &cards[ci].backend;
    pw_status s = b->ops->flow_write
        ? b->ops->flow_write(b->ctx, row, &tmp)
        : PW_E_NOT_IMPLEMENTED;
    if (s == PW_OK && b->ops->flow_commit)
        s = b->ops->flow_commit(b->ctx);
    if (s == PW_OK && persist) *fc = tmp;
    return s;
}

/* Current TX-enable state of a flow (the daemon's authoritative view, from the
 * staged flow row that flow.start/stop/test.* toggle). */
static bool flow_enabled(const struct pw_program *prog, uint32_t global_flow_id) {
    int ci = -1; uint32_t row = 0;
    if (find_tx_row(prog, global_flow_id, &ci, &row) < 0) return false;
    return prog->per_card[ci].flow_rows[row].tx_enable != 0;
}

/* ---- end backend programming ---------------------------------------- */

static struct json_object *build_error(const char *msg);

/* The environment config path (`-e`), captured in main(). The
 * config.get_raw / config.save RPCs read and write this file. Writes
 * target ONLY this path -- never an arbitrary client-supplied path. */
static const char *g_env_path = "/etc/packetwyrm/packetwyrm.yaml";

/* The active test-config YAML text (flows/forwards), stashed so the GUI can
 * load and edit the currently-running flows (config.get_test). Updated from
 * the `-t` file at startup and from each successful config.load. The daemon
 * doesn't otherwise keep the source text (it parses into pw_config). */
static char *g_test_yaml = NULL;
static void set_test_yaml(const char *s) {
    free(g_test_yaml);
    g_test_yaml = s ? strdup(s) : NULL;
}

/* The exact env-file text the daemon LOADED at startup. config.save compares
 * against this (not the current on-disk file, which may have been edited
 * externally since) to decide restart_required -- the running daemon only
 * reflects what it parsed at startup. */
static char *g_env_loaded_yaml = NULL;

/* Read an entire file into a malloc'd NUL-terminated string (NULL on error). */
static char *read_file_str(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char *buf = NULL; size_t cap = 0, len = 0; int ch;
    while ((ch = fgetc(f)) != EOF) {
        if (len + 2 > cap) {
            cap = cap ? cap * 2 : 4096;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); fclose(f); return NULL; }
            buf = nb;
        }
        buf[len++] = (char)ch;
    }
    fclose(f);
    if (!buf) { buf = malloc(1); if (!buf) return NULL; }
    buf[len] = '\0';
    return buf;
}

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
    /* Compare the fields that actually define the TAP/backend binding, not just
     * ids -- otherwise a combined config.load that keeps the ids but changes a
     * PCI BDF, a port's global_port, or a lif's name/vlan/global_port/mac would
     * be treated as "same topology": the env part silently discarded, only the
     * flows applied on the OLD topology, and the operator sees a false success. */
    for (size_t i = 0; i < a->n_cards; i++) {
        const struct pw_card *ca = &a->cards[i], *cb = &b->cards[i];
        if (ca->id != cb->id) return false;
        if (strcmp(ca->pci, cb->pci) != 0) return false;
        if (ca->n_ports != cb->n_ports) return false;
        for (size_t k = 0; k < ca->n_ports; k++) {
            if (ca->ports[k].local_port  != cb->ports[k].local_port)  return false;
            if (ca->ports[k].global_port != cb->ports[k].global_port) return false;
        }
    }
    for (size_t i = 0; i < a->n_logical_if; i++) {
        const struct pw_logical_if *la = &a->logical_if[i], *lb = &b->logical_if[i];
        if (la->id != lb->id) return false;
        if (la->global_port != lb->global_port) return false;
        if (la->vlan != lb->vlan) return false;
        if (strcmp(la->name, lb->name) != 0) return false;
        if (memcmp(la->mac, lb->mac, sizeof(la->mac)) != 0) return false;
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

    struct pw_config  *new_cfg  = NULL;
    struct pw_program *new_prog = pw_program_new();
    struct pw_diag     diag = {0};
    struct json_object *resp = NULL;
    if (!new_prog) { resp = build_error("out of memory"); goto fail; }

    /* Parse the payload as a TEST config (system/cards optional). config.load
     * ONLY swaps flows/forwards -- the environment (cards / logical_ifs /
     * secret) is immutable at runtime (topology changes need a restart). So we
     * always merge onto a clone of the RUNNING environment and take just the
     * payload's flows/forwards. A combined body that also carries cards is
     * accepted for back-compat, but its cards must MATCH the running topology
     * (checked below) -- they are otherwise ignored, never swapped in (which
     * would zero system.secret and the rest of the environment). */
    struct pw_config *payload = pw_config_new();
    if (!payload) { resp = build_error("out of memory"); goto fail; }
    pw_status r = pw_config_parse_string_ex(yaml, yaml_len, PW_CFG_TEST_ONLY, payload, &diag);
    if (r != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "parse: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        pw_config_free(payload);
        goto fail;
    }
    /* A combined body's cards/lifs must match the running environment. */
    if (payload->n_cards > 0 && !same_topology(*cfg_pp, payload)) {
        resp = build_error("topology change (cards / logical_ifs) requires restart");
        pw_config_free(payload);
        goto fail;
    }
    new_cfg = pw_config_clone_env(*cfg_pp);
    if (!new_cfg) { resp = build_error("out of memory"); pw_config_free(payload); goto fail; }
    new_cfg->flows = payload->flows; new_cfg->n_flows = payload->n_flows;
    payload->flows = NULL; payload->n_flows = 0;
    new_cfg->forwards = payload->forwards; new_cfg->n_forwards = payload->n_forwards;
    payload->forwards = NULL; payload->n_forwards = 0;
    pw_config_free(payload);

    if ((r = pw_config_validate(new_cfg, &diag)) != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "validate: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }
    if ((r = pw_flow_compile(new_cfg, new_prog, &diag)) != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "compile: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }

    /* Explicit-start: a runtime config.load never puts traffic on the wire on
     * its own -- the newly compiled flows are staged idle and wait for an
     * explicit test.start (regardless of the daemon's -a startup default; a
     * manual reload is exactly the moment a surprise burst would be worst). */
    stage_flow_run_state(new_prog, false);

    /* From here we mutate the cards and swap cfg/prog. Hold off the servo thread
     * (which reads the cfg/prog pointers and would use-after-free across the
     * swap) for this whole section. config.load is rare/manual, so the
     * sub-second pause is fine; prime_lat_correction re-establishes the
     * correction anyway. */
    pthread_mutex_lock(&g_servo_lock);

    /* Stop running flows on the live program so we don't briefly
     * dual-program two distinct flow sets. Best-effort: failures here
     * don't block the swap; the new program's commit will override
     * any stale row anyway. */
    for (size_t k = 0; k < (*prog_pp)->n_flow_meta; k++) {
        (void)set_flow_enable(*prog_pp, cards,
                              (*prog_pp)->flow_meta[k].global_flow_id,
                              false, /*persist=*/false);
    }

    /* Stage: program the new config into every open backend. On a hard fault
     * (card drop / BAR error) ROLL BACK -- re-program the previous config so the
     * FPGA matches the daemon's unchanged view, keep the old config running, and
     * reject the load. A half-applied config (daemon view != FPGA) is the worst
     * failure mode for a tester; see docs/design/daemon.md. */
    struct pw_diag prog_diag = {0};
    pw_status prog_st = program_backends_diag(new_prog, new_cfg, cards, &prog_diag);
    if (prog_st != PW_OK) {
        /* Prefer the concrete detail (e.g. capacity numbers) over the bare
         * status string when the programming layer filled one in. */
        const char *detail = prog_diag.message[0] ? prog_diag.message : pw_strerror(prog_st);
        fprintf(stderr, "load: stage failed (%s) -- rolling back to the previous "
                "config\n", detail);
        pw_status rb_st = program_backends(*prog_pp, *cfg_pp, cards);  /* restore */
        pthread_mutex_unlock(&g_servo_lock);   /* cfg/prog unchanged; servo may resume */
        pw_program_free(new_prog);
        pw_config_free(new_cfg);
        char msg[320];
        if (rb_st == PW_OK) {
            snprintf(msg, sizeof msg,
                     "stage failed (%s); rolled back, previous config still running",
                     detail);
        } else {
            /* Both the new config AND the restore failed: the FPGA no longer
             * matches the daemon's (unchanged) view. Report it honestly -- a
             * "still running" message here would be a lie -- so the operator
             * re-syncs (test.arm) or restarts instead of trusting stale state. */
            fprintf(stderr, "load: ROLLBACK ALSO FAILED (%s) -- device may be out "
                    "of sync with the daemon view\n", pw_strerror(rb_st));
            snprintf(msg, sizeof msg,
                     "stage failed (%s) AND rollback failed (%s); device may be OUT "
                     "OF SYNC -- re-arm (test.arm) or restart the daemon",
                     pw_strerror(prog_st), pw_strerror(rb_st));
        }
        return build_error(msg);
    }

    /* Success: swap the daemon's view to the new (now-programmed) config. */
    pw_program_free(*prog_pp);
    pw_config_free(*cfg_pp);
    *cfg_pp  = new_cfg;
    *prog_pp = new_prog;
    pthread_mutex_unlock(&g_servo_lock);   /* new cfg/prog live; servo may resume */

    /* Stash the loaded test YAML so the GUI can read back / edit it. */
    set_test_yaml(yaml);

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

/* The redaction sentinel config.get_raw substitutes for the secret value, and
 * that config.save recognizes as "keep the existing secret" (see do_config_save
 * -- prevents a Save of the redacted view from overwriting the real secret). */
#define PW_SECRET_REDACTED "***"

/* If `line` is a `secret:` key line (leading ws, "secret", optional ws, ':')
 * return the indentation width, else -1. Structural, YAML-block form only
 * (inline `system: { secret: ... }` is not matched -- documented). */
static int secret_line_indent(const char *line) {
    const char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (strncmp(p, "secret", 6) != 0) return -1;
    const char *q = p + 6;
    while (*q == ' ' || *q == '\t') q++;
    return (*q == ':') ? (int)(p - line) : -1;
}

/* config.get_raw: return the raw text of the environment config file so a GUI
 * can edit it, with the `secret:` value structurally redacted to the sentinel.
 * We redact ONLY the secret key line (not a blanket value replacement) so a
 * secret that happens to equal a card/interface name isn't clobbered, and so
 * config.save can round-trip it safely. `secret_set` is authoritative from the
 * loaded config. */
static struct json_object *build_config_get_raw(const struct pw_config *cfg) {
    FILE *f = fopen(g_env_path, "r");
    struct json_object *resp = json_object_new_object();
    json_object_object_add(resp, "path", json_object_new_string(g_env_path));
    if (!f) {
        json_object_object_add(resp, "yaml", json_object_new_string(""));
        json_object_object_add(resp, "secret_set", json_object_new_boolean(false));
        json_object_object_add(resp, "error",
                               json_object_new_string("cannot open env config"));
        return resp;
    }
    char line[1024];
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (buf) buf[0] = '\0';
    while (buf && fgets(line, sizeof(line), f)) {
        int indent = secret_line_indent(line);
        if (indent >= 0) {
            snprintf(line, sizeof(line), "%.*s" "secret: \"" PW_SECRET_REDACTED "\"\n",
                     indent < 32 ? indent : 32,
                     "                                ");
        }
        size_t ll = strlen(line);
        if (len + ll + 1 > cap) {
            cap = (len + ll + 1) * 2;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); buf = NULL; break; }
            buf = nb;
        }
        memcpy(buf + len, line, ll + 1);
        len += ll;
    }
    fclose(f);

    json_object_object_add(resp, "yaml", json_object_new_string(buf ? buf : ""));
    json_object_object_add(resp, "secret_set",
                           json_object_new_boolean(cfg && cfg->system.secret[0] != '\0'));
    free(buf);
    return resp;
}

/* config.save: validate a full environment YAML and, if it parses, write it
 * atomically to g_env_path (tmp + rename). Reports restart_required=true when
 * the new topology (cards / logical_ifs) differs from the running one, since
 * config.load cannot swap topology live. Writes ONLY g_env_path. */
/* Return a malloc'd copy of `yaml` with the value of any `secret:` key line
 * replaced by `sec` (YAML double-quoted, backslash/quote-escaped). Used to
 * restore the real secret when the GUI saves the redacted placeholder back so
 * a thoughtless Save can't overwrite system.secret with "***". Caller frees. */
static char *yaml_rewrite_secret(const char *yaml, const char *sec) {
    /* escape the secret for a double-quoted YAML scalar */
    char esc[PW_SECRET_MAX * 2 + 1]; size_t e = 0;
    for (const char *s = sec; *s && e + 2 < sizeof(esc); s++) {
        if (*s == '\\' || *s == '"') esc[e++] = '\\';
        esc[e++] = *s;
    }
    esc[e] = '\0';

    size_t cap = strlen(yaml) + sizeof(esc) + 64, len = 0;
    char *out = malloc(cap);
    if (!out) return NULL;
    out[0] = '\0';
    for (const char *p = yaml; *p; ) {
        const char *nl = strchr(p, '\n');
        size_t linelen = nl ? (size_t)(nl - p) + 1 : strlen(p);
        char rep[1400]; const char *emit = p; size_t emitlen = linelen;
        if (linelen < 1024) {
            char lb[1024]; memcpy(lb, p, linelen); lb[linelen] = '\0';
            int indent = secret_line_indent(lb);
            if (indent >= 0) {
                int n = snprintf(rep, sizeof(rep), "%.*s" "secret: \"%s\"%s",
                    indent < 64 ? indent : 64,
                    "                                                                ",
                    esc, nl ? "\n" : "");
                if (n > 0) { emit = rep; emitlen = (size_t)n; }
            }
        }
        if (len + emitlen + 1 > cap) {
            cap = (len + emitlen + 1) * 2;
            char *nb = realloc(out, cap);
            if (!nb) { free(out); return NULL; }
            out = nb;
        }
        memcpy(out + len, emit, emitlen); len += emitlen; out[len] = '\0';
        p += linelen;
    }
    return out;
}

static struct json_object *do_config_save(struct pw_config **cfg_pp,
                                          struct json_object *req) {
    struct json_object *jy;
    if (!json_object_object_get_ex(req, "yaml", &jy) ||
        json_object_get_type(jy) != json_type_string)
        return build_error("missing yaml");
    const char *yaml = json_object_get_string(jy);
    size_t yaml_len  = strlen(yaml);

    struct pw_config *newc = pw_config_new();
    if (!newc) return build_error("out of memory");
    struct pw_diag diag = {0};
    pw_status r = pw_config_parse_string_ex(yaml, yaml_len, 0, newc, &diag);
    if (r != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "parse: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        pw_config_free(newc);
        return build_error(msg);
    }
    if ((r = pw_config_validate(newc, &diag)) != PW_OK) {
        char msg[600];
        snprintf(msg, sizeof(msg), "validate: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        pw_config_free(newc);
        return build_error(msg);
    }
    bool topology_change = !same_topology(*cfg_pp, newc);

    /* Secret preservation: if the submitted config's secret is the redaction
     * sentinel (the GUI round-tripped config.get_raw's "***"), rewrite it back
     * to the running secret so a Save of the redacted view can't lock the
     * operator out. Reject if the placeholder can't be resolved (e.g. inline
     * mapping the line-scan doesn't reach). */
    char *rewritten = NULL;
    const char *out_yaml = yaml;
    size_t out_len = yaml_len;
    if (strcmp(newc->system.secret, PW_SECRET_REDACTED) == 0) {
        rewritten = yaml_rewrite_secret(yaml, (*cfg_pp)->system.secret);
        bool ok = rewritten != NULL;
        if (ok) {
            struct pw_config *chk = pw_config_new();
            struct pw_diag d2 = {0};
            ok = chk &&
                 pw_config_parse_string_ex(rewritten, strlen(rewritten), 0, chk, &d2) == PW_OK &&
                 strcmp(chk->system.secret, PW_SECRET_REDACTED) != 0;
            if (chk) pw_config_free(chk);
        }
        if (!ok) {
            free(rewritten);
            pw_config_free(newc);
            return build_error("refusing to save the redacted secret placeholder "
                "\"" PW_SECRET_REDACTED "\"; set a real secret or restore it first");
        }
        out_yaml = rewritten;
        out_len  = strlen(rewritten);
    }
    pw_config_free(newc);

    /* config.save writes the file but does NOT live-apply it (unlike
     * config.load's test merge): the running daemon keeps its loaded env until
     * restart. So a restart is needed to apply ANY change -- secret, system,
     * logical_ifs, cards -- not just topology. Compare against the text the
     * daemon LOADED at startup (g_env_loaded_yaml), NOT the current on-disk
     * file (which may have been edited externally since) -- otherwise saving an
     * external edit could wrongly report no restart while the running daemon is
     * unaware of it. A save identical to the loaded text needs no restart. */
    bool restart_required = !g_env_loaded_yaml ||
        strlen(g_env_loaded_yaml) != out_len ||
        memcmp(g_env_loaded_yaml, out_yaml, out_len) != 0;

    /* Atomic write: <path>.tmp then rename. The env file holds system.secret,
     * so its permissions matter: create the tmp file with the EXISTING file's
     * mode + owner (default 0600 for a brand-new file) rather than relying on
     * fopen()+umask, which would leave a world-readable 0644 secret. */
    mode_t mode = 0600;
    uid_t uid = (uid_t)-1; gid_t gid = (gid_t)-1;
    struct stat st;
    if (stat(g_env_path, &st) == 0) {
        mode = st.st_mode & 07777;
        uid = st.st_uid; gid = st.st_gid;
    }
    /* Create a UNIQUELY-named temp file in the same directory via mkstemp
     * (O_CREAT|O_EXCL, mode 0600, does not follow symlinks) then rename over the
     * target. A fixed "<path>.tmp" opened O_CREAT|O_TRUNC would follow a
     * pre-planted symlink and let a local user with write access to the config
     * directory trick the root daemon into truncating/writing an arbitrary
     * file. */
    char dirbuf[1024];
    if ((size_t)snprintf(dirbuf, sizeof(dirbuf), "%s", g_env_path) >= sizeof(dirbuf)) {
        free(rewritten); return build_error("env path too long");
    }
    char tmp[1088];
    if ((size_t)snprintf(tmp, sizeof(tmp), "%s/.packetwyrmd-save.XXXXXX",
                         dirname(dirbuf)) >= sizeof(tmp)) {
        free(rewritten); return build_error("env path too long");
    }
    int fd = mkstemp(tmp);
    if (fd < 0) { free(rewritten); return build_error("cannot create temp env config"); }
    /* Enforce mode + owner explicitly (open() mode is masked by umask; a
     * preserved non-root owner needs an explicit fchown by the root daemon).
     * The mode is the security-critical part (this file holds system.secret), so
     * a failure to apply it ABORTS the save rather than leaving a wrong-mode
     * file; fchown (owner preservation) stays best-effort. */
    if (fchmod(fd, mode) != 0) {
        close(fd); unlink(tmp); free(rewritten);
        return build_error("cannot set env config mode");
    }
    if (uid != (uid_t)-1 && fchown(fd, uid, gid) != 0) {
        /* best-effort owner preservation; mode (fchmod) is the security-
         * critical part and already applied */
    }
    bool wok = true;
    for (size_t off = 0; off < out_len; ) {
        ssize_t w = write(fd, out_yaml + off, out_len - off);
        if (w <= 0) { wok = false; break; }
        off += (size_t)w;
    }
    if (fsync(fd) != 0) wok = false;
    close(fd);
    free(rewritten);
    if (!wok || rename(tmp, g_env_path) != 0) {
        unlink(tmp);
        return build_error("write failed");
    }
    /* fsync the PARENT directory so the rename (the new directory entry) is
     * durable across a crash/power loss. The file contents were fsync'd above,
     * but the dir entry pointing at them can still be lost otherwise -- and this
     * file holds system.secret + the environment config. */
    {
        char dbuf[1024];
        snprintf(dbuf, sizeof(dbuf), "%s", g_env_path);
        int dfd = open(dirname(dbuf), O_DIRECTORY | O_RDONLY | O_CLOEXEC);
        if (dfd >= 0) { (void)fsync(dfd); close(dfd); }
    }

    struct json_object *resp = json_object_new_object();
    json_object_object_add(resp, "ok", json_object_new_boolean(true));
    json_object_object_add(resp, "path", json_object_new_string(g_env_path));
    /* restart_required: the saved change won't take effect until packetwyrmd
     * restarts (config.save is a file write, not a live reload).
     * topology_change: additionally, cards/logical_ifs differ (a full restart,
     * never a live swap, per config.load's constraint). */
    json_object_object_add(resp, "restart_required",
                           json_object_new_boolean(restart_required));
    json_object_object_add(resp, "topology_change",
                           json_object_new_boolean(topology_change));
    return resp;
}

/* ---- flow/forward -> GUI-form-model JSON (for config.get_test) ---------- */
/* These emit the running config in the exact shape the Web GUI's flow/forward
 * form model uses, so "Load current" can populate the form (not just the raw
 * YAML). Addresses: IPv4 is stored host-order (htonl before inet_ntop); IPv6
 * and masks are MSB-first byte arrays. */
static struct json_object *js_mac(const uint8_t m[6]) {
    char b[18];
    snprintf(b, sizeof b, "%02x:%02x:%02x:%02x:%02x:%02x",
             m[0], m[1], m[2], m[3], m[4], m[5]);
    return json_object_new_string(b);
}
static struct json_object *js_v4(uint32_t host) {
    struct in_addr a; a.s_addr = htonl(host);
    char b[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &a, b, sizeof b);
    return json_object_new_string(b);
}
static struct json_object *js_v6(const uint8_t a[16]) {
    char b[INET6_ADDRSTRLEN]; inet_ntop(AF_INET6, a, b, sizeof b);
    return json_object_new_string(b);
}
static int v6_prefix_len(const uint8_t m[16]) {
    int n = 0;
    for (int i = 0; i < 16; i++) {
        if (m[i] == 0xff) { n += 8; continue; }
        uint8_t b = m[i]; while (b & 0x80) { n++; b <<= 1; } break;
    }
    return n;
}
static bool v6_any(const uint8_t m[16]) {
    for (int i = 0; i < 16; i++) if (m[i]) return true;
    return false;
}
static const char *modestr(uint8_t m) {
    return m == 1 ? "increment" : m == 2 ? "random" : "static";
}
/* One modifier entry { mode, mask } for a hex-mask field (MAC/IPv4/port/vlan). */
static void add_mod_u64(struct json_object *o, const char *k, uint8_t mode, uint64_t mask) {
    struct json_object *m = json_object_new_object();
    json_object_object_add(m, "mode", json_object_new_string(modestr(mode)));
    if (mode && mask) {
        char b[24]; snprintf(b, sizeof b, "0x%llx", (unsigned long long)mask);
        json_object_object_add(m, "mask", json_object_new_string(b));
    } else json_object_object_add(m, "mask", json_object_new_string(""));
    json_object_object_add(o, k, m);
}
/* One modifier entry for an IPv6-address field (mask is a v6 literal). `active`
 * is true only for the flow's own family (mode is shared with the v4 slot). */
static void add_mod_v6(struct json_object *o, const char *k, uint8_t mode,
                       const uint8_t mask16[16], bool active) {
    struct json_object *m = json_object_new_object();
    json_object_object_add(m, "mode",
                           json_object_new_string(active ? modestr(mode) : "static"));
    if (active && mode && v6_any(mask16)) json_object_object_add(m, "mask", js_v6(mask16));
    else json_object_object_add(m, "mask", json_object_new_string(""));
    json_object_object_add(o, k, m);
}

static struct json_object *flow_to_form_json(const struct pw_flow *f) {
    struct json_object *o = json_object_new_object();
    json_object_object_add(o, "id", json_object_new_int((int)f->id));
    json_object_object_add(o, "name", json_object_new_string(f->name));
    json_object_object_add(o, "tx", json_object_new_int(f->tx_global_port));
    json_object_object_add(o, "rx", json_object_new_int(f->rx_global_port));
    json_object_object_add(o, "src_mac", js_mac(f->l2.src_mac));
    json_object_object_add(o, "dst_mac", js_mac(f->l2.dst_mac));
    if (f->l2.vlan_set) json_object_object_add(o, "vlan", json_object_new_int(f->l2.vlan));
    else json_object_object_add(o, "vlan", json_object_new_string(""));
    if (f->l2.ethertype) { char eb[8]; snprintf(eb, sizeof eb, "0x%04x", f->l2.ethertype);
                           json_object_object_add(o, "ethertype", json_object_new_string(eb)); }
    else json_object_object_add(o, "ethertype", json_object_new_string(""));
    bool v6 = f->ipv6.present;
    json_object_object_add(o, "l3", json_object_new_string(v6 ? "ipv6" : "ipv4"));
    if (v6) {
        json_object_object_add(o, "ip_src", js_v6(f->ipv6.src));
        json_object_object_add(o, "ip_dst", js_v6(f->ipv6.dst));
        json_object_object_add(o, "ttl", json_object_new_int(f->ipv6.hop_limit));
    } else {
        json_object_object_add(o, "ip_src", js_v4(f->ipv4.src));
        json_object_object_add(o, "ip_dst", js_v4(f->ipv4.dst));
        json_object_object_add(o, "ttl", json_object_new_int(f->ipv4.ttl));
    }
    bool tcp = f->udp.l4_proto == 6;
    json_object_object_add(o, "l4", json_object_new_string(tcp ? "tcp" : "udp"));
    json_object_object_add(o, "sport", json_object_new_int(f->udp.src_port));
    json_object_object_add(o, "dport", json_object_new_int(f->udp.dst_port));
    if (tcp) { char tb[8]; snprintf(tb, sizeof tb, "0x%02x", f->udp.tcp_flags);
               json_object_object_add(o, "tcp_flags", json_object_new_string(tb)); }
    else json_object_object_add(o, "tcp_flags", json_object_new_string(""));
    /* traffic (form has fixed frame_len + rate_bps; range/pps flows are
     * approximated here and are authoritative in the raw YAML). */
    json_object_object_add(o, "frame_len", json_object_new_int(
        f->traffic.frame_len_fixed_set ? f->traffic.frame_len_fixed
                                       : f->traffic.frame_len_min));
    /* rate: preserve the flow's rate mode so Load current -> Apply round-trips
     * (emitting rate_bps for a rate_pps flow would produce invalid YAML). */
    if (f->traffic.rate_pps) {
        json_object_object_add(o, "rate_mode", json_object_new_string("pps"));
        json_object_object_add(o, "rate", json_object_new_int64((int64_t)f->traffic.rate_pps));
    } else {
        json_object_object_add(o, "rate_mode", json_object_new_string("bps"));
        json_object_object_add(o, "rate", json_object_new_int64((int64_t)f->traffic.rate_bps));
    }
    const char *pm = f->traffic.payload_mode == 0 ? "zero" :
                     f->traffic.payload_mode == 2 ? "prbs" :
                     f->traffic.payload_mode == 3 ? "random" : "increment";
    json_object_object_add(o, "payload", json_object_new_string(pm));
    const char *ft = f->traffic.frame_template == PW_FRAME_TEMPLATE_L4RAW ? "raw" :
                     f->traffic.frame_template == PW_FRAME_TEMPLATE_L3RAW ? "ip" :
                     f->traffic.frame_template == PW_FRAME_TEMPLATE_L2RAW ? "eth" : "test";
    json_object_object_add(o, "frame_template", json_object_new_string(ft));
    json_object_object_add(o, "seq", json_object_new_boolean(f->traffic.insert_sequence));
    json_object_object_add(o, "ts", json_object_new_boolean(f->traffic.insert_timestamp));
    json_object_object_add(o, "m_loss", json_object_new_boolean(f->meas.loss));
    json_object_object_add(o, "m_lat", json_object_new_boolean(f->meas.latency));
    json_object_object_add(o, "m_jit", json_object_new_boolean(f->meas.jitter));
    json_object_object_add(o, "classify",
                           json_object_new_string(f->classify_header ? "header" : "map"));
    json_object_object_add(o, "background", json_object_new_boolean(f->background));
    /* match (only narrowed fields; blank = exact/wildcard default) */
    struct json_object *mt = json_object_new_object();
    char hb[16];
    if (f->match_udp_dst_mask != 0xFFFF) {
        snprintf(hb, sizeof hb, "0x%x", f->match_udp_dst_mask);
        json_object_object_add(mt, "udp_dst", json_object_new_string(hb));
    } else json_object_object_add(mt, "udp_dst", json_object_new_string(""));
    if (f->match_ipv4_dst_mask != 0xFFFFFFFFu) {
        snprintf(hb, sizeof hb, "0x%x", f->match_ipv4_dst_mask);
        json_object_object_add(mt, "ipv4_dst", json_object_new_string(hb));
    } else json_object_object_add(mt, "ipv4_dst", json_object_new_string(""));
    if (f->match_ipv6_dst_set)
        json_object_object_add(mt, "ipv6_dst_prefix",
                               json_object_new_int(v6_prefix_len(f->match_ipv6_dst_mask)));
    else json_object_object_add(mt, "ipv6_dst_prefix", json_object_new_string(""));
    if (f->match_ipv6_src_set)
        json_object_object_add(mt, "ipv6_src_prefix",
                               json_object_new_int(v6_prefix_len(f->match_ipv6_src_mask)));
    else json_object_object_add(mt, "ipv6_src_prefix", json_object_new_string(""));
    json_object_object_add(o, "match", mt);
    /* modifiers (mode for the ipv6 address slot is shared with the ipv4 slot) */
    struct json_object *md = json_object_new_object();
    add_mod_u64(md, "src_ipv4", v6 ? 0 : f->mod.src_ipv4.mode, v6 ? 0 : f->mod.src_ipv4.mask);
    add_mod_u64(md, "dst_ipv4", v6 ? 0 : f->mod.dst_ipv4.mode, v6 ? 0 : f->mod.dst_ipv4.mask);
    add_mod_v6(md, "src_ipv6", f->mod.src_ipv4.mode, f->mod.src_ipv6_mask, v6);
    add_mod_v6(md, "dst_ipv6", f->mod.dst_ipv4.mode, f->mod.dst_ipv6_mask, v6);
    add_mod_u64(md, "udp_src", f->mod.udp_src.mode, f->mod.udp_src.mask);
    add_mod_u64(md, "udp_dst", f->mod.udp_dst.mode, f->mod.udp_dst.mask);
    add_mod_u64(md, "src_mac", f->mod.src_mac.mode, f->mod.src_mac.mask);
    add_mod_u64(md, "dst_mac", f->mod.dst_mac.mode, f->mod.dst_mac.mask);
    add_mod_u64(md, "vlan", f->mod.vlan.mode, f->mod.vlan.mask);
    json_object_object_add(o, "mods", md);   /* GUI form-model key (not "modifiers") */
    /* encap */
    struct json_object *en = json_object_new_object();
    const char *et = f->encap.type == 1 ? "ipip" : f->encap.type == 2 ? "gre" :
                     f->encap.type == 3 ? "etherip" : "none";
    json_object_object_add(en, "type", json_object_new_string(f->encap.present ? et : "none"));
    bool ev6 = f->encap.outer_ipv6.present;
    json_object_object_add(en, "l3", json_object_new_string(ev6 ? "ipv6" : "ipv4"));
    if (f->encap.present && ev6) {
        json_object_object_add(en, "src", js_v6(f->encap.outer_ipv6.src));
        json_object_object_add(en, "dst", js_v6(f->encap.outer_ipv6.dst));
        json_object_object_add(en, "ttl", json_object_new_int(f->encap.outer_ipv6.hop_limit));
        json_object_object_add(en, "dscp", json_object_new_int(f->encap.outer_ipv6.dscp));
    } else if (f->encap.present) {
        json_object_object_add(en, "src", js_v4(f->encap.outer_ipv4.src));
        json_object_object_add(en, "dst", js_v4(f->encap.outer_ipv4.dst));
        json_object_object_add(en, "ttl", json_object_new_int(f->encap.outer_ipv4.ttl));
        json_object_object_add(en, "dscp", json_object_new_int(f->encap.outer_ipv4.dscp));
    } else {
        json_object_object_add(en, "src", json_object_new_string(""));
        json_object_object_add(en, "dst", json_object_new_string(""));
        json_object_object_add(en, "ttl", json_object_new_string(""));
        json_object_object_add(en, "dscp", json_object_new_string(""));
    }
    if (f->encap.present && f->encap.inner_mac_set) {
        json_object_object_add(en, "inner_src_mac", js_mac(f->encap.inner_src_mac));
        json_object_object_add(en, "inner_dst_mac", js_mac(f->encap.inner_dst_mac));
    } else {
        json_object_object_add(en, "inner_src_mac", json_object_new_string(""));
        json_object_object_add(en, "inner_dst_mac", json_object_new_string(""));
    }
    json_object_object_add(o, "encap", en);
    json_object_object_add(o, "rx_expect",
                           json_object_new_string(f->rx_expect == 1 ? "tunneled" : "inner"));
    return o;
}

static struct json_object *fwd_to_form_json(const struct pw_forward_rule *r) {
    struct json_object *o = json_object_new_object();
    json_object_object_add(o, "name", json_object_new_string(r->name));
    json_object_object_add(o, "ingress", json_object_new_int(r->ingress_port));
    json_object_object_add(o, "egress", json_object_new_int(r->egress_port));
    json_object_object_add(o, "priority", json_object_new_int(r->priority));
    #define OPT16(k, v) json_object_object_add(o, k, \
        (v) ? json_object_new_int((int)(v)) : json_object_new_string(""))
    OPT16("ethertype", r->ethertype);
    OPT16("ip_proto", r->ip_proto);
    OPT16("udp_dst", r->udp_dst);
    OPT16("vlan", r->vlan);
    #undef OPT16
    for (int which = 0; which < 2; which++) {
        bool set = which ? r->ipv6_src_set : r->ipv6_dst_set;
        const uint8_t *a = which ? r->ipv6_src : r->ipv6_dst;
        const uint8_t *m = which ? r->ipv6_src_mask : r->ipv6_dst_mask;
        const char *key = which ? "ipv6_src" : "ipv6_dst";
        if (set) {
            char ab[INET6_ADDRSTRLEN], b[80];
            inet_ntop(AF_INET6, a, ab, sizeof ab);
            snprintf(b, sizeof b, "%s/%d", ab, v6_prefix_len(m));
            json_object_object_add(o, key, json_object_new_string(b));
        } else json_object_object_add(o, key, json_object_new_string(""));
    }
    return o;
}

/* config.get_test: return the active test-config YAML (flows/forwards) text AND
 * the running flows/forwards as structured JSON in the GUI form-model shape, so
 * "Load current" can populate both the form and the raw YAML editor. `yaml` is
 * empty / `loaded` false when no test config was loaded via -t or config.load
 * (flows may still appear in `flows` if they came from a combined `-e` file). */
static struct json_object *build_config_get_test(const struct pw_config *cfg) {
    struct json_object *resp = json_object_new_object();
    json_object_object_add(resp, "yaml",
                           json_object_new_string(g_test_yaml ? g_test_yaml : ""));
    json_object_object_add(resp, "loaded",
                           json_object_new_boolean(g_test_yaml != NULL));
    struct json_object *fa = json_object_new_array();
    for (size_t i = 0; i < cfg->n_flows; i++)
        json_object_array_add(fa, flow_to_form_json(&cfg->flows[i]));
    json_object_object_add(resp, "flows", fa);
    struct json_object *wa = json_object_new_array();
    for (size_t i = 0; i < cfg->n_forwards; i++)
        json_object_array_add(wa, fwd_to_form_json(&cfg->forwards[i]));
    json_object_object_add(resp, "forwards", wa);
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
        /* FPGA identity/version from the card (for the dashboard versions panel). */
        struct pw_card_info info;
        if (cards[i].open && cards[i].backend.ops->card_info &&
            cards[i].backend.ops->card_info(cards[i].backend.ctx, &info) == PW_OK) {
            char hx[16];
            snprintf(hx, sizeof hx, "0x%08x", info.device_id);
            json_object_object_add(c, "device_id", json_object_new_string(hx));
            json_object_object_add(c, "fpga_version", json_object_new_int((int)info.version));
            snprintf(hx, sizeof hx, "0x%08x", info.build_id);
            json_object_object_add(c, "build_id", json_object_new_string(hx));
            snprintf(hx, sizeof hx, "0x%08x", info.git_hash);
            json_object_object_add(c, "git_hash", json_object_new_string(hx));
        }
        /* Live health + on-chip SYSMON telemetry (via generic read32). On an
         * older bitstream GLOBAL_STATUS is a constant and the SYSMON regs read
         * 0, so err_sticky/activity come out false and temp/volt are omitted. */
        if (cards[i].open && cards[i].backend.ops->read32) {
            void *bx = cards[i].backend.ctx;
            uint32_t gs = 0, tc = 0, sup = 0;
            if (cards[i].backend.ops->read32(bx, PWFPGA_REG_GLOBAL_STATUS, &gs) == PW_OK) {
                json_object_object_add(c, "err_sticky",
                    json_object_new_boolean((gs & PWFPGA_GSTAT_ERROR) != 0));
                json_object_object_add(c, "activity",
                    json_object_new_boolean((gs & PWFPGA_GSTAT_ACTIVITY) != 0));
            }
            if (cards[i].backend.ops->read32(bx, PWFPGA_REG_SYSMON_TEMP, &tc) == PW_OK &&
                PWFPGA_SYSMON_CODE(tc) != 0) {   /* code 0 => no SYSMON on this image */
                json_object_object_add(c, "temp_c",
                    json_object_new_double(PWFPGA_SYSMON_TEMP_C(tc)));
                if (cards[i].backend.ops->read32(bx, PWFPGA_REG_SYSMON_SUPPLY, &sup) == PW_OK) {
                    /* pw_sysmon reads temp/vccint/vccaux in sequence, so just
                     * after boot a supply code may still be 0 (not yet sampled);
                     * only report each rail once its code is non-zero. */
                    if (PWFPGA_SYSMON_CODE(sup & 0xFFFF))
                        json_object_object_add(c, "vccint_v",
                            json_object_new_double(PWFPGA_SYSMON_SUPPLY_V(sup & 0xFFFF)));
                    if (PWFPGA_SYSMON_CODE(sup >> 16))
                        json_object_object_add(c, "vccaux_v",
                            json_object_new_double(PWFPGA_SYSMON_SUPPLY_V(sup >> 16)));
                }
            }
        }
        json_object_array_add(arr, c);
    }
    json_object_object_add(r, "cards", arr);
    return r;
}

/* ---- SFP cache + background refresh -----------------------------------------
 * pw_sfp_probe() does I2C bit-bang (~0.3 s per module) -- doing it in the
 * sfp.info RPC path would BLOCK the single-threaded main loop (and thus starve
 * the cross-card lat_correction servo -> stale correction -> skew drift ->
 * cross-card latency min=0 / huge tails: the exact bug the GUI's ~1 Hz sfp.info
 * poll triggered). So a background thread does the slow I2C into a cache and the
 * RPC returns the cache instantly. SFP DOM changes on a seconds timescale, so a
 * few-second refresh is plenty. Indexed by cards[] index (topology is immutable
 * at runtime -> stable), so it never touches the swappable cfg pointer. */
struct sfp_cache_entry { bool valid; bool probe_ok; struct pw_sfp_info info; };
static struct sfp_cache_entry g_sfp_cache[MAX_CARDS][2];
static pthread_mutex_t g_sfp_lock = PTHREAD_MUTEX_INITIALIZER;

/* One probe pass over all open ports into the cache (slow I2C; off the main loop). */
static void sfp_refresh_once(struct card_runtime cards[], size_t n_cards) {
    for (size_t i = 0; i < n_cards && i < MAX_CARDS; i++) {
        if (!cards[i].open) continue;
        for (int p = 0; p < 2; p++) {
            struct pw_sfp_info s;
            pw_status st = pw_sfp_probe(&cards[i].backend, p, &s);   /* SLOW I2C bit-bang */
            pthread_mutex_lock(&g_sfp_lock);
            g_sfp_cache[i][p].valid = true;
            g_sfp_cache[i][p].probe_ok = (st == PW_OK);
            if (st == PW_OK) g_sfp_cache[i][p].info = s;
            pthread_mutex_unlock(&g_sfp_lock);
        }
    }
}

struct sfp_refresh_args { struct card_runtime *cards; size_t n_cards; };
static void *sfp_refresh_thread_fn(void *arg) {
    struct sfp_refresh_args *a = arg;
    while (!g_stop) {
        sfp_refresh_once(a->cards, a->n_cards);
        for (int k = 0; k < 50 && !g_stop; k++) usleep(100 * 1000);  /* ~5 s, shutdown-responsive */
    }
    return NULL;
}

/* Per-SFP module identifier + DOM, served from the background-refreshed cache
 * (never does live I2C on the RPC path). card_filter/port_filter = -1 = "all". */
static struct json_object *build_sfp_info(const struct pw_config *cfg,
                                          struct card_runtime cards[],
                                          int card_filter, int port_filter) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_cards && i < MAX_CARDS; i++) {
        if (card_filter >= 0 && cfg->cards[i].id != card_filter) continue;
        if (!cards[i].open) continue;
        for (int p = 0; p < 2; p++) {
            if (port_filter >= 0 && p != port_filter) continue;
            struct pw_sfp_info s;
            bool valid, ok;
            pthread_mutex_lock(&g_sfp_lock);
            valid = g_sfp_cache[i][p].valid;
            ok    = g_sfp_cache[i][p].probe_ok;
            if (ok) s = g_sfp_cache[i][p].info;
            pthread_mutex_unlock(&g_sfp_lock);

            struct json_object *o = json_object_new_object();
            json_object_object_add(o, "card_id", json_object_new_int(cfg->cards[i].id));
            json_object_object_add(o, "port", json_object_new_int(p));
            if (!valid) {
                json_object_object_add(o, "present", json_object_new_boolean(false));
                json_object_object_add(o, "pending", json_object_new_boolean(true));
                json_object_array_add(arr, o);
                continue;
            }
            if (!ok) {
                json_object_object_add(o, "present", json_object_new_boolean(false));
                json_object_object_add(o, "error", json_object_new_string("i2c error"));
                json_object_array_add(arr, o);
                continue;
            }
            json_object_object_add(o, "present", json_object_new_boolean(s.present));
            if (s.present) {
                json_object_object_add(o, "identifier", json_object_new_int(s.identifier));
                json_object_object_add(o, "connector",  json_object_new_int(s.connector));
                json_object_object_add(o, "vendor",     json_object_new_string(s.vendor));
                json_object_object_add(o, "part",       json_object_new_string(s.part));
                json_object_object_add(o, "revision",   json_object_new_string(s.revision));
                json_object_object_add(o, "serial",     json_object_new_string(s.serial));
                json_object_object_add(o, "date_code",  json_object_new_string(s.date_code));
                json_object_object_add(o, "br_nominal_mbaud",
                                       json_object_new_int(s.br_nominal * 100));
                json_object_object_add(o, "dom_supported", json_object_new_boolean(s.dom_supported));
                json_object_object_add(o, "dom_external_cal", json_object_new_boolean(s.dom_external_cal));
                json_object_object_add(o, "dom_valid",   json_object_new_boolean(s.dom_valid));
                if (s.dom_valid) {
                    json_object_object_add(o, "temp_c",      json_object_new_double(s.temp_c));
                    json_object_object_add(o, "vcc_v",       json_object_new_double(s.vcc_v));
                    json_object_object_add(o, "tx_bias_ma",  json_object_new_double(s.tx_bias_ma));
                    json_object_object_add(o, "tx_power_mw", json_object_new_double(s.tx_power_mw));
                    json_object_object_add(o, "rx_power_mw", json_object_new_double(s.rx_power_mw));
                }
            }
            json_object_array_add(arr, o);
        }
    }
    json_object_object_add(r, "sfp", arr);
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
        /* Latency is available for BOTH same-card (counter-direct) and cross-card
         * (HW lat_correction + J5 sync) flows, so latency_valid is true for
         * either; latency_method tells them apart (matches flow.stats).
         * EXCEPT background (load) flows: TX-only, no RX checker slot, so no
         * latency at all -- report latency_valid:false + method "none" so this
         * RPC agrees with flow.stats/flow.hist (which also refuse RX for them).
         * `background` is surfaced so a client can label the flow. */
        bool xcard = (m->tx_card_id != m->rx_card_id);
        json_object_object_add(fl, "background", json_object_new_boolean(!m->rx_slot_valid));
        json_object_object_add(fl, "latency_valid", json_object_new_boolean(m->rx_slot_valid));
        json_object_object_add(fl, "latency_method",
            json_object_new_string(!m->rx_slot_valid ? "none"
                                   : xcard ? "gpio-corrected" : "same-card"));
        json_object_object_add(fl, "enabled",
            json_object_new_boolean(flow_enabled(prog, (uint32_t)f->id)));
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

/* ports.stats: per-port wire counters (frames/bytes/FCS/link) from the MAC,
 * plus an FPGA timestamp so a client can derive exact per-port pps/bps. This
 * is authoritative per-port traffic (all frames, not just test flows) and
 * surfaces FCS errors -- one of the inputs to the front-panel LED err_sticky. */
static struct json_object *build_port_stats(const struct pw_config *cfg,
                                            struct card_runtime cards[]) {
    struct json_object *r = json_object_new_object();
    /* snapshot each open card first (same trigger as flow.stats) */
    for (size_t ci = 0; ci < cfg->n_cards; ci++)
        if (cards[ci].open && cards[ci].backend.ops->stats_snapshot)
            (void)cards[ci].backend.ops->stats_snapshot(cards[ci].backend.ctx);
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (!cards[ci].open || !cards[ci].backend.ops->read32) continue;
        uint32_t lo = 0, hi = 0;
        if (cards[ci].backend.ops->read32(cards[ci].backend.ctx,
                PWFPGA_REG_TIMESTAMP_LOW, &lo) == PW_OK &&
            cards[ci].backend.ops->read32(cards[ci].backend.ctx,
                PWFPGA_REG_TIMESTAMP_HIGH, &hi) == PW_OK) {
            json_object_object_add(r, "fpga_ts_lo", json_object_new_int64((int64_t)lo));
            json_object_object_add(r, "fpga_ts_hi", json_object_new_int64((int64_t)hi));
        }
        break;
    }
    struct json_object *arr = json_object_new_array();
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *cc = &cfg->cards[i];
        if (!cards[i].open || !cards[i].backend.ops->port_stats_read) continue;
        for (size_t p = 0; p < cc->n_ports; p++) {
            struct pw_port_stats ps = {0};
            if (cards[i].backend.ops->port_stats_read(
                    cards[i].backend.ctx, cc->ports[p].local_port, &ps) != PW_OK)
                continue;
            struct json_object *o = json_object_new_object();
            json_object_object_add(o, "card_id", json_object_new_int(cc->id));
            json_object_object_add(o, "local_port", json_object_new_int(cc->ports[p].local_port));
            json_object_object_add(o, "global_port", json_object_new_int(cc->ports[p].global_port));
            json_object_object_add(o, "rx_frames", json_object_new_int64((int64_t)ps.rx_frames));
            json_object_object_add(o, "rx_bytes",  json_object_new_int64((int64_t)ps.rx_bytes));
            json_object_object_add(o, "tx_frames", json_object_new_int64((int64_t)ps.tx_frames));
            json_object_object_add(o, "tx_bytes",  json_object_new_int64((int64_t)ps.tx_bytes));
            json_object_object_add(o, "rx_fcs_error", json_object_new_int64((int64_t)ps.rx_fcs_error));
            /* `drops` = REAL drops only (store-and-forward buffer overflow).
             * FCS + drops are the two per-port inputs to the LED err_sticky. A
             * classifier no-match is NOT a drop (see rx_unmatched below). */
            json_object_object_add(o, "drops", json_object_new_int64((int64_t)ps.rx_bad_frame));
            /* rx_unmatched: frames that arrived and were counted in rx_frames but
             * matched no classifier rule (informational, e.g. the host TAP's own
             * IPv6 ND/MLD looped back). Deliberately separate from `drops` and
             * does NOT light the LED. */
            json_object_object_add(o, "rx_unmatched", json_object_new_int64((int64_t)ps.rx_unmatched));
            /* Most-recent unmatched frame's context (decoded) so a rare miss can
             * be attributed: was it a real test frame (is_test + its flow_id) or a
             * stray/garbage frame? Raw ctx word + decoded fields + flow_id. */
            {
                uint32_t c = ps.last_unmatched_ctx;
                struct json_object *ld = json_object_new_object();
                json_object_object_add(ld, "ctx_raw", json_object_new_int64((int64_t)c));
                json_object_object_add(ld, "is_test",  json_object_new_boolean(c & 0x1));
                json_object_object_add(ld, "is_ipv4",  json_object_new_boolean((c>>1) & 0x1));
                json_object_object_add(ld, "is_ipv6",  json_object_new_boolean((c>>2) & 0x1));
                json_object_object_add(ld, "hit",      json_object_new_boolean((c>>3) & 0x1));
                json_object_object_add(ld, "action",   json_object_new_int((int)((c>>4) & 0x7)));
                json_object_object_add(ld, "is_arp",   json_object_new_boolean((c>>7) & 0x1));
                json_object_object_add(ld, "ethertype",json_object_new_int((int)((c>>8) & 0xFFFF)));
                json_object_object_add(ld, "l3_proto", json_object_new_int((int)((c>>24) & 0xFF)));
                json_object_object_add(ld, "flow_id",  json_object_new_int64((int64_t)ps.last_unmatched_flowid));
                json_object_object_add(o, "last_unmatched", ld);
            }
            json_object_object_add(o, "link_up_count", json_object_new_int64((int64_t)ps.link_up_count));
            json_object_object_add(o, "block_lock_loss", json_object_new_int64((int64_t)ps.block_lock_loss));
            json_object_array_add(arr, o);
        }
    }
    json_object_object_add(r, "ports", arr);
    return r;
}

/* tap.stats: per-logical-interface TAP status + statistics. Reports the kernel
 * netdev state (admin/oper up, IP addresses, netdev rx/tx/dropped counters) and
 * the PacketWyrm host-plane bridge counters (FPGA<->TAP frame movement). Lets an
 * operator see the punt/inject TAPs the daemon created and whether host traffic
 * (e.g. the TAP's own IPv6 ND/MLD) is flowing -- the traffic that shows up on the
 * loopback ports as rx_unmatched. SW-only (no FPGA access). */
static struct json_object *build_tap_stats(const struct pw_config *cfg,
                                           const struct tap_handle *taps,
                                           int n_taps,
                                           struct pw_host_plane *hps[MAX_CARDS]) {
    struct json_object *r = json_object_new_object();
    struct json_object *arr = json_object_new_array();
    for (int i = 0; i < n_taps; i++) {
        const struct tap_handle *th = &taps[i];
        struct json_object *o = json_object_new_object();
        json_object_object_add(o, "name", json_object_new_string(th->name));
        json_object_object_add(o, "logical_if_id", json_object_new_int64((int64_t)th->lif_id));

        const struct pw_logical_if *lif = pw_config_logical_if_by_id(cfg, th->lif_id);
        if (lif) {
            char mac[18];
            snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                     lif->mac[0], lif->mac[1], lif->mac[2],
                     lif->mac[3], lif->mac[4], lif->mac[5]);
            json_object_object_add(o, "mac", json_object_new_string(mac));
            json_object_object_add(o, "global_port", json_object_new_int(lif->global_port));
            json_object_object_add(o, "vlan", json_object_new_int(lif->vlan));
            json_object_object_add(o, "mtu",  json_object_new_int(lif->mtu));
        }

        /* Live kernel state: flags + IP addrs + netdev stats. */
        struct pw_tap_state st;
        if (pw_tap_query(th->name, &st) == PW_OK) {
            json_object_object_add(o, "admin_up", json_object_new_boolean(st.admin_up));
            json_object_object_add(o, "oper_up",  json_object_new_boolean(st.oper_up));
            struct json_object *ad = json_object_new_array();
            for (int a = 0; a < st.n_addrs; a++)
                json_object_array_add(ad, json_object_new_string(st.addrs[a]));
            json_object_object_add(o, "addrs", ad);
            struct json_object *k = json_object_new_object();
            json_object_object_add(k, "rx_packets", json_object_new_int64((int64_t)st.rx_packets));
            json_object_object_add(k, "rx_bytes",   json_object_new_int64((int64_t)st.rx_bytes));
            json_object_object_add(k, "rx_dropped", json_object_new_int64((int64_t)st.rx_dropped));
            json_object_object_add(k, "tx_packets", json_object_new_int64((int64_t)st.tx_packets));
            json_object_object_add(k, "tx_bytes",   json_object_new_int64((int64_t)st.tx_bytes));
            json_object_object_add(k, "tx_dropped", json_object_new_int64((int64_t)st.tx_dropped));
            json_object_object_add(o, "kernel", k);
        }

        /* PacketWyrm host-plane bridge counters for this lif. Search all cards'
         * host planes for the binding matching this logical_if_id. to_tap =
         * FPGA punt -> written to the TAP; from_tap = read from TAP -> injected. */
        for (size_t c = 0; c < cfg->n_cards; c++) {
            if (!hps[c]) continue;
            for (size_t j = 0; j < hps[c]->n_bindings; j++) {
                if (hps[c]->bindings[j].logical_if_id != th->lif_id) continue;
                struct json_object *b = json_object_new_object();
                json_object_object_add(b, "to_tap_ok",      json_object_new_int64((int64_t)hps[c]->punt_to_tap_ok[j]));
                json_object_object_add(b, "to_tap_dropped", json_object_new_int64((int64_t)hps[c]->punt_to_tap_dropped[j]));
                json_object_object_add(b, "from_tap_ok",      json_object_new_int64((int64_t)hps[c]->tap_to_fpga_ok[j]));
                json_object_object_add(b, "from_tap_dropped", json_object_new_int64((int64_t)hps[c]->tap_to_fpga_dropped[j]));
                json_object_object_add(o, "bridge", b);
            }
        }
        json_object_array_add(arr, o);
    }
    json_object_object_add(r, "taps", arr);
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
    if (!m->rx_slot_valid) {
        /* background (TX-only): no RX checker slot, so no latency histogram --
         * reading rx_local_flow_id would alias a real flow's slot. */
        json_object_object_add(r, "error",
            json_object_new_string("background (TX-only) flow: no RX latency histogram"));
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
    /* Optional op (same guard as build_port_stats/build_flow_stats): a
     * backend without stats_snapshot just serves the live counters. */
    if (cards[rx_ci].backend.ops->stats_snapshot) {
        pw_status ss = cards[rx_ci].backend.ops->stats_snapshot(cards[rx_ci].backend.ctx);
        if (ss != PW_OK) {
            json_object_object_add(r, "error", json_object_new_string(pw_strerror(ss)));
            return r;
        }
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

/* Human-readable "cardName.portName" label for a global_port (e.g. "card0.p0"),
 * so flow.stats can report the physical tx->rx path without the client having to
 * cross-reference the topology. Falls back to "gpN" if the port is unknown. */
static void port_label(const struct pw_config *cfg, uint16_t gp,
                       char *buf, size_t n) {
    for (size_t i = 0; i < cfg->n_cards; i++)
        for (size_t p = 0; p < cfg->cards[i].n_ports; p++)
            if (cfg->cards[i].ports[p].global_port == gp) {
                snprintf(buf, n, "%s.%s", cfg->cards[i].name,
                         cfg->cards[i].ports[p].name);
                return;
            }
    snprintf(buf, n, "gp%u", (unsigned)gp);
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
    /* FPGA free-running timestamp (6.4 ns/tick) at snapshot time, so a client
     * can compute exact frame/byte rates as Δcounter / Δticks -- independent of
     * host poll jitter. Read LOW first (latches HIGH) from the first open card. */
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (!cards[ci].open || !cards[ci].backend.ops->read32) continue;
        uint32_t lo = 0, hi = 0;
        if (cards[ci].backend.ops->read32(cards[ci].backend.ctx,
                PWFPGA_REG_TIMESTAMP_LOW, &lo) == PW_OK &&
            cards[ci].backend.ops->read32(cards[ci].backend.ctx,
                PWFPGA_REG_TIMESTAMP_HIGH, &hi) == PW_OK) {
            json_object_object_add(r, "fpga_ts_lo", json_object_new_int64((int64_t)lo));
            json_object_object_add(r, "fpga_ts_hi", json_object_new_int64((int64_t)hi));
        }
        break;
    }
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
        if (!m->rx_slot_valid) {
            /* background (TX-only): no RX checker slot. rx counters are
             * legitimately zero (rs stays {0}); rx_local_flow_id must NOT be
             * read -- it would alias a real flow's slot. Don't fault read_ok for
             * the intentionally-absent RX side. */
        } else if (rx_ci != (size_t)-1 && cards[rx_ci].open &&
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
        /* Physical tx->rx path: global ports + "cardName.portName" labels, so a
         * client (CLI / GUI dashboard) can show "card0.p0 -> card1.p2" from the
         * live stats alone without joining against the topology. */
        {
            const struct pw_flow *cf = pw_config_flow_by_id(cfg, m->global_flow_id);
            uint16_t txgp = cf ? cf->tx_global_port : 0;
            uint16_t rxgp = cf ? cf->rx_global_port : 0;
            char txl[PW_NAME_MAX * 2 + 2], rxl[PW_NAME_MAX * 2 + 2];
            port_label(cfg, txgp, txl, sizeof txl);
            port_label(cfg, rxgp, rxl, sizeof rxl);
            json_object_object_add(f, "name", json_object_new_string(cf ? cf->name : ""));
            json_object_object_add(f, "tx_global_port", json_object_new_int(txgp));
            json_object_object_add(f, "rx_global_port", json_object_new_int(rxgp));
            json_object_object_add(f, "tx_port", json_object_new_string(txl));
            json_object_object_add(f, "rx_port", json_object_new_string(rxl));
        }
        json_object_object_add(f, "enabled",
            json_object_new_boolean(flow_enabled(prog, m->global_flow_id)));
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
        json_object_object_add(f, "last_seq",  json_object_new_int64((int64_t)rs.last_sequence));

        /* Cross-card latency is corrected PER FLOW in hardware: the daemon servo
         * writes each cross-card flow's slot in the lat_correction table, and the
         * checker computes lat = (rx_wire_ts + corr[slot]) - tx_ts. So
         * min/max/sum/histogram already hold the true one-way latency here -- no
         * read-time correction, and avg (from the now-small 64-bit sum) is valid
         * for cross-card too. Same-card flows run with correction 0 (unchanged).
         * offset_ticks is reported for visibility (the live servo offset).
         * latency is valid for both same- and cross-card, but ONLY if the
         * counter read actually succeeded (read_ok) -- otherwise the fields are
         * stale/zero, not a real measurement. */
        bool xcard = (m->tx_card_id != m->rx_card_id);
        bool lat_ok = read_ok && m->rx_slot_valid && (m->latency_valid || xcard);
        json_object_object_add(f, "latency_valid", json_object_new_boolean(lat_ok));
        if (lat_ok) {
            /* min_latency / jitter_min are tracked in HW from a 0xFFFFFFFF
             * sentinel that the first sample overwrites. With NO samples yet
             * (no traffic / flow not started) that sentinel is meaningless --
             * report 0 so it never surfaces as a bogus ~27.5 s "min" (0xFFFFFFFF
             * ticks * 6.4 ns). Consumers key "has a measurement" off
             * sample_count, which is emitted below. */
            int have = rs.sample_count > 0;
            json_object_object_add(f, "min_latency",
                json_object_new_int64(have ? (int64_t)(uint32_t)rs.min_latency : 0));
            json_object_object_add(f, "max_latency", json_object_new_int64((int64_t)(uint32_t)rs.max_latency));
            int64_t avg = rs.sample_count ? (int64_t)(rs.sum_latency / rs.sample_count) : 0;
            json_object_object_add(f, "avg_latency", json_object_new_int64(avg));
            json_object_object_add(f, "sample_count",
                                   json_object_new_int64((int64_t)rs.sample_count));
            json_object_object_add(f, "jitter_min",
                json_object_new_int64(have ? (int64_t)rs.jitter_min : 0));
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

/* flow.preview: build the on-wire frame a flow's generator emits (shared
 * builder in libpacketwyrm) and return it as hex + a decoded summary. The flow
 * source is either an inline test-config `yaml` (so the GUI can preview an
 * edited-but-unloaded flow) or, absent that, the running config. `id` selects a
 * flow by global id (else the first); `seq` picks the packet number. Offline /
 * read-only: touches no hardware. */
static struct json_object *build_flow_preview(const struct pw_config *run_cfg,
                                              const char *yaml, size_t yaml_len,
                                              int want_id, uint32_t seq) {
    struct pw_config *tmp = NULL;
    const struct pw_config *cfg = run_cfg;
    if (yaml && yaml_len) {
        tmp = pw_config_new();
        struct pw_diag d = {0};
        if (pw_config_parse_string_ex(yaml, yaml_len, PW_CFG_TEST_ONLY, tmp, &d) != PW_OK) {
            char m[300]; snprintf(m, sizeof m, "preview parse error at %.40s: %.220s", d.path, d.message);
            pw_config_free(tmp);
            return build_error(m);
        }
        cfg = tmp;
    }
    if (!cfg || cfg->n_flows == 0) {
        if (tmp) pw_config_free(tmp);
        return build_error("no flows to preview");
    }
    const struct pw_flow *f = NULL;
    for (size_t i = 0; i < cfg->n_flows; i++) {
        if (want_id < 0 || (int)cfg->flows[i].id == want_id) { f = &cfg->flows[i]; break; }
    }
    if (!f) { if (tmp) pw_config_free(tmp); return build_error("flow id not found"); }

    uint8_t buf[9200]; size_t built = 0;
    int len = pw_flow_build_preview(f, seq, buf, sizeof buf, &built);
    if (len < 0) { if (tmp) pw_config_free(tmp); return build_error("cannot build preview (unsupported template/length)"); }

    struct json_object *r = json_object_new_object();
    json_object_object_add(r, "ok", json_object_new_boolean(true));
    json_object_object_add(r, "flow", json_object_new_int((int)f->id));
    json_object_object_add(r, "name", json_object_new_string(f->name));
    unsigned t = f->traffic.frame_template;
    json_object_object_add(r, "template", json_object_new_string(
        t==0?"test":t==1?"l4raw":t==2?"l3raw":t==3?"l2raw":"?"));
    json_object_object_add(r, "len", json_object_new_int(len));
    json_object_object_add(r, "header_len", json_object_new_int((int)built));
    json_object_object_add(r, "seq", json_object_new_int64(seq));
    /* hex string of the whole frame */
    char *hex = malloc((size_t)len * 2 + 1);
    if (hex) {
        static const char H[] = "0123456789abcdef";
        for (int b = 0; b < len; b++) { hex[b*2] = H[buf[b]>>4]; hex[b*2+1] = H[buf[b]&0xF]; }
        hex[len*2] = '\0';
        json_object_object_add(r, "hex", json_object_new_string(hex));
        free(hex);
    }
    /* decoded field summary (mirrors the CLI preview) */
    struct json_object *dec = json_object_new_object();
    char mac[24];
    snprintf(mac, sizeof mac, "%02x:%02x:%02x:%02x:%02x:%02x",
             f->l2.dst_mac[0],f->l2.dst_mac[1],f->l2.dst_mac[2],f->l2.dst_mac[3],f->l2.dst_mac[4],f->l2.dst_mac[5]);
    json_object_object_add(dec, "eth_dst", json_object_new_string(mac));
    snprintf(mac, sizeof mac, "%02x:%02x:%02x:%02x:%02x:%02x",
             f->l2.src_mac[0],f->l2.src_mac[1],f->l2.src_mac[2],f->l2.src_mac[3],f->l2.src_mac[4],f->l2.src_mac[5]);
    json_object_object_add(dec, "eth_src", json_object_new_string(mac));
    if (f->l2.vlan_set) json_object_object_add(dec, "vlan", json_object_new_int(f->l2.vlan));
    if (f->encap.present && t != 3)
        json_object_object_add(dec, "encap", json_object_new_string(
            f->encap.type==1?"ipip":f->encap.type==2?"gre":"etherip"));
    if (t != 3)
        json_object_object_add(dec, "l3", json_object_new_string(f->ipv6.present?"ipv6":"ipv4"));
    if (t != 3 && t != 2)
        json_object_object_add(dec, "l4", json_object_new_string(f->udp.l4_proto==6?"tcp":"udp"));
    json_object_object_add(r, "decode", dec);

    if (tmp) pw_config_free(tmp);
    return r;
}

/* Handle one connection: read one request frame, dispatch, write
 * one response frame. */
static void handle_client(int cfd,
                          struct pw_config  **cfg_pp,
                          struct pw_program **prog_pp,
                          struct card_runtime cards[],
                          struct pw_host_plane *hps[MAX_CARDS],
                          const struct tap_handle *taps,
                          int n_taps) {
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
    } else if (json_object_get_type(req) != json_type_object) {
        /* A top-level array/scalar isn't a request envelope; reject it rather
         * than letting object-field lookups silently no-op into "unknown rpc". */
        resp = build_error("request must be a JSON object");
    } else {
        struct json_object *rpc;
        const char *name = NULL;
        /* `rpc` must be a STRING -- json_object_get_string() would otherwise
         * stringify a number/bool/object and match an unintended method name. */
        if (json_object_object_get_ex(req, "rpc", &rpc) &&
            json_object_get_type(rpc) == json_type_string) {
            name = json_object_get_string(rpc);
        }
        /* Access control: when the environment config sets a secret, every
         * request must carry a matching "secret" (constant-time compare). A
         * client obtains it by reading the env config, so read permission on
         * that file is the gate. Empty secret -> auth disabled (dev/CI). */
        const char *want = cfg->system.secret;
        bool authed = (want[0] == '\0');
        if (!authed) {
            struct json_object *js;
            const char *got_s = (json_object_object_get_ex(req, "secret", &js))
                              ? json_object_get_string(js) : "";
            /* constant-time compare over the fixed secret buffer */
            size_t wl = strnlen(want, PW_SECRET_MAX), gl = strlen(got_s);
            unsigned diff = (unsigned)(wl ^ gl);
            for (size_t i = 0; i < wl; i++) diff |= (unsigned)(want[i] ^ (i < gl ? got_s[i] : 0));
            authed = (diff == 0);
        }
        if      (!authed)                   resp = build_error("unauthorized");
        else if (!name)                     resp = build_error("missing rpc");
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
        } else if (!strcmp(name, "ports.stats")) {
            resp = build_port_stats(cfg, cards);
        } else if (!strcmp(name, "tap.stats")) {
            resp = build_tap_stats(cfg, taps, n_taps, hps);
        } else if (!strcmp(name, "flow.hist")) {
            struct json_object *jid;
            if (!json_object_object_get_ex(req, "id", &jid)) {
                resp = build_error("missing id");
            } else {
                resp = build_flow_hist(cfg, prog, cards,
                                       json_object_get_int(jid));
            }
        } else if (!strcmp(name, "flow.preview")) {
            struct json_object *jv, *ji, *js;
            const char *pv_yaml = NULL; size_t pv_ylen = 0;
            int pv_want = -1; uint32_t pv_seq = 0;
            if (json_object_object_get_ex(req, "yaml", &jv)) {
                pv_yaml = json_object_get_string(jv);
                pv_ylen = pv_yaml ? (size_t)json_object_get_string_len(jv) : 0;
            }
            if (json_object_object_get_ex(req, "id", &ji))  pv_want = json_object_get_int(ji);
            if (json_object_object_get_ex(req, "seq", &js)) pv_seq = (uint32_t)json_object_get_int64(js);
            resp = build_flow_preview(cfg, pv_yaml, pv_ylen, pv_want, pv_seq);
        } else if (!strcmp(name, "flow.stats")) {
            struct json_object *jc;
            int filter = -1;
            if (json_object_object_get_ex(req, "id", &jc))
                filter = json_object_get_int(jc);
            resp = build_flow_stats(cfg, prog, cards, filter);
        } else if (!strcmp(name, "sfp.info")) {
            struct json_object *jc;
            int cardf = -1, portf = -1;
            if (json_object_object_get_ex(req, "card", &jc)) cardf = json_object_get_int(jc);
            if (json_object_object_get_ex(req, "port", &jc)) portf = json_object_get_int(jc);
            resp = build_sfp_info(cfg, cards, cardf, portf);
        } else if (!strcmp(name, "test.start") || !strcmp(name, "test.stop") ||
                   !strcmp(name, "test.arm")) {
            bool en = (strcmp(name, "test.start") == 0);
            int  changed = 0, failed = 0;
            /* test.arm pushes the compiled program again (idempotent
             * resync), then soft-clears the RX checker counters on each
             * card so a measurement run starts from zero (the data plane
             * has no auto-reset; only this CSR write or rst_n). test.start
             * / test.stop walk every flow and flip the enable bit. */
            bool arm_programmed = true;
            if (!strcmp(name, "test.arm")) {
                /* Re-push the compiled program first. If it HARD-fails the FPGA
                 * may be only partially programmed -- do NOT clear the RX
                 * counters then (a clear would wipe measurement state and make a
                 * failed arm look armed). Report programmed:false so the operator
                 * re-arms / restarts instead of trusting zeroed counters. */
                if (program_backends(prog, cfg, cards) != PW_OK) {
                    failed++;
                    arm_programmed = false;
                } else {
                    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
                        if (cards[ci].open && cards[ci].backend.ops->write32) {
                            pw_status s = cards[ci].backend.ops->write32(
                                cards[ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
                            if (s == PW_OK) changed++;
                            else            failed++;
                        }
                    }
                }
            } else {
                for (size_t k = 0; k < prog->n_flow_meta; k++) {
                    pw_status s = set_flow_enable(prog, cards,
                                                  prog->flow_meta[k].global_flow_id,
                                                  en, /*persist=*/true);
                    if (s == PW_OK) changed++;
                    else            failed++;
                }
                /* test.start gives a clean, corrected baseline: now that the
                 * generators are enabled, zero the RX checker counters and
                 * (re)prime the cross-card lat_correction so a measurement
                 * begins from zero with the right timebase. (The servo thread
                 * keeps the correction tracked afterwards.) test.stop just
                 * freezes -- leave the counters readable. */
                if (en && !failed) {
                    prime_lat_correction(cfg, prog, cards);
                    for (size_t ci = 0; ci < cfg->n_cards; ci++)
                        if (cards[ci].open && cards[ci].backend.ops->write32)
                            (void)cards[ci].backend.ops->write32(
                                cards[ci].backend.ctx, PWFPGA_REG_STATS_CLEAR, 1u);
                }
            }
            resp = json_object_new_object();
            json_object_object_add(resp, "action", json_object_new_string(name));
            json_object_object_add(resp, "changed", json_object_new_int(changed));
            json_object_object_add(resp, "failed",  json_object_new_int(failed));
            if (!strcmp(name, "test.arm"))   /* false => re-program hard-failed, counters NOT cleared */
                json_object_object_add(resp, "programmed",
                                       json_object_new_boolean(arm_programmed));
            /* Warn if a cross-card measurement is armed/started before the J5
             * servo has a coherent offset: those first samples would carry raw
             * (wrong-timebase) latency. Only meaningful for arm/start. */
            if (strcmp(name, "test.stop") != 0) {
                bool conv = servo_converged(cfg, prog, cards);
                json_object_object_add(resp, "servo_converged",
                                       json_object_new_boolean(conv));
                if (!conv)
                    json_object_object_add(resp, "warning", json_object_new_string(
                        "cross-card servo has no coherent J5 offset yet -- "
                        "cross-card latency may be wrong; wait for sync then "
                        "re-arm (test.arm) to re-baseline"));
            }
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
        } else if (!strcmp(name, "config.get_raw")) {
            resp = build_config_get_raw(cfg);
        } else if (!strcmp(name, "config.get_test")) {
            resp = build_config_get_test(cfg);
        } else if (!strcmp(name, "config.save")) {
            resp = do_config_save(cfg_pp, req);
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
                pw_status s = set_flow_enable(prog, cards, id, en, /*persist=*/true);
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
                        size_t rd = img ? fread(img, 1, (size_t)sz, f) : 0;
                        fclose(f);
                        if (!img) { resp = build_error("out of memory"); }
                        else if (rd != (size_t)sz) { free(img); resp = build_error("file read failed"); }
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
    }
    /* Free the parsed request on EVERY non-NULL path (the "not an object" and
     * "invalid JSON" early branches reach here too). json_object_put(NULL) is a
     * no-op, but guard anyway for clarity. */
    if (req) json_object_put(req);

    const char *out = json_object_to_json_string_ext(resp, JSON_C_TO_STRING_PLAIN);
    pw_ipc_write_frame(cfd, out, strlen(out));
    json_object_put(resp);
}

/* ---- Prometheus exporter --------------------------------------------- */

/* The exporter serves plain, unauthenticated HTTP (build/version, card state,
 * host-plane counters, logical labels), so it binds 127.0.0.1 by DEFAULT --
 * exposing operational state to the whole LAN must be an explicit operator
 * choice (`-p 0.0.0.0:9100`), matching how proxyd gates remote access. */
/* Bound blocking reads/writes on an accepted connection so a stalled client
 * can't wedge the single-threaded main loop. Returns false (caller closes +
 * skips) if either timeout can't be set -- the DoS guard must not be silently
 * absent. */
static bool set_conn_timeout(int fd, int seconds) {
    struct timeval tv = { .tv_sec = seconds, .tv_usec = 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) return false;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) return false;
    return true;
}

static int promex_listen(const char *addr, int port, int *out_fd) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
    };
    if (!addr || !*addr) addr = "127.0.0.1";
    if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1) { close(fd); return -1; }
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    *out_fd = fd;
    return 0;
}

static size_t promex_build_body(char *out, size_t cap,
                                const struct pw_config *cfg,
                                const struct pw_program *prog,
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

    /* Per-flow measurement metrics. Reuse build_flow_stats (the flow.stats RPC
     * data path: snapshots every card, aggregates via prog->flow_meta) and walk
     * its JSON so the exporter and the CLI/GUI always agree. Emitted only when a
     * program is loaded. Labeled by flow id + name so Grafana can group. */
    if (prog && prog->n_flow_meta > 0) {
        struct json_object *fs = build_flow_stats(cfg, prog, cards, -1);
        struct json_object *arr;
        if (fs && json_object_object_get_ex(fs, "flows", &arr) &&
            json_object_get_type(arr) == json_type_array) {
            APPENDF("# HELP packetwyrm_flow_tx_frames Frames transmitted per flow\n");
            APPENDF("# TYPE packetwyrm_flow_tx_frames counter\n");
            APPENDF("# HELP packetwyrm_flow_rx_frames Frames received per flow\n");
            APPENDF("# TYPE packetwyrm_flow_rx_frames counter\n");
            APPENDF("# HELP packetwyrm_flow_tx_bytes Bytes transmitted per flow\n");
            APPENDF("# TYPE packetwyrm_flow_tx_bytes counter\n");
            APPENDF("# HELP packetwyrm_flow_rx_bytes Bytes received per flow\n");
            APPENDF("# TYPE packetwyrm_flow_rx_bytes counter\n");
            APPENDF("# HELP packetwyrm_flow_lost_packets Estimated lost packets per flow\n");
            APPENDF("# TYPE packetwyrm_flow_lost_packets counter\n");
            APPENDF("# HELP packetwyrm_flow_duplicate_packets Duplicate packets per flow\n");
            APPENDF("# TYPE packetwyrm_flow_duplicate_packets counter\n");
            APPENDF("# HELP packetwyrm_flow_out_of_order_packets Out-of-order packets per flow\n");
            APPENDF("# TYPE packetwyrm_flow_out_of_order_packets counter\n");
            APPENDF("# HELP packetwyrm_flow_sequence_gaps Sequence-gap events per flow\n");
            APPENDF("# TYPE packetwyrm_flow_sequence_gaps counter\n");
            APPENDF("# HELP packetwyrm_flow_latency_samples Latency samples measured per flow\n");
            APPENDF("# TYPE packetwyrm_flow_latency_samples counter\n");
            APPENDF("# HELP packetwyrm_flow_running 1 when the flow's generator is enabled\n");
            APPENDF("# TYPE packetwyrm_flow_running gauge\n");
            APPENDF("# HELP packetwyrm_flow_latency_ns One-way latency per flow (nanoseconds)\n");
            APPENDF("# TYPE packetwyrm_flow_latency_ns gauge\n");
            APPENDF("# HELP packetwyrm_flow_jitter_ns Inter-packet delay variation per flow (nanoseconds)\n");
            APPENDF("# TYPE packetwyrm_flow_jitter_ns gauge\n");
            size_t nf = json_object_array_length(arr);
            for (size_t i = 0; i < nf; i++) {
                struct json_object *f = json_object_array_get_idx(arr, i), *v;
                int id = 0; const char *nm = "";
                if (json_object_object_get_ex(f, "id", &v)) id = json_object_get_int(v);
                if (json_object_object_get_ex(f, "name", &v)) nm = json_object_get_string(v);
                #define FLOWMETRIC(field, key) do { \
                    if (json_object_object_get_ex(f, key, &v)) \
                        APPENDF("packetwyrm_flow_" field "{flow=\"%d\",name=\"%s\"} %lld\n", \
                                id, nm, (long long)json_object_get_int64(v)); \
                } while (0)
                FLOWMETRIC("tx_frames", "tx_frames");
                FLOWMETRIC("rx_frames", "rx_frames");
                FLOWMETRIC("tx_bytes",  "tx_bytes");
                FLOWMETRIC("rx_bytes",  "rx_bytes");
                FLOWMETRIC("lost_packets", "lost");
                FLOWMETRIC("duplicate_packets", "duplicate");
                FLOWMETRIC("out_of_order_packets", "out_of_order");
                FLOWMETRIC("sequence_gaps", "seq_gap");
                FLOWMETRIC("latency_samples", "sample_count");
                #undef FLOWMETRIC
                if (json_object_object_get_ex(f, "enabled", &v))
                    APPENDF("packetwyrm_flow_running{flow=\"%d\",name=\"%s\"} %d\n",
                            id, nm, json_object_get_boolean(v) ? 1 : 0);
                /* Latency AND jitter come from the JSON in data-plane TICKS
                 * (6.4 ns); convert to ns. ns = ticks * 1e9 / clock_hz. Only
                 * present when the measurement is valid (has samples). */
                struct json_object *lv;
                if (json_object_object_get_ex(f, "latency_valid", &lv) &&
                    json_object_get_boolean(lv)) {
                    static const struct { const char *lkey, *jkey, *stat; } st[] = {
                        {"min_latency","jitter_min","min"},
                        {"avg_latency","jitter_avg","avg"},
                        {"max_latency","jitter_max","max"} };
                    for (size_t k = 0; k < 3; k++) {
                        if (json_object_object_get_ex(f, st[k].lkey, &v))
                            APPENDF("packetwyrm_flow_latency_ns{flow=\"%d\",name=\"%s\",stat=\"%s\"} %.1f\n",
                                    id, nm, st[k].stat,
                                    (double)json_object_get_int64(v) * 1e9 / (double)PWFPGA_DATA_PLANE_CLOCK_HZ);
                        if (json_object_object_get_ex(f, st[k].jkey, &v))
                            APPENDF("packetwyrm_flow_jitter_ns{flow=\"%d\",name=\"%s\",stat=\"%s\"} %.1f\n",
                                    id, nm, st[k].stat,
                                    (double)json_object_get_int64(v) * 1e9 / (double)PWFPGA_DATA_PLANE_CLOCK_HZ);
                    }
                }
            }
        }
        if (fs) json_object_put(fs);
    }

    /* ---- Card / FPGA health (per card): SYSMON die temp + supply rails, and
     * the sticky-error / activity status bits. Cheap direct CSR reads. ---- */
    APPENDF("# HELP packetwyrm_card_temp_celsius FPGA die temperature (SYSMON)\n");
    APPENDF("# TYPE packetwyrm_card_temp_celsius gauge\n");
    APPENDF("# HELP packetwyrm_card_vccint_volts FPGA VCCINT rail (SYSMON)\n");
    APPENDF("# TYPE packetwyrm_card_vccint_volts gauge\n");
    APPENDF("# HELP packetwyrm_card_vccaux_volts FPGA VCCAUX rail (SYSMON)\n");
    APPENDF("# TYPE packetwyrm_card_vccaux_volts gauge\n");
    APPENDF("# HELP packetwyrm_card_error_sticky 1 when the card latched an error\n");
    APPENDF("# TYPE packetwyrm_card_error_sticky gauge\n");
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (!cards[ci].open || !cards[ci].backend.ops->read32) continue;
        void *bx = cards[ci].backend.ctx;
        unsigned id = cfg->cards[ci].id;
        uint32_t tc = 0, sup = 0, gs = 0;
        if (cards[ci].backend.ops->read32(bx, PWFPGA_REG_SYSMON_TEMP, &tc) == PW_OK &&
            PWFPGA_SYSMON_CODE(tc) != 0) {
            APPENDF("packetwyrm_card_temp_celsius{card=\"%u\"} %.1f\n", id, PWFPGA_SYSMON_TEMP_C(tc));
            if (cards[ci].backend.ops->read32(bx, PWFPGA_REG_SYSMON_SUPPLY, &sup) == PW_OK) {
                if (PWFPGA_SYSMON_CODE(sup & 0xFFFF))
                    APPENDF("packetwyrm_card_vccint_volts{card=\"%u\"} %.3f\n", id, PWFPGA_SYSMON_SUPPLY_V(sup & 0xFFFF));
                if (PWFPGA_SYSMON_CODE(sup >> 16))
                    APPENDF("packetwyrm_card_vccaux_volts{card=\"%u\"} %.3f\n", id, PWFPGA_SYSMON_SUPPLY_V(sup >> 16));
            }
        }
        if (cards[ci].backend.ops->read32(bx, PWFPGA_REG_GLOBAL_STATUS, &gs) == PW_OK)
            APPENDF("packetwyrm_card_error_sticky{card=\"%u\"} %d\n",
                    id, (gs & PWFPGA_GSTAT_ERROR) ? 1 : 0);
    }

    /* ---- Per-port wire counters (per card+port) straight from the MAC. ---- */
    APPENDF("# HELP packetwyrm_port_rx_frames Frames received on the port (wire)\n");
    APPENDF("# TYPE packetwyrm_port_rx_frames counter\n");
    APPENDF("# HELP packetwyrm_port_tx_frames Frames transmitted on the port (wire)\n");
    APPENDF("# TYPE packetwyrm_port_tx_frames counter\n");
    APPENDF("# HELP packetwyrm_port_rx_bytes Bytes received on the port (wire)\n");
    APPENDF("# TYPE packetwyrm_port_rx_bytes counter\n");
    APPENDF("# HELP packetwyrm_port_tx_bytes Bytes transmitted on the port (wire)\n");
    APPENDF("# TYPE packetwyrm_port_tx_bytes counter\n");
    APPENDF("# HELP packetwyrm_port_rx_fcs_errors FCS (CRC) errors received\n");
    APPENDF("# TYPE packetwyrm_port_rx_fcs_errors counter\n");
    APPENDF("# HELP packetwyrm_port_rx_bad_frames Real RX drops (SAF buffer overflow)\n");
    APPENDF("# TYPE packetwyrm_port_rx_bad_frames counter\n");
    APPENDF("# HELP packetwyrm_port_rx_oversize Oversize frames received\n");
    APPENDF("# TYPE packetwyrm_port_rx_oversize counter\n");
    APPENDF("# HELP packetwyrm_port_rx_undersize Undersize frames received\n");
    APPENDF("# TYPE packetwyrm_port_rx_undersize counter\n");
    APPENDF("# HELP packetwyrm_port_rx_unmatched Frames with no classifier match (informational)\n");
    APPENDF("# TYPE packetwyrm_port_rx_unmatched counter\n");
    APPENDF("# HELP packetwyrm_port_link_up_events Link-up transitions\n");
    APPENDF("# TYPE packetwyrm_port_link_up_events counter\n");
    APPENDF("# HELP packetwyrm_port_link_down_events Link-down transitions\n");
    APPENDF("# TYPE packetwyrm_port_link_down_events counter\n");
    APPENDF("# HELP packetwyrm_port_block_lock_loss PCS block-lock loss events\n");
    APPENDF("# TYPE packetwyrm_port_block_lock_loss counter\n");
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (!cards[ci].open || !cards[ci].backend.ops->port_stats_read) continue;
        if (cards[ci].backend.ops->stats_snapshot)
            (void)cards[ci].backend.ops->stats_snapshot(cards[ci].backend.ctx);
        unsigned id = cfg->cards[ci].id;
        for (uint8_t p = 0; p < PW_PORTS_PER_CARD; p++) {
            struct pw_port_stats ps = {0};
            if (cards[ci].backend.ops->port_stats_read(cards[ci].backend.ctx, p, &ps) != PW_OK)
                continue;
            #define PORTMETRIC(field, val) \
                APPENDF("packetwyrm_port_" field "{card=\"%u\",port=\"%u\"} %llu\n", id, p, (unsigned long long)(val))
            PORTMETRIC("rx_frames",      ps.rx_frames);
            PORTMETRIC("tx_frames",      ps.tx_frames);
            PORTMETRIC("rx_bytes",       ps.rx_bytes);
            PORTMETRIC("tx_bytes",       ps.tx_bytes);
            PORTMETRIC("rx_fcs_errors",  ps.rx_fcs_error);
            PORTMETRIC("rx_bad_frames",  ps.rx_bad_frame);
            PORTMETRIC("rx_oversize",    ps.rx_oversize);
            PORTMETRIC("rx_undersize",   ps.rx_undersize);
            PORTMETRIC("rx_unmatched",   ps.rx_unmatched);
            PORTMETRIC("link_up_events", ps.link_up_count);
            PORTMETRIC("link_down_events", ps.link_down_count);
            PORTMETRIC("block_lock_loss", ps.block_lock_loss);
            #undef PORTMETRIC
        }
    }

    /* ---- SFP+ optics (per card+port) from the background DOM cache -- no I2C
     * on the scrape path (the sfp poller thread refills g_sfp_cache). ---- */
    APPENDF("# HELP packetwyrm_sfp_present 1 when a module is seated\n");
    APPENDF("# TYPE packetwyrm_sfp_present gauge\n");
    APPENDF("# HELP packetwyrm_sfp_temp_celsius Module temperature (DOM)\n");
    APPENDF("# TYPE packetwyrm_sfp_temp_celsius gauge\n");
    APPENDF("# HELP packetwyrm_sfp_vcc_volts Module supply voltage (DOM)\n");
    APPENDF("# TYPE packetwyrm_sfp_vcc_volts gauge\n");
    APPENDF("# HELP packetwyrm_sfp_tx_bias_ma Laser bias current (DOM)\n");
    APPENDF("# TYPE packetwyrm_sfp_tx_bias_ma gauge\n");
    APPENDF("# HELP packetwyrm_sfp_tx_power_dbm TX optical power (DOM)\n");
    APPENDF("# TYPE packetwyrm_sfp_tx_power_dbm gauge\n");
    APPENDF("# HELP packetwyrm_sfp_rx_power_dbm RX optical power (DOM)\n");
    APPENDF("# TYPE packetwyrm_sfp_rx_power_dbm gauge\n");
    pthread_mutex_lock(&g_sfp_lock);
    for (size_t ci = 0; ci < cfg->n_cards && ci < MAX_CARDS; ci++) {
        unsigned id = cfg->cards[ci].id;
        for (int p = 0; p < 2; p++) {
            struct sfp_cache_entry *e = &g_sfp_cache[ci][p];
            if (!e->valid || !e->probe_ok) continue;
            APPENDF("packetwyrm_sfp_present{card=\"%u\",port=\"%d\"} %d\n", id, p, e->info.present ? 1 : 0);
            if (e->info.present && e->info.dom_valid) {
                APPENDF("packetwyrm_sfp_temp_celsius{card=\"%u\",port=\"%d\"} %.1f\n", id, p, e->info.temp_c);
                APPENDF("packetwyrm_sfp_vcc_volts{card=\"%u\",port=\"%d\"} %.3f\n", id, p, e->info.vcc_v);
                APPENDF("packetwyrm_sfp_tx_bias_ma{card=\"%u\",port=\"%d\"} %.2f\n", id, p, e->info.tx_bias_ma);
                /* mW -> dBm (operators read optical power in dBm). Guard log(0). */
                if (e->info.tx_power_mw > 0)
                    APPENDF("packetwyrm_sfp_tx_power_dbm{card=\"%u\",port=\"%d\"} %.2f\n", id, p, 10.0 * log10(e->info.tx_power_mw));
                if (e->info.rx_power_mw > 0)
                    APPENDF("packetwyrm_sfp_rx_power_dbm{card=\"%u\",port=\"%d\"} %.2f\n", id, p, 10.0 * log10(e->info.rx_power_mw));
            }
        }
    }
    pthread_mutex_unlock(&g_sfp_lock);
    #undef APPENDF
    return n;
}

static void promex_handle(int cfd,
                          const struct pw_config *cfg,
                          const struct pw_program *prog,
                          struct card_runtime cards[],
                          struct pw_host_plane *hps[MAX_CARDS]) {
    /* Read until \r\n\r\n or some limit; we don't actually parse the
     * request, just acknowledge any GET and respond. */
    char req[1024];
    ssize_t n = read(cfd, req, sizeof(req) - 1);
    if (n <= 0) return;
    req[n] = 0;

    /* Sized for the management metrics + per-flow lines (NUM_FLOWS x ~10
     * series x ~80 B); comfortably covers 32 flows. */
    static char body[262144];
    size_t bn = promex_build_body(body, sizeof(body), cfg, prog, cards, hps);

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
    /* -e ENV (environment: system/cards/logical_interfaces/secret, rarely
     * changed) + optional -t TEST (flows/forwards, changed often). -c is a
     * back-compat alias for -e; a combined single file still works via -e. */
    const char *env_path  = "/etc/packetwyrm/packetwyrm.yaml";
    const char *test_path = NULL;
    bool dry_run        = false;
    bool verbose        = false;
    bool allow_fake     = false;
    int  stats_interval = 5000;
    int  servo_interval = 10;     /* cross-card lat_correction servo period (ms) */
    int  prom_port      = 0;
    const char *prom_addr = "127.0.0.1";   /* -p default: loopback only */

    int opt;
    static const struct option long_opts[] = {
        {"autostart",  no_argument, 0, 'a'},
        {"allow-fake", no_argument, 0, 'F'},
        {"help",       no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    while ((opt = getopt_long(argc, argv, "c:e:t:nvas:S:C:p:Fh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'c': case 'e': env_path = optarg; g_env_path = optarg; break;
        case 't': test_path = optarg; break;
        case 'n': dry_run = true; break;
        case 'v': verbose = true; break;
        case 'a': g_gen_autostart = true; break;
        case 's': stats_interval = atoi(optarg); break;
        case 'S': servo_interval = atoi(optarg); if (servo_interval < 1) servo_interval = 1; break;
        case 'C': g_xcard_lat_cal_ticks = atoi(optarg); break;   /* xcard lat calibration (signed ticks) */
        case 'p': {   /* -p [ADDR:]PORT ; ADDR defaults to 127.0.0.1 */
            char *colon = strrchr(optarg, ':');
            if (colon) { *colon = '\0'; prom_addr = optarg; prom_port = atoi(colon + 1); }
            else       { prom_port = atoi(optarg); }
            break;
        }
        case 'F': allow_fake = true; break;
        case 'h': default: usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }

    struct pw_config  *cfg  = pw_config_new();
    struct pw_program *prog = pw_program_new();
    struct pw_diag     diag = {0};
    pw_status r;

    /* Environment config (system + cards + logical_interfaces + secret). A
     * combined file with flows here also works (back-compat). */
    if ((r = pw_config_parse_file(env_path, cfg, &diag)) != PW_OK) {
        fprintf(stderr, "parse env: %s at %s: %s\n", pw_strerror(r), diag.path, diag.message);
        return 1;
    }
    /* Stash the env text as loaded, so config.save's restart_required compares
     * against what the running daemon actually parsed (not the live file). */
    g_env_loaded_yaml = read_file_str(env_path);
    /* Optional test config: parse flows/forwards and attach onto the env. */
    if (test_path) {
        struct pw_config *t = pw_config_new();
        if ((r = pw_config_parse_file_ex(test_path, PW_CFG_TEST_ONLY, t, &diag)) != PW_OK) {
            fprintf(stderr, "parse test: %s at %s: %s\n", pw_strerror(r), diag.path, diag.message);
            return 1;
        }
        /* move flows/forwards from the test config onto the environment config */
        cfg->flows = t->flows; cfg->n_flows = t->n_flows; t->flows = NULL; t->n_flows = 0;
        cfg->forwards = t->forwards; cfg->n_forwards = t->n_forwards; t->forwards = NULL; t->n_forwards = 0;
        pw_config_free(t);
        /* Stash the raw text so config.get_test can serve the running flows. */
        char *tb = read_file_str(test_path);
        if (tb) { set_test_yaml(tb); free(tb); }
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

    int n_failed = open_all_backends(cfg, cards, allow_fake);
    if (n_failed > 0 && !allow_fake) {
        fprintf(stderr, "fatal: %d of %zu card backend(s) failed to open; "
                "refusing to run with an unprogrammed data path "
                "(pass -F/--allow-fake for a dev/CI no-op backend)\n",
                n_failed, cfg->n_cards);
        close_all_backends(cfg, cards);
        return 1;
    }
    /* Explicit-start default: stage all generators idle before the first
     * program so nothing hits the wire until `test.start` (-a/--autostart
     * keeps the compiled enable=1 and generates immediately). */
    if (!g_gen_autostart) stage_flow_run_state(prog, false);
    if (program_backends(prog, cfg, cards) != PW_OK) {
        if (!allow_fake) {
            fprintf(stderr, "fatal: initial FPGA programming failed -- the device "
                    "is not in sync with the config (BAR write error / card drop / "
                    "window mismatch); refusing to run "
                    "(pass -F/--allow-fake for dev/CI)\n");
            close_all_backends(cfg, cards);
            return 1;
        }
        fprintf(stderr, "warning: initial FPGA programming hard-failed -- "
                "device may not match config (check the card / BAR)\n");
    }
    int n_taps = setup_taps(cfg, cards, hps, taps, PW_HOST_PLANE_MAX_BINDINGS,
                            true, allow_fake);
    if (n_taps < 0) {
        fprintf(stderr, "fatal: a configured logical_if could not get a working "
                "TAP; the control-plane path would blackhole "
                "(pass -F/--allow-fake to tolerate missing TAPs in dev/CI)\n");
        close_all_backends(cfg, cards);
        return 1;
    }
    if (n_taps == 0) {
        if (cfg->n_logical_if > 0 && !allow_fake) {
            fprintf(stderr, "fatal: no TAPs created though %zu logical_if(s) are "
                    "configured (pass -F/--allow-fake for dev/CI)\n",
                    cfg->n_logical_if);
            close_all_backends(cfg, cards);
            return 1;
        }
        fprintf(stderr, "warning: no TAPs were created\n");
    }

    /* Control socket. Path comes from config; fall back to the library default.
     * The daemon runs as root, so a client that can write this socket gets
     * root-equivalent device ops (flow control, config.save, flash.write). In
     * production (no -F) create it 0660 so it is NOT world-writable, then
     * group-own it root:packetwyrm below so root or the packetwyrm group (e.g.
     * the packetwyrm-proxyd gateway) can drive it, on top of the system.secret
     * check. Dev/CI (-F) uses 0666 so non-root tests work without group setup. */
    int ipc_listen_fd = -1;
    mode_t sock_mode = allow_fake ? 0666 : 0660;
    const char *sock_path = cfg->system.control_socket[0]
        ? cfg->system.control_socket
        : PW_IPC_DEFAULT_PATH;
    pw_status sr = pw_ipc_listen(sock_path, sock_mode, &ipc_listen_fd);
    if (sr != PW_OK) {
        /* The control socket is how everything is driven -- config.load, flow
         * start/stop, flash, stats, and the proxyd relay. Without it the daemon
         * would look healthy under systemd but be entirely unmanageable, so a
         * listen failure is fatal (not a warning). */
        fprintf(stderr, "fatal: control socket on %s unavailable: %s -- the daemon "
                "would be unmanageable; refusing to run\n",
                sock_path, pw_strerror(sr));
        close_all_backends(cfg, cards);
        return 1;
    }
    /* In production the socket is 0660 (not world-writable). Group-own it by
     * `packetwyrm` so the unprivileged packetwyrm-proxyd gateway (User/Group=
     * packetwyrm) can reach it without being root. Best-effort: if the group
     * isn't installed (dev box without packaging/packetwyrm.sysusers) the socket
     * stays root-only and only root can drive it -- still safe, just no proxyd. */
    if (!allow_fake) {
        struct group *grp = getgrnam("packetwyrm");
        if (grp) {
            if (chown(sock_path, 0, grp->gr_gid) != 0)
                fprintf(stderr, "warning: could not chown %s to root:packetwyrm: %s "
                        "(proxyd may not connect)\n", sock_path, strerror(errno));
        } else {
            fprintf(stderr, "warning: group 'packetwyrm' not found -- control socket "
                    "%s stays root-only; install packaging/packetwyrm.sysusers so "
                    "packetwyrm-proxyd can connect\n", sock_path);
        }
    }
    if (verbose)
        printf("  control socket listening on %s\n", sock_path);

    int prom_fd = -1;
    if (prom_port > 0) {
        if (promex_listen(prom_addr, prom_port, &prom_fd) < 0) {
            fprintf(stderr, "warning: Prometheus listener on %s:%d failed\n", prom_addr, prom_port);
            prom_fd = -1;
        } else if (verbose) {
            printf("  Prometheus exporter on %s:%d/metrics\n", prom_addr, prom_port);
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

    /* Run the cross-card servo and the SFP refresh in their OWN threads so no
     * slow control RPC can block them on the main loop. Start the SERVO FIRST
     * (so it tracks the offset immediately after prime, before the SFP thread's
     * first ~0.3 s/module I2C pass), then the SFP thread -- whose first pass
     * warms the cache in the background (sfp.info returns pending until then).
     * Both threads touch cards[].backend concurrently with the host-plane worker
     * threads; that is the existing design -- BAR/MMIO word accesses to DISJOINT
     * register regions need no lock (backend_bar.c), and the servo (GPIO_SYNC +
     * LAT_CORRECTION regs) and SFP refresh (REG_SFP_I2C only) touch disjoint
     * registers from each other and from program_backends. */
    struct servo_args srv_args = {
        .cfgp = &cfg, .progp = &prog, .cards = cards, .interval_ms = servo_interval,
    };
    pthread_t servo_tid; bool servo_running = false;
    if (pthread_create(&servo_tid, NULL, servo_thread_fn, &srv_args) == 0)
        servo_running = true;
    else
        fprintf(stderr, "warning: servo thread failed to start; cross-card latency "
                "correction will not track the inter-card offset\n");

    struct sfp_refresh_args sfp_args = { .cards = cards, .n_cards = cfg->n_cards };
    pthread_t sfp_tid; bool sfp_running = false;
    if (pthread_create(&sfp_tid, NULL, sfp_refresh_thread_fn, &sfp_args) == 0)
        sfp_running = true;
    else
        fprintf(stderr, "warning: SFP refresh thread failed to start; sfp.info will be stale\n");

    uint64_t last_stats = now_ms();
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
        /* Wake at least as often as the servo period so -S can actually tighten
         * the servo cadence (the loop otherwise idles in poll). */
        int poll_ms = servo_interval < 100 ? servo_interval : 100;
        (void)poll(np ? pfds : NULL, np, poll_ms);

        if (listen_idx != (size_t)-1 && (pfds[listen_idx].revents & POLLIN)) {
            int cfd = accept(ipc_listen_fd, NULL, NULL);
            if (cfd >= 0) {
                /* The daemon is single-threaded and the control socket is world-
                 * accessible in dev mode, so a stalled/malicious client (send a
                 * 4-byte length, then no body) would otherwise wedge the whole
                 * main loop (servo, metrics, all RPCs) forever. A 5 s timeout
                 * makes read_all() fail and the connection close. */
                if (!set_conn_timeout(cfd, 5)) {
                    fprintf(stderr, "warning: could not arm control-socket timeout; "
                            "dropping connection\n");
                    close(cfd);
                } else {
                    handle_client(cfd, &cfg, &prog, cards, hps, taps, n_taps);
                    close(cfd);
                }
            }
        }
        if (prom_idx != (size_t)-1 && (pfds[prom_idx].revents & POLLIN)) {
            int cfd = accept(prom_fd, NULL, NULL);
            if (cfd >= 0) {
                /* Same rationale as the control socket: don't let a slow HTTP
                 * client hang the single-threaded loop while it reads /metrics. */
                if (!set_conn_timeout(cfd, 5)) {
                    fprintf(stderr, "warning: could not arm metrics-socket timeout; "
                            "dropping connection\n");
                    close(cfd);
                } else {
                    promex_handle(cfd, cfg, prog, cards, hps);
                    close(cfd);
                }
            }
        }

        if (stats_interval > 0 &&
            (int)(now_ms() - last_stats) >= stats_interval) {
            print_stats(cfg, cards, hps);
            last_stats = now_ms();
        }
    }

    fprintf(stderr, "shutting down ...\n");
    /* servo + SFP threads poll g_stop (set by the signal handler); join them. */
    if (servo_running) pthread_join(servo_tid, NULL);
    if (sfp_running)   pthread_join(sfp_tid, NULL);
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
