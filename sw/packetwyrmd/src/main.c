/* packetwyrmd: load config, open backends, create TAPs, run the
 * host packet plane until SIGINT/SIGTERM. The full control socket
 * + per-card workers ship later; this is the minimum that
 * presents PacketWyrm to the rest of the host (Linux sees TAPs,
 * fake or real backend sees flow programming). */

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
        printf("  flow id=%u tx=p%u rx=p%u latency_valid=%s\n",
               f->id, f->tx_global_port, f->rx_global_port,
               m->latency_valid ? "yes" : "no (cross-card)");
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
 * can report that the FPGA is NOT in sync with the daemon's config. */
#define PB_CHK(call) do { \
    pw_status _s = (call); \
    if (_s != PW_OK && _s != PW_E_NOT_IMPLEMENTED && worst == PW_OK) worst = _s; \
} while (0)
static pw_status program_backends(const struct pw_program *prog,
                                  const struct pw_config *cfg,
                                  struct card_runtime cards[]) {
    pw_status worst = PW_OK;
    for (size_t ci = 0; ci < prog->n_cards; ci++) {
        const struct pw_card_program *cp = &prog->per_card[ci];
        if (!cards[ci].open) continue;
        const struct pw_card_backend *b = &cards[ci].backend;
        bool any_err = false;
        /* Soft-reset the data plane before (re)writing the tables. This
         * quiesces the generators / SAF / arbiters so reprogramming over a
         * running data plane cannot wedge it (configuration is preserved,
         * and we re-commit it immediately below). */
        if (b->ops->write32)
            PB_CHK(b->ops->write32(b->ctx, PWFPGA_REG_DP_RESET, 1u));
        for (size_t r = 0; r < cp->n_flow_rows; r++) {
            pw_status s = b->ops->flow_write
                ? b->ops->flow_write(b->ctx, (uint32_t)r, &cp->flow_rows[r])
                : PW_E_NOT_IMPLEMENTED;
            if (s != PW_OK) any_err = true;
            if (s != PW_OK && s != PW_E_NOT_IMPLEMENTED && worst == PW_OK) worst = s;
        }
        if (b->ops->flow_commit) PB_CHK(b->ops->flow_commit(b->ctx));
        /* TEST_RX flow-id map: test flows are classified by the flow-id map
         * (not classifier rules), so program one entry per test flow. */
        for (size_t m = 0; m < cp->n_map_entries; m++) {
            if (b->ops->write32)
                (void)b->ops->write32(b->ctx,
                    PWFPGA_WIN_FLOWID_MAP + cp->map_entries[m].flow_id * 4u,
                    PWFPGA_FLOWID_MAP_VALID | cp->map_entries[m].local_flow_id);
        }
        /* Unified field+UDF classifier: header-defined test flows + punt +
         * forward. Program each comparator ({src/offset,mask,value}; value
         * commits) then each rule (lif commits). */
        if (b->ops->write32) {
            for (size_t i = 0; i < cp->n_fc_cmps; i++) {
                const struct pw_fc_cmp *c = &cp->fc_cmps[i];
                (void)b->ops->write32(b->ctx, PWFPGA_FC_CMP_SRC(PWFPGA_WIN_FC_CMP, i), c->src);
                (void)b->ops->write32(b->ctx, PWFPGA_FC_CMP_MASK(PWFPGA_WIN_FC_CMP, i), c->mask);
                (void)b->ops->write32(b->ctx, PWFPGA_FC_CMP_VALUE(PWFPGA_WIN_FC_CMP, i), c->value);
            }
            for (size_t i = 0; i < cp->n_fc_udfs; i++) {
                const struct pw_fc_udf *u = &cp->fc_udfs[i];
                (void)b->ops->write32(b->ctx, PWFPGA_FC_UDF_OFFSET(PWFPGA_WIN_FC_UDF, i), u->offset);
                (void)b->ops->write32(b->ctx, PWFPGA_FC_UDF_MASK(PWFPGA_WIN_FC_UDF, i), u->mask);
                (void)b->ops->write32(b->ctx, PWFPGA_FC_UDF_VALUE(PWFPGA_WIN_FC_UDF, i), u->value);
            }
            for (size_t i = 0; i < cp->n_fc_rules; i++) {
                const struct pw_fc_rule *rl = &cp->fc_rules[i];
                (void)b->ops->write32(b->ctx, PWFPGA_FC_RULE_WORD0(PWFPGA_WIN_FC_RULE, i),
                    PWFPGA_FC_RULE_W0(rl->care, rl->action, rl->egress, rl->priority, 1));
                (void)b->ops->write32(b->ctx, PWFPGA_FC_RULE_LFID(PWFPGA_WIN_FC_RULE, i), rl->local_flow_id);
                (void)b->ops->write32(b->ctx, PWFPGA_FC_RULE_LIF(PWFPGA_WIN_FC_RULE, i), rl->logical_if_id);
            }
            /* Hash exact table: seed first, then each entry (key words, then the
             * control word commits at the SW-chosen bucket index). */
            if (cp->n_hash_entries > 0) {
                for (unsigned w = 0; w < PWFPGA_HASH_KEY_WORDS; w++)
                    (void)b->ops->write32(b->ctx,
                        PWFPGA_HASH_MASK_WORD(PWFPGA_WIN_HASH_MASK, w), cp->hash_mask[w]);
                (void)b->ops->write32(b->ctx, PWFPGA_REG_HASH_SEED, cp->hash_seed);
                for (size_t i = 0; i < cp->n_hash_entries; i++) {
                    const struct pw_fc_hash_entry *he = &cp->hash_entries[i];
                    for (unsigned w = 0; w < PWFPGA_HASH_KEY_WORDS; w++)
                        (void)b->ops->write32(b->ctx,
                            PWFPGA_HASH_KEY_WORD(PWFPGA_WIN_FC_HASH, he->index, w), he->key_word[w]);
                    (void)b->ops->write32(b->ctx,
                        PWFPGA_HASH_CTRL(PWFPGA_WIN_FC_HASH, he->index),
                        PWFPGA_HASH_CTRL_VALID | he->local_flow_id);
                }
            }
        }
        if (any_err) {
            fprintf(stderr,
                "  card%u(%s): some table writes returned not-implemented; "
                "RTL table windows not in this bitstream yet\n",
                (unsigned)cfg->cards[ci].id, cards[ci].which);
        }
    }
    return worst;
}
#undef PB_CHK

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
        char msg[256];
        snprintf(msg, sizeof(msg), "parse: %s at %s: %s",
                 pw_strerror(r), diag.path, diag.message);
        resp = build_error(msg);
        goto fail;
    }
    if ((r = pw_config_validate(new_cfg, &diag)) != PW_OK) {
        char msg[256];
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
        char msg[256];
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

    /* Push the new program into every open backend, then swap. The FPGA has
     * now been written, so we swap the daemon's view regardless; but a hard
     * programming fault (card drop / BAR error) is surfaced in the response so
     * the operator knows the FPGA may not match the loaded config. */
    pw_status prog_st = program_backends(new_prog, new_cfg, cards);

    pw_program_free(*prog_pp);
    pw_config_free(*cfg_pp);
    *cfg_pp  = new_cfg;
    *prog_pp = new_prog;

    if (prog_st != PW_OK)
        fprintf(stderr, "load: FPGA programming hard-failed (%s) -- "
                "config swapped but device may be out of sync\n", pw_strerror(prog_st));

    resp = json_object_new_object();
    json_object_object_add(resp, "ok", json_object_new_boolean(prog_st == PW_OK));
    if (prog_st != PW_OK)
        json_object_object_add(resp, "program_error",
                               json_object_new_string(pw_strerror(prog_st)));
    json_object_object_add(resp, "n_flows",
                           json_object_new_int((int)new_cfg->n_flows));
    {
        size_t total_rules = 0;
        for (size_t ci = 0; ci < new_prog->n_cards; ci++)
            total_rules += new_prog->per_card[ci].n_fc_rules;
        /* Key name matches the CLI + docs/design/rpc-protocol.md contract
         * (n_classifier_rows); a prior n_classifier_rules typo made the CLI
         * print 0 rows. */
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
    if (!m->latency_valid) {
        json_object_object_add(r, "id", json_object_new_int(flow_id));
        json_object_object_add(r, "latency_valid", json_object_new_boolean(false));
        json_object_object_add(r, "reason",
            json_object_new_string("cross-card flow; latency not supported"));
        return r;
    }
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
    (void)cards[rx_ci].backend.ops->stats_snapshot(cards[rx_ci].backend.ctx);
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
    for (size_t ci = 0; ci < cfg->n_cards; ci++) {
        if (cards[ci].open && cards[ci].backend.ops->stats_snapshot)
            (void)cards[ci].backend.ops->stats_snapshot(cards[ci].backend.ctx);
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
        if (rx_ci != (size_t)-1 && cards[rx_ci].open &&
            cards[rx_ci].backend.ops->flow_stats_read) {
            (void)cards[rx_ci].backend.ops->flow_stats_read(
                cards[rx_ci].backend.ctx, m->rx_local_flow_id, &rs);
        }
        if (tx_ci != (size_t)-1 && cards[tx_ci].open &&
            cards[tx_ci].backend.ops->flow_stats_read) {
            (void)cards[tx_ci].backend.ops->flow_stats_read(
                cards[tx_ci].backend.ctx, m->tx_local_flow_id, &ts);
        }

        struct json_object *f = json_object_new_object();
        json_object_object_add(f, "id", json_object_new_int64(m->global_flow_id));
        json_object_object_add(f, "tx_card_id", json_object_new_int(m->tx_card_id));
        json_object_object_add(f, "rx_card_id", json_object_new_int(m->rx_card_id));
        json_object_object_add(f, "tx_frames", json_object_new_int64((int64_t)ts.tx_frames));
        json_object_object_add(f, "tx_bytes",  json_object_new_int64((int64_t)ts.tx_bytes));
        json_object_object_add(f, "rx_frames", json_object_new_int64((int64_t)rs.rx_frames));
        json_object_object_add(f, "rx_bytes",  json_object_new_int64((int64_t)rs.rx_bytes));
        json_object_object_add(f, "lost",      json_object_new_int64((int64_t)rs.lost_packets_estimated));
        json_object_object_add(f, "duplicate", json_object_new_int64((int64_t)rs.duplicate_count));
        json_object_object_add(f, "out_of_order", json_object_new_int64((int64_t)rs.out_of_order_count));
        json_object_object_add(f, "seq_gap",   json_object_new_int64((int64_t)rs.sequence_gap_count));
        json_object_object_add(f, "expected_seq", json_object_new_int64((int64_t)rs.expected_sequence));

        json_object_object_add(f, "latency_valid",
                               json_object_new_boolean(m->latency_valid));
        if (m->latency_valid) {
            json_object_object_add(f, "min_latency", json_object_new_int64((int64_t)rs.min_latency));
            json_object_object_add(f, "max_latency", json_object_new_int64((int64_t)rs.max_latency));
            int64_t avg = rs.sample_count
                ? (int64_t)(rs.sum_latency / rs.sample_count)
                : 0;
            json_object_object_add(f, "avg_latency", json_object_new_int64(avg));
            json_object_object_add(f, "sample_count",
                                   json_object_new_int64((int64_t)rs.sample_count));
            json_object_object_add(f, "jitter_min", json_object_new_int64((int64_t)rs.jitter_min));
            json_object_object_add(f, "jitter_max", json_object_new_int64((int64_t)rs.jitter_max));
            int64_t jit_avg = rs.sample_count
                ? (int64_t)(rs.jitter_sum / rs.sample_count)
                : 0;
            json_object_object_add(f, "jitter_avg", json_object_new_int64(jit_avg));
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
                program_backends(prog, cfg, cards);
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
                char buf[16]; snprintf(buf, sizeof buf, "%02x %02x %02x", id[0], id[1], id[2]);
                resp = json_object_new_object();
                json_object_object_add(resp, "jedec_id", json_object_new_string(buf));
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
                    if (sz <= 0 || sz > (8 << 20)) { fclose(f); resp = build_error("bad file size"); }
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
    program_backends(prog, cfg, cards);
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
