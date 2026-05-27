/* pktwyrm: Phase 0 CLI skeleton.
 *
 * Subcommands operate offline against a YAML configuration. Phase 4+
 * connects them to packetwyrmd over the control socket. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <json-c/json.h>

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

/* Send one RPC request, return the raw response in `resp` (size in
 * `*out_len`). 0 on success, -1 on failure. */
static int rpc_call(const char *sock, const char *json_req,
                    char *resp, size_t resp_cap, size_t *out_len) {
    int fd = -1;
    if (pw_ipc_connect(sock, &fd) != PW_OK) return -1;
    int rc = -1;
    if (pw_ipc_write_frame(fd, json_req, strlen(json_req)) == PW_OK &&
        pw_ipc_read_frame(fd, resp, resp_cap, out_len) == PW_OK) {
        rc = 0;
    }
    close(fd);
    return rc;
}

/* Pretty-print the "stats" response. Falls back to printing the
 * raw JSON if the structure isn't what we expect. */
static void pretty_print_stats(const char *json, size_t len) {
    struct json_tokener *tok = json_tokener_new();
    struct json_object *root = json_tokener_parse_ex(tok, json, (int)len);
    json_tokener_free(tok);
    if (!root) { printf("%.*s\n", (int)len, json); return; }

    struct json_object *err;
    if (json_object_object_get_ex(root, "error", &err)) {
        printf("error: %s\n", json_object_get_string(err));
        json_object_put(root);
        return;
    }
    struct json_object *arr;
    if (!json_object_object_get_ex(root, "stats", &arr) ||
        json_object_get_type(arr) != json_type_array) {
        printf("%.*s\n", (int)len, json);
        json_object_put(root);
        return;
    }

    printf("%-5s %-7s %-8s %12s %12s %12s %12s %12s\n",
           "card", "open", "backend",
           "punt_ok", "punt_drop", "inject_ok", "inject_drop", "unk_lif");
    size_t n = json_object_array_length(arr);
    for (size_t i = 0; i < n; i++) {
        struct json_object *c = json_object_array_get_idx(arr, i);
        struct json_object *v;
        int    id = 0; bool open = false;
        const char *be = "?";
        int64_t pok=0, pdrop=0, tok2=0, tdrop=0, unk=0;
        if (json_object_object_get_ex(c, "card_id", &v))           id    = json_object_get_int(v);
        if (json_object_object_get_ex(c, "open", &v))              open  = json_object_get_boolean(v);
        if (json_object_object_get_ex(c, "backend", &v))           be    = json_object_get_string(v);
        if (json_object_object_get_ex(c, "punt_to_tap_ok", &v))    pok   = json_object_get_int64(v);
        if (json_object_object_get_ex(c, "punt_to_tap_dropped", &v))pdrop= json_object_get_int64(v);
        if (json_object_object_get_ex(c, "tap_to_fpga_ok", &v))    tok2  = json_object_get_int64(v);
        if (json_object_object_get_ex(c, "tap_to_fpga_dropped", &v))tdrop= json_object_get_int64(v);
        if (json_object_object_get_ex(c, "punt_unknown_lif", &v))  unk   = json_object_get_int64(v);
        printf("%-5d %-7s %-8s %12ld %12ld %12ld %12ld %12ld\n",
               id, open ? "yes" : "no", be,
               (long)pok, (long)pdrop, (long)tok2, (long)tdrop, (long)unk);
    }
    json_object_put(root);
}

static int cmd_stats(int argc, char **argv) {
    /* pktwyrm stats [--socket PATH] [--card N] [--watch MS] [--json] */
    const char *sock = PW_IPC_DEFAULT_PATH;
    int  card = -1;
    int  watch_ms = 0;
    bool raw = false;

    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--card") && i + 1 < argc) card = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--watch") && i + 1 < argc) watch_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--json")) raw = true;
    }

    char req[128];
    if (card >= 0) snprintf(req, sizeof(req), "{\"rpc\":\"stats\",\"card\":%d}", card);
    else           snprintf(req, sizeof(req), "{\"rpc\":\"stats\"}");

    do {
        char   resp[PW_IPC_FRAME_MAX];
        size_t got = 0;
        if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
            fprintf(stderr, "rpc call failed (socket=%s)\n", sock);
            return 1;
        }
        if (watch_ms > 0) printf("\033[2J\033[H");  /* clear screen */
        if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); }
        else     pretty_print_stats(resp, got);
        if (watch_ms > 0) {
            struct timespec ts = { watch_ms / 1000, (watch_ms % 1000) * 1000000L };
            nanosleep(&ts, NULL);
        }
    } while (watch_ms > 0);
    return 0;
}

static int cmd_rpc(int argc, char **argv) {
    /* pktwyrm rpc <method> [--socket PATH] [--card N] */
    const char *method = NULL;
    const char *sock   = PW_IPC_DEFAULT_PATH;
    int card_id        = -1;

    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock = argv[++i];
        } else if (!strcmp(argv[i], "--card") && i + 1 < argc) {
            card_id = atoi(argv[++i]);
        } else if (!method) {
            method = argv[i];
        }
    }
    if (!method) {
        fprintf(stderr,
            "usage: pktwyrm rpc <version|cards|ports|flows|stats> "
            "[--socket PATH] [--card N]\n");
        return 2;
    }

    int fd = -1;
    pw_status r = pw_ipc_connect(sock, &fd);
    if (r != PW_OK) {
        fprintf(stderr, "cannot connect to %s: %s\n", sock, pw_strerror(r));
        return 1;
    }
    char req[256];
    int rlen;
    if (card_id >= 0) {
        rlen = snprintf(req, sizeof(req),
                        "{\"rpc\":\"%s\",\"card\":%d}", method, card_id);
    } else {
        rlen = snprintf(req, sizeof(req), "{\"rpc\":\"%s\"}", method);
    }
    if (rlen < 0 || (size_t)rlen >= sizeof(req)) { close(fd); return 1; }
    if (pw_ipc_write_frame(fd, req, (size_t)rlen) != PW_OK) {
        fprintf(stderr, "write failed\n");
        close(fd);
        return 1;
    }
    char  resp[PW_IPC_FRAME_MAX];
    size_t got = 0;
    r = pw_ipc_read_frame(fd, resp, sizeof(resp), &got);
    close(fd);
    if (r != PW_OK) {
        fprintf(stderr, "read failed: %s\n", pw_strerror(r));
        return 1;
    }
    fwrite(resp, 1, got, stdout);
    fputc('\n', stdout);
    return 0;
}

static int cmd_help(void) {
    puts("pktwyrm - PacketWyrm CLI");
    puts("");
    puts("Offline commands (operate on a YAML file):");
    puts("  pktwyrm cards                        discover real PacketWyrm PCI cards");
    puts("  pktwyrm cards <config.yaml>          list configured cards from YAML");
    puts("  pktwyrm ports <config.yaml>          list configured ports");
    puts("  pktwyrm map   <config.yaml>          show port -> logical-if map");
    puts("  pktwyrm load  <config.yaml>          parse + validate + compile");
    puts("  pktwyrm flow show <config.yaml>      list flows");
    puts("  pktwyrm version");
    puts("");
    puts("Online (talks to a running packetwyrmd over a Unix socket):");
    puts("  pktwyrm rpc version");
    puts("  pktwyrm rpc cards|ports|flows|stats [--socket PATH] [--card N]");
    puts("  pktwyrm stats [--socket PATH] [--card N] [--watch MS] [--json]");
    puts("  pktwyrm flow start|stop <id> [--socket PATH]");
    puts("  pktwyrm flow stats [--flow N] [--socket PATH] [--watch MS] [--json]");
    puts("  pktwyrm test arm|start|stop [--socket PATH]");
    puts("  pktwyrm hist latency --flow N [--socket PATH]");
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
    if (!strcmp(sub, "rpc"))    return cmd_rpc(argc - 2, argv + 2);
    if (!strcmp(sub, "stats"))  return cmd_stats(argc - 2, argv + 2);
    if (!strcmp(sub, "hist")) {
        if (argc < 4 || strcmp(argv[2], "latency")) {
            fprintf(stderr,
                "usage: pktwyrm hist latency --flow N [--socket PATH]\n");
            return 2;
        }
        const char *sock = PW_IPC_DEFAULT_PATH;
        int flow_id = -1;
        for (int i = 3; i < argc; i++) {
            if (!strcmp(argv[i], "--flow") && i + 1 < argc) flow_id = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        }
        if (flow_id < 0) { fprintf(stderr, "--flow required\n"); return 2; }
        char req[128];
        snprintf(req, sizeof(req), "{\"rpc\":\"flow.hist\",\"id\":%d}", flow_id);
        char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
        if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
            fprintf(stderr, "rpc call failed\n"); return 1;
        }
        /* Pretty-print: parse the bucket array and draw a small
         * text bar chart. */
        struct json_tokener *tok = json_tokener_new();
        struct json_object  *root = json_tokener_parse_ex(tok, resp, (int)got);
        json_tokener_free(tok);
        if (!root) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); return 0; }
        struct json_object *err;
        if (json_object_object_get_ex(root, "error", &err)) {
            printf("error: %s\n", json_object_get_string(err));
            json_object_put(root); return 1;
        }
        struct json_object *lv;
        if (json_object_object_get_ex(root, "latency_valid", &lv) &&
            !json_object_get_boolean(lv)) {
            struct json_object *reason;
            json_object_object_get_ex(root, "reason", &reason);
            printf("flow %d: latency not valid (%s)\n", flow_id,
                   reason ? json_object_get_string(reason) : "");
            json_object_put(root); return 0;
        }
        struct json_object *arr;
        if (!json_object_object_get_ex(root, "buckets", &arr) ||
            json_object_get_type(arr) != json_type_array) {
            fwrite(resp, 1, got, stdout); fputc('\n', stdout);
            json_object_put(root); return 0;
        }
        size_t n = json_object_array_length(arr);
        uint64_t maxv = 0;
        for (size_t i = 0; i < n; i++) {
            int64_t v = json_object_get_int64(json_object_array_get_idx(arr, i));
            if ((uint64_t)v > maxv) maxv = (uint64_t)v;
        }
        printf("flow %d latency histogram (log2 buckets, %zu bins)\n",
               flow_id, n);
        for (size_t i = 0; i < n; i++) {
            int64_t v = json_object_get_int64(json_object_array_get_idx(arr, i));
            int     bar = (maxv > 0) ? (int)((uint64_t)v * 40 / maxv) : 0;
            char    line[64];
            int j;
            for (j = 0; j < bar && j < 40; j++) line[j] = '#';
            line[j] = '\0';
            printf("  [%2zu] (>= %lu ns) %10ld  %s\n",
                   i, (unsigned long)(1ULL << i), (long)v, line);
        }
        json_object_put(root);
        return 0;
    }
    if (!strcmp(sub, "test")) {
        if (argc < 3) {
            fprintf(stderr,
                "usage: pktwyrm test arm|start|stop [--socket PATH]\n");
            return 2;
        }
        const char *action = argv[2];
        if (strcmp(action, "arm") && strcmp(action, "start") && strcmp(action, "stop")) {
            fprintf(stderr, "unknown test action: %s\n", action); return 2;
        }
        const char *sock = PW_IPC_DEFAULT_PATH;
        for (int i = 3; i < argc; i++)
            if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        char req[128];
        snprintf(req, sizeof(req), "{\"rpc\":\"test.%s\"}", action);
        char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
        if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
            fprintf(stderr, "rpc call failed (socket=%s)\n", sock);
            return 1;
        }
        fwrite(resp, 1, got, stdout); fputc('\n', stdout);
        return 0;
    }
    if (!strcmp(sub, "flow")) {
        if (argc < 3) {
            fprintf(stderr,
                "usage: pktwyrm flow show <config.yaml>\n"
                "       pktwyrm flow start <id> [--socket PATH]\n"
                "       pktwyrm flow stop  <id> [--socket PATH]\n");
            return 2;
        }
        const char *what = argv[2];
        if (!strcmp(what, "show")) return cmd_flow_show(argc - 3, argv + 3);
        if (!strcmp(what, "stats")) {
            const char *sock = PW_IPC_DEFAULT_PATH;
            int  id = -1;
            int  watch_ms = 0;
            bool raw = false;
            for (int i = 3; i < argc; i++) {
                if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
                else if (!strcmp(argv[i], "--flow") && i + 1 < argc) id = atoi(argv[++i]);
                else if (!strcmp(argv[i], "--watch") && i + 1 < argc) watch_ms = atoi(argv[++i]);
                else if (!strcmp(argv[i], "--json")) raw = true;
            }
            char req[128];
            if (id >= 0) snprintf(req, sizeof(req), "{\"rpc\":\"flow.stats\",\"id\":%d}", id);
            else         snprintf(req, sizeof(req), "{\"rpc\":\"flow.stats\"}");
            do {
                char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
                if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
                    fprintf(stderr, "rpc call failed (socket=%s)\n", sock);
                    return 1;
                }
                if (watch_ms > 0) printf("\033[2J\033[H");
                if (raw) {
                    fwrite(resp, 1, got, stdout); fputc('\n', stdout);
                } else {
                    struct json_tokener *tok = json_tokener_new();
                    struct json_object  *root = json_tokener_parse_ex(tok, resp, (int)got);
                    json_tokener_free(tok);
                    struct json_object  *arr = NULL;
                    if (!root || !json_object_object_get_ex(root, "flows", &arr) ||
                        json_object_get_type(arr) != json_type_array) {
                        fwrite(resp, 1, got, stdout); fputc('\n', stdout);
                        if (root) json_object_put(root);
                    } else {
                        printf("%-4s %-5s %-5s %10s %10s %8s %8s %8s %10s %10s %10s %s\n",
                               "id", "tx_c", "rx_c", "tx_frames", "rx_frames",
                               "lost", "dup", "reord",
                               "min_lat", "avg_lat", "max_lat", "lat_valid");
                        size_t n = json_object_array_length(arr);
                        for (size_t i = 0; i < n; i++) {
                            struct json_object *f = json_object_array_get_idx(arr, i);
                            struct json_object *v;
                            int64_t fid=0,tc=0,rc=0,tx=0,rx=0,lost=0,dup=0,reord=0;
                            int64_t mn=0,mx=0,avg=0; bool lv=false;
                            #define GETI(k, dst) do { if (json_object_object_get_ex(f, k, &v)) dst = json_object_get_int64(v); } while(0)
                            #define GETB(k, dst) do { if (json_object_object_get_ex(f, k, &v)) dst = json_object_get_boolean(v); } while(0)
                            GETI("id", fid);
                            GETI("tx_card_id", tc);
                            GETI("rx_card_id", rc);
                            GETI("tx_frames", tx);
                            GETI("rx_frames", rx);
                            GETI("lost", lost);
                            GETI("duplicate", dup);
                            GETI("out_of_order", reord);
                            GETI("min_latency", mn);
                            GETI("max_latency", mx);
                            GETI("avg_latency", avg);
                            GETB("latency_valid", lv);
                            #undef GETI
                            #undef GETB
                            printf("%-4ld %-5ld %-5ld %10ld %10ld %8ld %8ld %8ld %10ld %10ld %10ld %s\n",
                                   (long)fid, (long)tc, (long)rc,
                                   (long)tx, (long)rx,
                                   (long)lost, (long)dup, (long)reord,
                                   lv ? (long)mn : 0,
                                   lv ? (long)avg : 0,
                                   lv ? (long)mx : 0,
                                   lv ? "yes" : "no");
                        }
                        json_object_put(root);
                    }
                }
                if (watch_ms > 0) {
                    struct timespec ts = { watch_ms / 1000, (watch_ms % 1000) * 1000000L };
                    nanosleep(&ts, NULL);
                }
            } while (watch_ms > 0);
            return 0;
        }
        if (!strcmp(what, "start") || !strcmp(what, "stop")) {
            if (argc < 4) {
                fprintf(stderr, "usage: pktwyrm flow %s <id> [--socket PATH]\n", what);
                return 2;
            }
            int id = atoi(argv[3]);
            const char *sock = PW_IPC_DEFAULT_PATH;
            for (int i = 4; i < argc; i++) {
                if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
            }
            char req[128];
            snprintf(req, sizeof(req), "{\"rpc\":\"flow.%s\",\"id\":%d}", what, id);
            char  resp[PW_IPC_FRAME_MAX];
            size_t got = 0;
            if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
                fprintf(stderr, "rpc call failed (socket=%s)\n", sock);
                return 1;
            }
            fwrite(resp, 1, got, stdout); fputc('\n', stdout);
            return 0;
        }
        fprintf(stderr, "unknown flow subcommand: %s\n", what);
        return 2;
    }
    fprintf(stderr, "unknown subcommand: %s\n", sub);
    return cmd_help();
}
