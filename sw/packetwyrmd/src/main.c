/* packetwyrmd: Phase 0 skeleton.
 *
 * Loads / validates / compiles a config and prints what it would
 * program if a real card were attached. Phase 4 wires this skeleton up
 * to the real BAR backend; the fake backend already exercises the
 * full code path. */

#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "packetwyrm/packetwyrm.h"

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [-c CONFIG] [-n] [-v]\n"
        "  -c CONFIG   path to packetwyrm.yaml (default /etc/packetwyrm/packetwyrm.yaml)\n"
        "  -n          dry run: parse + validate + compile, print summary, exit\n"
        "  -v          verbose\n",
        prog);
}

static void print_summary(const struct pw_config *cfg, const struct pw_program *prog) {
    printf("packetwyrmd %s\n", pw_version_string());
    printf("system: %s (mode=%s, speed=%s)\n",
           cfg->system.name, cfg->system.mode, cfg->system.default_speed);
    printf("cards: %zu\n", cfg->n_cards);
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        printf("  card%u  %s  ports:", (unsigned)c->id, c->pci);
        for (size_t p = 0; p < c->n_ports; p++)
            printf(" %s(local=%u,global=%u)",
                   c->ports[p].name, c->ports[p].local_port, c->ports[p].global_port);
        printf("\n");
    }
    printf("logical_interfaces: %zu\n", cfg->n_logical_if);
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        const struct pw_logical_if *l = &cfg->logical_if[i];
        printf("  lif id=%u name=%s gport=%u vlan=%u\n",
               l->id, l->name, l->global_port, l->vlan);
    }
    printf("flows: %zu\n", cfg->n_flows);
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        printf("  flow id=%u tx=p%u(card%u) rx=p%u(card%u) latency_valid=%s\n",
               f->id, f->tx_global_port, m->tx_card_id,
               f->rx_global_port, m->rx_card_id,
               m->latency_valid ? "yes" : "no (cross-card)");
    }
    for (size_t i = 0; i < prog->n_cards; i++) {
        printf("  program card%u: %zu classifier rows, %zu flow rows\n",
               prog->per_card[i].card_id,
               prog->per_card[i].n_classifier_rows,
               prog->per_card[i].n_flow_rows);
    }
}

int main(int argc, char **argv) {
    const char *cfg_path = "/etc/packetwyrm/packetwyrm.yaml";
    bool dry_run = false;
    bool verbose = false;

    int opt;
    while ((opt = getopt(argc, argv, "c:nvh")) != -1) {
        switch (opt) {
        case 'c': cfg_path = optarg; break;
        case 'n': dry_run = true; break;
        case 'v': verbose = true; break;
        case 'h': default: usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }

    struct pw_config *cfg = pw_config_new();
    if (!cfg) { fprintf(stderr, "out of memory\n"); return 1; }
    struct pw_diag diag = {0};
    pw_status r = pw_config_parse_file(cfg_path, cfg, &diag);
    if (r != PW_OK) {
        fprintf(stderr, "config parse failed: %s\n  at %s: %s\n",
                pw_strerror(r), diag.path, diag.message);
        pw_config_free(cfg);
        return 1;
    }
    r = pw_config_validate(cfg, &diag);
    if (r != PW_OK) {
        fprintf(stderr, "config invalid: %s\n  at %s: %s\n",
                pw_strerror(r), diag.path, diag.message);
        pw_config_free(cfg);
        return 1;
    }

    struct pw_program *prog = pw_program_new();
    r = pw_flow_compile(cfg, prog, &diag);
    if (r != PW_OK) {
        fprintf(stderr, "flow compile failed: %s\n  at %s: %s\n",
                pw_strerror(r), diag.path, diag.message);
        pw_program_free(prog);
        pw_config_free(cfg);
        return 1;
    }

    if (verbose || dry_run) print_summary(cfg, prog);

    if (dry_run) {
        pw_program_free(prog);
        pw_config_free(cfg);
        return 0;
    }

    /* Phase 0/4 stop here: for each declared card, prefer the real
     * BAR backend; fall back to the fake backend if the card is not
     * present (or unreadable). The full event loop / control socket
     * land in Phase 5. */
    for (size_t i = 0; i < cfg->n_cards; i++) {
        struct pw_card_backend b;
        const char *which = "bar";
        pw_status br = pw_bar_backend_open(cfg->cards[i].pci, &b);
        if (br != PW_OK) {
            which = "fake";
            br = pw_fake_backend_open(cfg->cards[i].pci, &b);
        }
        if (br != PW_OK) {
            fprintf(stderr, "could not open backend for %s: %s\n",
                    cfg->cards[i].pci, pw_strerror(br));
            continue;
        }
        struct pw_card_info info = {0};
        b.ops->card_info(b.ctx, &info);
        printf("  card%u %-14s backend=%s device_id=0x%08x flows=%u caps=0x%08x\n",
               (unsigned)cfg->cards[i].id, cfg->cards[i].pci, which,
               info.device_id, info.num_local_flows, info.capabilities);
        pw_card_backend_close(&b);
    }

    pw_program_free(prog);
    pw_config_free(cfg);
    fprintf(stderr,
            "packetwyrmd: Phase 4 startup complete; long-running event loop ships in Phase 5.\n");
    return 0;
}
