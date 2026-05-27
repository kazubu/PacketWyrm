/* pktwyrm: Phase 0 CLI skeleton.
 *
 * Subcommands operate offline against a YAML configuration. Phase 4+
 * connects them to packetwyrmd over the control socket. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "packetwyrm/packetwyrm.h"

static int cmd_help(void);

static int load_config(const char *path, struct pw_config **out_cfg,
                       struct pw_program **out_prog) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag diag = {0};
    if (pw_config_parse_file(path, cfg, &diag) != PW_OK) {
        fprintf(stderr, "parse error at %s: %s\n", diag.path, diag.message);
        pw_config_free(cfg);
        return -1;
    }
    if (pw_config_validate(cfg, &diag) != PW_OK) {
        fprintf(stderr, "invalid config at %s: %s\n", diag.path, diag.message);
        pw_config_free(cfg);
        return -1;
    }
    struct pw_program *prog = pw_program_new();
    if (pw_flow_compile(cfg, prog, &diag) != PW_OK) {
        fprintf(stderr, "compile error at %s: %s\n", diag.path, diag.message);
        pw_program_free(prog); pw_config_free(cfg);
        return -1;
    }
    *out_cfg = cfg;
    *out_prog = prog;
    return 0;
}

static int cmd_cards(int argc, char **argv) {
    if (argc < 1) {
        /* No config: discover real PacketWyrm cards via PCI sysfs. */
        struct pw_pci_device devs[PW_MAX_CARDS] = {0};
        int n = pw_pci_discover(PW_DEFAULT_PCI_VENDOR, PW_DEFAULT_PCI_DEVICE,
                                devs, PW_MAX_CARDS);
        if (n < 0) {
            fprintf(stderr, "PCI discovery failed: %s\n", pw_strerror((pw_status)n));
            return 1;
        }
        if (n == 0) {
            printf("No PacketWyrm cards found (vendor=0x%04x device=0x%04x).\n",
                   PW_DEFAULT_PCI_VENDOR, PW_DEFAULT_PCI_DEVICE);
            printf("  (Pass a YAML config to inspect a configured card map instead.)\n");
            return 0;
        }
        printf("ID  PCI BDF        Vendor:Device  Subsys         Status\n");
        for (int i = 0; i < n && i < PW_MAX_CARDS; i++) {
            struct pw_card_backend b;
            const char *st = "ready";
            pw_status r = pw_bar_backend_open(devs[i].bdf, &b);
            uint32_t dev_id = 0;
            if (r == PW_OK) {
                b.ops->read32(b.ctx, PWFPGA_REG_DEVICE_ID, &dev_id);
                pw_card_backend_close(&b);
                if (dev_id != 0xA502BEEFu) st = "wrong-id";
            } else {
                st = "noaccess";
            }
            printf("%-3d %-14s %04x:%04x      %04x:%04x      %s\n",
                   i, devs[i].bdf, devs[i].vendor, devs[i].device,
                   devs[i].subsystem_vendor, devs[i].subsystem_device, st);
        }
        if (n > PW_MAX_CARDS) {
            printf("  (%d more cards not shown; PW_MAX_CARDS=%d)\n",
                   n - PW_MAX_CARDS, PW_MAX_CARDS);
        }
        return 0;
    }
    struct pw_config *cfg; struct pw_program *prog;
    if (load_config(argv[0], &cfg, &prog) < 0) return 1;
    printf("ID  PCI BDF        Name   FW       Status    Ports\n");
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        printf("%-3u %-14s %-6s %-8s %-9s ",
               (unsigned)c->id, c->pci, c->name, "0.1.0", "config");
        for (size_t p = 0; p < c->n_ports; p++)
            printf("%s%s", c->ports[p].name, p + 1 < c->n_ports ? "," : "");
        printf("\n");
    }
    pw_program_free(prog); pw_config_free(cfg);
    return 0;
}

static int cmd_ports(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: pktwyrm ports <config.yaml>\n");
        return 2;
    }
    struct pw_config *cfg; struct pw_program *prog;
    if (load_config(argv[0], &cfg, &prog) < 0) return 1;
    printf("Port  Card  Local  Link  Speed  TX Gbps  RX Gbps\n");
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        for (size_t p = 0; p < c->n_ports; p++) {
            printf("%-5s %-5u %-6u %-5s %-6s %-8s %-8s\n",
                   c->ports[p].name, (unsigned)c->id, c->ports[p].local_port,
                   "?", "10G", "0.00", "0.00");
        }
    }
    pw_program_free(prog); pw_config_free(cfg);
    return 0;
}

static int cmd_map(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: pktwyrm map <config.yaml>\n"); return 2; }
    struct pw_config *cfg; struct pw_program *prog;
    if (load_config(argv[0], &cfg, &prog) < 0) return 1;
    printf("global_port  card.local_port  logical_interface(s)\n");
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        for (size_t p = 0; p < c->n_ports; p++) {
            printf("  %-10s card%u.%u           ",
                   c->ports[p].name, (unsigned)c->id, c->ports[p].local_port);
            int first = 1;
            for (size_t li = 0; li < cfg->n_logical_if; li++) {
                if (cfg->logical_if[li].global_port == c->ports[p].global_port) {
                    if (!first) printf(", ");
                    printf("%s(id=%u,vlan=%u)",
                           cfg->logical_if[li].name,
                           cfg->logical_if[li].id,
                           cfg->logical_if[li].vlan);
                    first = 0;
                }
            }
            if (first) printf("(none)");
            printf("\n");
        }
    }
    pw_program_free(prog); pw_config_free(cfg);
    return 0;
}

static int cmd_load(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: pktwyrm load <config.yaml>\n"); return 2; }
    struct pw_config *cfg; struct pw_program *prog;
    if (load_config(argv[0], &cfg, &prog) < 0) return 1;
    printf("Configuration OK: %zu cards, %zu logical interfaces, %zu flows.\n",
           cfg->n_cards, cfg->n_logical_if, cfg->n_flows);
    for (size_t i = 0; i < prog->n_cards; i++)
        printf("  card%u program: %zu classifier rows, %zu flow rows\n",
               prog->per_card[i].card_id,
               prog->per_card[i].n_classifier_rows,
               prog->per_card[i].n_flow_rows);
    pw_program_free(prog); pw_config_free(cfg);
    return 0;
}

static int cmd_flow_show(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: pktwyrm flow show <config.yaml>\n"); return 2; }
    struct pw_config *cfg; struct pw_program *prog;
    if (load_config(argv[0], &cfg, &prog) < 0) return 1;
    printf("ID   TX   RX   LatencyValid  Name\n");
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        const struct pw_flow_meta *m = &prog->flow_meta[i];
        printf("%-4u p%-3u p%-3u %-13s %s\n",
               f->id, f->tx_global_port, f->rx_global_port,
               m->latency_valid ? "yes" : "no",
               f->name[0] ? f->name : "(unnamed)");
    }
    pw_program_free(prog); pw_config_free(cfg);
    return 0;
}

static int cmd_help(void) {
    puts("pktwyrm - PacketWyrm CLI");
    puts("");
    puts("Commands:");
    puts("  pktwyrm cards                        discover real PacketWyrm PCI cards");
    puts("  pktwyrm cards <config.yaml>          list configured cards from YAML");
    puts("  pktwyrm ports <config.yaml>          list configured ports");
    puts("  pktwyrm map   <config.yaml>          show port -> logical-if map");
    puts("  pktwyrm load  <config.yaml>          parse + validate + compile");
    puts("  pktwyrm flow show <config.yaml>      list flows");
    puts("  pktwyrm version");
    puts("");
    puts("Online stats / flow start / test orchestration ship in Phase 5+.");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return cmd_help();
    const char *sub = argv[1];
    if (!strcmp(sub, "help") || !strcmp(sub, "-h") || !strcmp(sub, "--help")) return cmd_help();
    if (!strcmp(sub, "version") || !strcmp(sub, "--version")) {
        printf("pktwyrm %s\n", pw_version_string()); return 0;
    }
    if (!strcmp(sub, "cards"))  return cmd_cards(argc - 2, argv + 2);
    if (!strcmp(sub, "ports"))  return cmd_ports(argc - 2, argv + 2);
    if (!strcmp(sub, "map"))    return cmd_map(argc - 2, argv + 2);
    if (!strcmp(sub, "load"))   return cmd_load(argc - 2, argv + 2);
    if (!strcmp(sub, "flow")) {
        if (argc < 3 || strcmp(argv[2], "show")) {
            fprintf(stderr, "usage: pktwyrm flow show <config.yaml>\n"); return 2;
        }
        return cmd_flow_show(argc - 3, argv + 3);
    }
    fprintf(stderr, "unknown subcommand: %s\n", sub);
    return cmd_help();
}
