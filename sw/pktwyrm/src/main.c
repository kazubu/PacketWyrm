/* pktwyrm: Phase 0 CLI skeleton.
 *
 * Subcommands operate offline against a YAML configuration. Phase 4+
 * connects them to packetwyrmd over the control socket. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   /* strncasecmp */
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <netdb.h>
#include <sys/socket.h>

#include <json-c/json.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#include "packetwyrm/packetwyrm.h"
#include "packetwyrm/vfio.h"        /* pw_vfio_bind */
#include "packetwyrm/spi_flash.h"  /* pw_flash_program (firmware update) */

/* The FPGA's latency counters and histogram buckets are in data-plane
 * clock ticks (the free-running timestamp runs at PWFPGA_DATA_PLANE_CLOCK_HZ
 * = 156.25 MHz, i.e. 6.4 ns/tick). Convert to nanoseconds for display. */
static inline unsigned long pw_ticks_to_ns(unsigned long long ticks) {
    return (unsigned long)(ticks * 1000000000ULL / PWFPGA_DATA_PLANE_CLOCK_HZ);
}

static int cmd_help(void);

/* --- control-socket secret (access control) --------------------------------
 * The daemon requires a matching secret when the environment config sets one.
 * Resolution precedence: --secret ARG  >  $PACKETWYRM_SECRET  >  the `secret`
 * key of the environment config (--env PATH, default /etc/packetwyrm/
 * packetwyrm.yaml). Read permission on that file is thus the access gate. */
static const char *g_secret_arg = NULL;   /* --secret */
static const char *g_env_arg    = NULL;   /* --env */
/* errno from the last failed local-socket connect (pw_ipc_connect preserves
 * it across its close()), so rpc_fail() can print an actionable hint instead
 * of the opaque "rpc call failed". 0 when the failure wasn't a connect. */
static int g_last_connect_errno = 0;
/* --host HOST[:PORT]: talk to a remote packetwyrm-proxyd over HTTPS instead
 * of the local Unix socket. All RPCs then go through POST /api/rpc. */
static const char *g_host_arg   = NULL;

static const char *resolve_secret(void) {
    static char cache[PW_SECRET_MAX];
    static int  done = 0;
    if (done) return cache;
    done = 1;
    cache[0] = '\0';
    if (g_secret_arg) { snprintf(cache, sizeof(cache), "%s", g_secret_arg); return cache; }
    const char *env = getenv("PACKETWYRM_SECRET");
    if (env && env[0]) { snprintf(cache, sizeof(cache), "%s", env); return cache; }
    const char *path = g_env_arg ? g_env_arg : "/etc/packetwyrm/packetwyrm.yaml";
    struct pw_config *c = pw_config_new();
    if (c && pw_config_parse_file(path, c, NULL) == PW_OK)
        snprintf(cache, sizeof(cache), "%s", c->system.secret);
    pw_config_free(c);
    return cache;   /* "" if unreadable / no secret -> daemon may reject */
}

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

static int rpc_call(const char *sock, const char *json_req,
                    char *resp, size_t resp_cap, size_t *out_len);
static void rpc_fail(const char *sock);

/* Read an entire file into a newly allocated buffer. Caller frees. */
static char *slurp_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return NULL; }
    long sz = ftell(fp);
    if (sz < 0) { fclose(fp); return NULL; }
    rewind(fp);
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(fp); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    buf[got] = '\0';
    if (out_len) *out_len = got;
    return buf;
}

static int cmd_load(int argc, char **argv) {
    const char *path = NULL;
    const char *sock = NULL;
    bool check_only = false;   /* --check / -n: offline validate, do not deploy */
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--check") || !strcmp(argv[i], "-n")) check_only = true;
        else if ((!strcmp(argv[i], "--env") || !strcmp(argv[i], "--secret")) && i + 1 < argc)
            i++;                                  /* global flags, consumed in main */
        else if (!path) path = argv[i];
    }
    if (!path) {
        fprintf(stderr,
                "usage: pktwyrm load <config.yaml> [--socket PATH] [--check]\n"
                "  Deploys to the running daemon by default (socket %s);\n"
                "  --check validates the file offline without deploying.\n",
                g_host_arg ? "via --host" : PW_IPC_DEFAULT_PATH);
        return 2;
    }
    /* Deploy by default -- `load` means "load into the running daemon". Use the
     * default control socket unless --socket / --host overrides it; --check does
     * the offline validate only. (Historically load was offline-only unless
     * --socket was given, which silently did nothing to a running daemon.) */
    if (!sock && !g_host_arg) sock = PW_IPC_DEFAULT_PATH;

    /* Offline syntax check before opening the socket. The file may be a full
     * combined config (system+cards+flows) OR a test-only config (flows/forwards
     * only -- the normal `load` payload). Try full first (compile + summary);
     * if that fails only because system/cards are absent, fall back to a
     * test-only parse (syntax only -- there are no cards here to compile
     * against; the daemon validates + compiles against its environment). */
    struct pw_diag d = {0};
    struct pw_config *cfg = pw_config_new();
    if (pw_config_parse_file(path, cfg, &d) == PW_OK) {
        /* Full combined config: validate + compile + summary. */
        struct pw_program *prog = pw_program_new();
        if (pw_config_validate(cfg, &d) != PW_OK) {
            fprintf(stderr, "invalid config at %s: %s\n", d.path, d.message);
            pw_program_free(prog); pw_config_free(cfg); return 1;
        }
        if (pw_flow_compile(cfg, prog, &d) != PW_OK) {
            fprintf(stderr, "compile error at %s: %s\n", d.path, d.message);
            pw_program_free(prog); pw_config_free(cfg); return 1;
        }
        printf("Configuration OK: %zu cards, %zu logical interfaces, %zu flows.\n",
               cfg->n_cards, cfg->n_logical_if, cfg->n_flows);
        for (size_t i = 0; i < prog->n_cards; i++)
            printf("  card%u program: %zu flow rows, %zu map entries, "
                   "%zu cmp/%zu udf/%zu rules\n",
                   prog->per_card[i].card_id,
                   prog->per_card[i].n_flow_rows,
                   prog->per_card[i].n_map_entries,
                   prog->per_card[i].n_fc_cmps,
                   prog->per_card[i].n_fc_udfs,
                   prog->per_card[i].n_fc_rules);
        pw_program_free(prog); pw_config_free(cfg);
    } else {
        /* Not a full config -> try test-only (flows/forwards, no cards to
         * compile against; the daemon validates against its environment). */
        pw_config_free(cfg);
        struct pw_config *t = pw_config_new();
        struct pw_diag dt = {0};
        if (pw_config_parse_file_ex(path, PW_CFG_TEST_ONLY, t, &dt) != PW_OK) {
            fprintf(stderr, "parse error at %s: %s\n", dt.path, dt.message);
            pw_config_free(t);
            return 1;
        }
        printf("Test config OK: %zu flows, %zu forwards "
               "(validated against the daemon's environment on load).\n",
               t->n_flows, t->n_forwards);
        pw_config_free(t);
    }

    if (check_only) {
        printf("(--check: validated offline, not deployed)\n");
        return 0;
    }
    if (!sock && !g_host_arg) return 0;   /* nothing to deploy to (shouldn't happen) */

    /* Live deploy: ship the YAML body to the running daemon (Unix socket, or a
     * remote gateway when --host is set -- rpc_call routes on g_host_arg). */
    size_t yaml_len = 0;
    char  *yaml = slurp_file(path, &yaml_len);
    if (!yaml) { fprintf(stderr, "cannot read %s\n", path); return 1; }

    struct json_object *req = json_object_new_object();
    json_object_object_add(req, "rpc",  json_object_new_string("config.load"));
    json_object_object_add(req, "yaml", json_object_new_string_len(yaml, (int)yaml_len));
    const char *req_str = json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN);

    char resp_buf[PW_IPC_FRAME_MAX];
    size_t resp_len = 0;
    const char *dest = g_host_arg ? g_host_arg : sock;
    int rc = rpc_call(sock, req_str, resp_buf, sizeof(resp_buf), &resp_len);
    json_object_put(req);
    free(yaml);
    if (rc != 0) {
        rpc_fail(sock);
        return 1;
    }
    struct json_tokener *tok = json_tokener_new();
    struct json_object  *resp = json_tokener_parse_ex(tok, resp_buf, (int)resp_len);
    json_tokener_free(tok);
    if (!resp) { fprintf(stderr, "invalid daemon response\n"); return 1; }

    struct json_object *jerr;
    if (json_object_object_get_ex(resp, "error", &jerr)) {
        fprintf(stderr, "daemon rejected reload: %s\n",
                json_object_get_string(jerr));
        json_object_put(resp);
        return 1;
    }
    struct json_object *jflows, *jcls;
    int nflows = 0, ncls = 0;
    if (json_object_object_get_ex(resp, "n_flows",          &jflows)) nflows = json_object_get_int(jflows);
    if (json_object_object_get_ex(resp, "n_classifier_rows",&jcls))   ncls   = json_object_get_int(jcls);
    printf("Deployed to %s: %d flows, %d classifier rows.\n",
           dest, nflows, ncls);
    json_object_put(resp);
    return 0;
}

/* ---- Generated-frame preview -------------------------------------------
 * Build the on-wire frame a flow's generator emits, mirroring the RTL layout
 * in pw_flow_gen_multi.sv (Ethernet [+VLAN] / [outer IP + tunnel] / inner IP /
 * L4 / 32-byte test header / zero payload). Rendered for packet `seq` with the
 * departure timestamp shown as 0 (HW fills it at egress); L4 checksums are
 * computed over that ts=0 frame so the preview is a valid, decodable packet. */

static uint16_t ones_csum(const uint8_t *p, size_t n, uint32_t sum) {
    for (size_t i = 0; i + 1 < n; i += 2) sum += (uint32_t)(p[i] << 8) | p[i+1];
    if (n & 1) sum += (uint32_t)p[n-1] << 8;
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint16_t)~sum;
}
static void wbe16(uint8_t *b, uint16_t v) { b[0] = v >> 8; b[1] = v & 0xFF; }

/* Returns total L2 length (pre-FCS), or -1 on unsupported/overflow.
 * *built receives the number of header+test-header bytes (rest is zero pad). */
static int build_preview_frame(const struct pw_flow *f, uint32_t seq,
                               uint8_t *buf, size_t cap, size_t *built) {
    memset(buf, 0, cap);
    unsigned tmpl = f->traffic.frame_template;
    bool inner_v6 = f->ipv6.present;
    bool is_tcp   = (f->udp.l4_proto == 6);
    bool encap    = f->encap.present && tmpl != PW_FRAME_TEMPLATE_L2RAW;
    bool outer_v6 = encap && f->encap.outer_ipv6.present;
    size_t frame_len = f->traffic.frame_len_fixed_set
                       ? f->traffic.frame_len_fixed : f->traffic.frame_len_min;
    if (frame_len < 14 || frame_len > 9100 || frame_len > cap) return -1;
    size_t o = 0;
    #define PUT(b)  do { if (o >= cap) return -1; buf[o++] = (uint8_t)(b); } while (0)
    #define PUTMAC(m) do { for (int _i=0;_i<6;_i++) PUT((m)[_i]); } while (0)

    /* Ethernet + optional 802.1Q */
    PUTMAC(f->l2.dst_mac); PUTMAC(f->l2.src_mac);
    if (f->l2.vlan_set) {
        PUT(0x81); PUT(0x00);
        uint16_t tci = ((uint16_t)(f->l2.pcp & 7) << 13) | (f->l2.vlan & 0x0FFF);
        PUT(tci >> 8); PUT(tci & 0xFF);
    }

    uint16_t inner_et = inner_v6 ? 0x86DD : 0x0800;

    if (tmpl == PW_FRAME_TEMPLATE_L2RAW) {
        uint16_t et = f->l2.ethertype ? f->l2.ethertype : inner_et;
        PUT(et >> 8); PUT(et & 0xFF);
        *built = o;
        return (int)frame_len;
    }

    /* L4 / payload sizing (inner) */
    size_t l4hl = (tmpl == PW_FRAME_TEMPLATE_L3RAW) ? 0 : (is_tcp ? 20 : 8);
    /* payload after headers: for TEST it's the 32B test header (+ any pad);
     * for L4RAW/L3RAW it's raw zero pad. We size the inner IP length from the
     * remaining frame_len after the L2/outer/tunnel prefix. */
    size_t prefix = o;   /* bytes consumed so far (eth + vlan) */
    size_t outer_len = 0, tun_len = 0, inner_eth = 0;
    if (encap) {
        outer_len = outer_v6 ? 40 : 20;
        if (f->encap.type == PW_ENCAP_GRE) tun_len = 4;
        else if (f->encap.type == PW_ENCAP_ETHERIP) { tun_len = 2; inner_eth = 14; }
        prefix += 2 /*outer et*/ + outer_len + tun_len + inner_eth;
    } else {
        prefix += 2; /* inner ethertype on the Ethernet */
    }
    size_t inner_iphl = inner_v6 ? 40 : 20;
    if (frame_len < prefix + inner_iphl + l4hl) return -1;
    size_t inner_payload = frame_len - prefix - inner_iphl - l4hl; /* test hdr + pad */
    size_t l4_len = l4hl + inner_payload;              /* UDP len / TCP seg len */
    size_t ip_pl  = (tmpl == PW_FRAME_TEMPLATE_L3RAW) ? inner_payload : l4_len;

    /* ---- Outer IP + tunnel (encap only) ---- */
    if (encap) {
        uint8_t oproto = (f->encap.type == PW_ENCAP_IPIP) ? (inner_v6 ? 41 : 4)
                       : (f->encap.type == PW_ENCAP_GRE)  ? 47 : 97;
        size_t o_pl = tun_len + inner_eth + inner_iphl + l4hl + inner_payload;
        if (outer_v6) {
            PUT(0x86); PUT(0xDD);
            const struct pw_flow_ipv6 *x = &f->encap.outer_ipv6;
            PUT(0x60 | (x->dscp >> 2)); PUT((x->dscp & 3) << 6); PUT(0); PUT(0);
            PUT(o_pl >> 8); PUT(o_pl & 0xFF); PUT(oproto); PUT(x->hop_limit ? x->hop_limit : 64);
            for (int i=0;i<16;i++) PUT(x->src[i]);
            for (int i=0;i<16;i++) PUT(x->dst[i]);
        } else {
            PUT(0x08); PUT(0x00);
            const struct pw_flow_ipv4 *x = &f->encap.outer_ipv4;
            size_t ohdr = o;
            PUT(0x45); PUT(x->dscp << 2); uint16_t otot = (uint16_t)(20 + o_pl);
            PUT(otot >> 8); PUT(otot & 0xFF); PUT(0); PUT(0); PUT(0x40); PUT(0);
            PUT(x->ttl ? x->ttl : 64); PUT(oproto); PUT(0); PUT(0);   /* csum filled below */
            PUT(x->src >> 24); PUT(x->src >> 16); PUT(x->src >> 8); PUT(x->src);
            PUT(x->dst >> 24); PUT(x->dst >> 16); PUT(x->dst >> 8); PUT(x->dst);
            wbe16(&buf[ohdr + 10], ones_csum(&buf[ohdr], 20, 0));
        }
        if (f->encap.type == PW_ENCAP_GRE) { PUT(0); PUT(0); PUT(inner_et >> 8); PUT(inner_et & 0xFF); }
        else if (f->encap.type == PW_ENCAP_ETHERIP) {
            PUT(0x30); PUT(0x00);
            const uint8_t *idm = f->encap.inner_mac_set ? f->encap.inner_dst_mac : f->l2.dst_mac;
            const uint8_t *ism = f->encap.inner_mac_set ? f->encap.inner_src_mac : f->l2.src_mac;
            PUTMAC(idm); PUTMAC(ism); PUT(inner_et >> 8); PUT(inner_et & 0xFF);
        }
    } else {
        PUT(inner_et >> 8); PUT(inner_et & 0xFF);
    }

    /* ---- Inner IP header ---- */
    size_t iph = o;
    if (inner_v6) {
        PUT(0x60 | (f->ipv6.dscp >> 2)); PUT((f->ipv6.dscp & 3) << 6); PUT(0); PUT(0);
        PUT(ip_pl >> 8); PUT(ip_pl & 0xFF);
        PUT(tmpl == PW_FRAME_TEMPLATE_L3RAW ? 0xFD : (is_tcp ? 6 : 17));
        PUT(f->ipv6.hop_limit ? f->ipv6.hop_limit : 64);
        for (int i=0;i<16;i++) PUT(f->ipv6.src[i]);
        for (int i=0;i<16;i++) PUT(f->ipv6.dst[i]);
    } else {
        uint16_t tot = (uint16_t)(20 + ip_pl);
        PUT(0x45); PUT(f->ipv4.dscp << 2); PUT(tot >> 8); PUT(tot & 0xFF);
        PUT(0); PUT(0); PUT(0x40); PUT(0);
        PUT(f->ipv4.ttl ? f->ipv4.ttl : 64);
        PUT(tmpl == PW_FRAME_TEMPLATE_L3RAW ? 0xFD : (is_tcp ? 6 : 17));
        PUT(0); PUT(0);   /* csum below */
        PUT(f->ipv4.src >> 24); PUT(f->ipv4.src >> 16); PUT(f->ipv4.src >> 8); PUT(f->ipv4.src);
        PUT(f->ipv4.dst >> 24); PUT(f->ipv4.dst >> 16); PUT(f->ipv4.dst >> 8); PUT(f->ipv4.dst);
        wbe16(&buf[iph + 10], ones_csum(&buf[iph], 20, 0));
    }

    if (tmpl == PW_FRAME_TEMPLATE_L3RAW) { *built = o; return (int)frame_len; }

    /* ---- L4 (UDP/TCP) ---- */
    size_t l4 = o;
    PUT(f->udp.src_port >> 8); PUT(f->udp.src_port & 0xFF);
    PUT(f->udp.dst_port >> 8); PUT(f->udp.dst_port & 0xFF);
    if (is_tcp) {
        PUT(seq >> 24); PUT(seq >> 16); PUT(seq >> 8); PUT(seq);   /* TCP seq = test seq low32 */
        PUT(0); PUT(0); PUT(0); PUT(0);                            /* ack */
        PUT(0x50); PUT(f->udp.tcp_flags ? f->udp.tcp_flags : 0x02);
        PUT(0xFF); PUT(0xFF); PUT(0); PUT(0); PUT(0); PUT(0);      /* window, csum(below), urg */
    } else {
        PUT(l4_len >> 8); PUT(l4_len & 0xFF); PUT(0); PUT(0);      /* UDP len, csum(below) */
    }

    /* ---- TEST header (32B): magic/ver/flow_id/seq/ts=0 ---- */
    if (tmpl == PW_FRAME_TEMPLATE_TEST) {
        size_t t = o;
        buf[t+0]=0xA5; buf[t+1]=0x02; buf[t+2]=0x7E; buf[t+3]=0x57;   /* PW_TEST_HDR_MAGIC */
        buf[t+4]=0x00; buf[t+5]=0x01; buf[t+6]=0; buf[t+7]=0;         /* version 1 */
        buf[t+8]=f->id>>24; buf[t+9]=f->id>>16; buf[t+10]=f->id>>8; buf[t+11]=f->id;
        /* seq is 64-bit; low 32 = seq, high 32 = 0 for packet < 2^32 */
        buf[t+12]=0; buf[t+13]=0; buf[t+14]=0; buf[t+15]=0;
        buf[t+16]=seq>>24; buf[t+17]=seq>>16; buf[t+18]=seq>>8; buf[t+19]=seq;
        /* ts (t+20..27) left 0: HW stamps the departure time at egress */
        o += 32;
        *built = t + 32;
    } else {
        *built = o;   /* L4RAW: headers only, zero payload */
    }

    /* ---- L4 checksum over the ts=0 frame (valid, decodable preview) ---- */
    {
        uint32_t sum = is_tcp ? 6 : 17;
        sum += (uint32_t)l4_len;
        if (inner_v6) { for (int i=0;i<16;i++){ sum += (uint32_t)f->ipv6.src[i]<<((i&1)?0:8);}
                        for (int i=0;i<16;i++){ sum += (uint32_t)f->ipv6.dst[i]<<((i&1)?0:8);} }
        else { sum += (f->ipv4.src>>16)&0xFFFF; sum += f->ipv4.src&0xFFFF;
               sum += (f->ipv4.dst>>16)&0xFFFF; sum += f->ipv4.dst&0xFFFF; }
        uint16_t c = ones_csum(&buf[l4], frame_len - l4, sum);
        if (is_tcp) wbe16(&buf[l4 + 16], c);
        else        wbe16(&buf[l4 + 6],  c);   /* incl. v4 UDP (valid; HW sends 0) */
    }
    #undef PUT
    #undef PUTMAC
    return (int)frame_len;
}

static const char *tmpl_name(unsigned t) {
    return t==0?"test":t==1?"l4raw":t==2?"l3raw":t==3?"l2raw":"?";
}

static int cmd_flow_preview(int argc, char **argv) {
    const char *path = NULL; int want = -1; uint32_t seq = 0; bool raw = false;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--flow") && i+1 < argc) want = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seq") && i+1 < argc) seq = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--json")) raw = true;
        else if (!path) path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: pktwyrm flow preview <config.yaml> [--flow ID] [--seq N] [--json]\n"); return 2; }
    /* Preview needs only the parsed flows (not a compiled program), so accept a
     * full combined config OR a test-only (flows/forwards) file. */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    if (pw_config_parse_file(path, cfg, &d) != PW_OK) {
        pw_config_free(cfg);
        cfg = pw_config_new();
        struct pw_diag dt = {0};
        if (pw_config_parse_file_ex(path, PW_CFG_TEST_ONLY, cfg, &dt) != PW_OK) {
            fprintf(stderr, "parse error at %s: %s\n", dt.path, dt.message);
            pw_config_free(cfg); return 1;
        }
    }
    if (cfg->n_flows == 0) { fprintf(stderr, "no flows in %s\n", path); pw_config_free(cfg); return 1; }
    int rc = 0;
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        if (want >= 0 && (int)f->id != want) continue;
        uint8_t buf[9200]; size_t built = 0;
        int len = build_preview_frame(f, seq, buf, sizeof buf, &built);
        if (len < 0) {
            fprintf(stderr, "flow %u (%s): cannot build preview (unsupported template/length)\n",
                    f->id, tmpl_name(f->traffic.frame_template));
            rc = 1; continue;
        }
        if (raw) {
            printf("{\"flow\":%u,\"name\":\"%s\",\"template\":\"%s\",\"len\":%d,\"seq\":%u,\"hex\":\"",
                   f->id, f->name, tmpl_name(f->traffic.frame_template), len, seq);
            for (int b = 0; b < len; b++) printf("%02x", buf[b]);
            printf("\"}\n");
            continue;
        }
        printf("flow %u \"%s\": template=%s  frame_len=%d B (pre-FCS)  packet seq=%u\n",
               f->id, f->name[0]?f->name:"(unnamed)", tmpl_name(f->traffic.frame_template), len, seq);
        /* decode summary */
        printf("  eth   dst=%02x:%02x:%02x:%02x:%02x:%02x src=%02x:%02x:%02x:%02x:%02x:%02x\n",
               buf[0],buf[1],buf[2],buf[3],buf[4],buf[5],buf[6],buf[7],buf[8],buf[9],buf[10],buf[11]);
        if (f->l2.vlan_set) printf("  vlan  vid=%u pcp=%u\n", f->l2.vlan, f->l2.pcp);
        if (f->encap.present && f->traffic.frame_template != PW_FRAME_TEMPLATE_L2RAW)
            printf("  encap %s (outer %s)\n",
                   f->encap.type==1?"ipip":f->encap.type==2?"gre":"etherip",
                   f->encap.outer_ipv6.present?"ipv6":"ipv4");
        if (f->traffic.frame_template != PW_FRAME_TEMPLATE_L2RAW) {
            if (f->ipv6.present) printf("  ipv6  ttl=%u dscp=%u proto=%s\n",
                   f->ipv6.hop_limit?f->ipv6.hop_limit:64, f->ipv6.dscp,
                   f->traffic.frame_template==PW_FRAME_TEMPLATE_L3RAW?"raw":(f->udp.l4_proto==6?"tcp":"udp"));
            else printf("  ipv4  ttl=%u dscp=%u proto=%s\n",
                   f->ipv4.ttl?f->ipv4.ttl:64, f->ipv4.dscp,
                   f->traffic.frame_template==PW_FRAME_TEMPLATE_L3RAW?"raw":(f->udp.l4_proto==6?"tcp":"udp"));
            if (f->traffic.frame_template!=PW_FRAME_TEMPLATE_L3RAW)
                printf("  l4    %s sport=%u dport=%u\n", f->udp.l4_proto==6?"tcp":"udp",
                       f->udp.src_port, f->udp.dst_port);
            if (f->traffic.frame_template==PW_FRAME_TEMPLATE_TEST)
                printf("  test  magic=A5027E57 flow_id=%u seq=%u ts=<egress>\n", f->id, seq);
        }
        /* hexdump: full header region + up to 16 payload bytes */
        int show = (int)built + 16; if (show > len) show = len;
        for (int b = 0; b < show; b += 16) {
            printf("  %04x  ", b);
            for (int j = 0; j < 16; j++) {
                if (b+j < show) printf("%02x ", buf[b+j]); else printf("   ");
                if (j==7) printf(" ");
            }
            printf(" |");
            for (int j = 0; j < 16 && b+j < show; j++) {
                unsigned c = buf[b+j]; printf("%c", (c>=32&&c<127)?c:'.');
            }
            printf("|\n");
        }
        if (len > show) printf("  ... +%d payload bytes (zero-filled)\n", len - show);
        printf("  note: timestamp is stamped by HW at egress (shown 0); L4 checksum shown is\n"
               "        computed for this seq with ts=0 (HW re-folds it at egress).\n");
    }
    pw_config_free(cfg);
    return rc;
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
/* Remote transport: POST the (already secret-injected) JSON to a
 * packetwyrm-proxyd over HTTPS and copy the response body into `resp`.
 * `hostarg` is "HOST" or "HOST:PORT" (default port 8443). The gateway's
 * cert is self-signed by default, so we do NOT verify it (a lab tool);
 * a one-time warning is printed. Returns 0 on success, -1 on error. */
static int https_rpc_call(const char *hostarg, const char *send,
                          char *resp, size_t resp_cap, size_t *out_len) {
    /* The gateway relays at most PW_IPC_FRAME_MAX to the daemon; reject an
     * oversize body here rather than build a request we can't send. */
    size_t send_len = strlen(send);
    if (send_len > PW_IPC_FRAME_MAX) return -1;

    char host[256]; const char *port = "8443";
    if ((size_t)snprintf(host, sizeof(host), "%s", hostarg) >= sizeof(host))
        return -1;   /* over-length host would silently connect to a truncated name */
    /* Split HOST[:PORT]. Support [ipv6]:port / [ipv6]; a BARE IPv6 literal
     * (multiple colons, no brackets) is taken as host-only so strrchr(':')
     * doesn't slice it mid-address. */
    if (host[0] == '[') {
        char *rb = strchr(host, ']');
        if (!rb) return -1;
        if (rb[1] == ':')      port = rb + 2;
        else if (rb[1] != '\0') return -1;   /* junk after ']' */
        *rb = '\0';
        memmove(host, host + 1, strlen(host + 1) + 1);   /* drop leading '[' */
    } else {
        char *first = strchr(host, ':');
        char *last  = strrchr(host, ':');
        if (first && first == last) { *last = '\0'; port = last + 1; }
        /* no colon (host only) or >1 colon (bare IPv6) -> no port split */
    }

    static int warned = 0;
    if (!warned) {
        /* The channel is encrypted but NOT authenticated (self-signed cert,
         * unverified) -- a MITM could capture the secret. Accepted lab tradeoff:
         * use only over a trusted network / SSH tunnel / VPN. See web-gui.md. */
        fprintf(stderr, "pktwyrm: WARNING connecting to %s:%s over TLS WITHOUT "
                        "certificate verification (self-signed) -- the secret is "
                        "exposed to a man-in-the-middle; use only over a trusted "
                        "network / SSH tunnel / VPN\n", host, port);
        warned = 1;
    }

    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL *ssl = ctx ? SSL_new(ctx) : NULL;
    int rc = -1;
    if (ssl) {
        SSL_set_fd(ssl, fd);
        SSL_set_tlsext_host_name(ssl, host);
        if (SSL_connect(ssl) == 1) {
            char req[PW_IPC_FRAME_MAX + 512];
            int hn = snprintf(req, sizeof(req),
                "POST /api/rpc HTTP/1.1\r\nHost: %s\r\n"
                "Content-Type: application/json\r\nContent-Length: %zu\r\n"
                "X-PW-Request: 1\r\n" /* required by proxyd (CSRF defence) */
                "Connection: close\r\n\r\n%s",
                host, send_len, send);
            /* snprintf returns the length it WOULD have written: a truncated
             * request must be rejected, or the SSL_write loop below (bounded by
             * hn) would read past req and leak stack bytes onto the wire. */
            int wok = (hn > 0 && (size_t)hn < sizeof(req));
            /* TLS allows partial writes -- loop until the whole request is sent. */
            for (int off = 0; wok && off < hn; ) {
                int w = SSL_write(ssl, req + off, hn - off);
                if (w <= 0) wok = 0; else off += w;
            }
            if (wok) {
                /* Read the whole HTTP response. */
                char buf[PW_IPC_FRAME_MAX + 4096];
                size_t have = 0;
                int r;
                while (have < sizeof(buf) - 1 &&
                       (r = SSL_read(ssl, buf + have, (int)(sizeof(buf) - 1 - have))) > 0)
                    have += (size_t)r;
                buf[have] = '\0';
                /* Validate the response line + framing before trusting the body:
                 *  - require "HTTP/1.x 200" (a 4xx/5xx gateway/relay error must
                 *    not be handed up as a daemon reply);
                 *  - a filled buffer means the response was truncated -> fail;
                 *  - if Content-Length is present, the body must be exactly that
                 *    long (a short read = truncation). */
                bool http_ok = (strncmp(buf, "HTTP/1.", 7) == 0);
                char *sp = http_ok ? strchr(buf, ' ') : NULL;
                bool is_200 = sp && strncmp(sp + 1, "200", 3) == 0 &&
                              (sp[4] == ' ' || sp[4] == '\r');
                bool truncated = (have >= sizeof(buf) - 1);
                char *body = is_200 && !truncated ? strstr(buf, "\r\n\r\n") : NULL;
                if (body) {
                    body += 4;
                    size_t blen = have - (size_t)(body - buf);
                    /* Enforce a declared Content-Length exactly (case-insensitive
                     * header match); reject a short/over body. */
                    long declared = -1;
                    for (char *h = buf; h && h < body; ) {
                        if (strncasecmp(h, "Content-Length:", 15) == 0) {
                            char *e = NULL;
                            declared = strtol(h + 15, &e, 10);
                            break;
                        }
                        char *nl = strstr(h, "\r\n");
                        h = nl ? nl + 2 : NULL;
                    }
                    if (declared >= 0 && (size_t)declared != blen) {
                        /* framing mismatch (truncated / trailing garbage) */
                    } else if (blen <= resp_cap) {
                        memcpy(resp, body, blen);
                        *out_len = blen;
                        rc = 0;
                    }
                }
            }
        } else {
            ERR_print_errors_fp(stderr);
        }
    }
    if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); }
    if (ctx) SSL_CTX_free(ctx);
    close(fd);
    return rc;
}

static int rpc_call(const char *sock, const char *json_req,
                    char *resp, size_t resp_cap, size_t *out_len) {
    /* Inject the access secret (if any) into the request object -- via json-c so
     * it is escaped correctly. Falls back to the raw request if the secret is
     * empty or the request doesn't parse (shouldn't happen). */
    const char *sec = resolve_secret();
    const char *send = json_req;
    struct json_object *o = NULL;
    if (sec && sec[0]) {
        o = json_tokener_parse(json_req);
        if (o) {
            json_object_object_add(o, "secret", json_object_new_string(sec));
            send = json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN);
        }
    }

    int rc;
    if (g_host_arg) {
        /* Remote: HTTPS to a packetwyrm-proxyd. `sock` is ignored. */
        rc = https_rpc_call(g_host_arg, send, resp, resp_cap, out_len);
    } else {
        int fd = -1;
        if (pw_ipc_connect(sock, &fd) != PW_OK) {
            g_last_connect_errno = errno;   /* pw_ipc_connect preserves it */
            if (o) json_object_put(o);
            return -1;
        }
        rc = (pw_ipc_write_frame(fd, send, strlen(send)) == PW_OK &&
              pw_ipc_read_frame(fd, resp, resp_cap, out_len) == PW_OK) ? 0 : -1;
        close(fd);
    }
    if (o) json_object_put(o);
    return rc;
}

/* Print a diagnostic for a failed rpc_call. For a local-socket connect failure
 * we captured errno; turn it into an actionable hint (daemon not running /
 * wrong path / permission) instead of the opaque "rpc call failed". */
static void rpc_fail(const char *sock) {
    if (g_host_arg) {
        fprintf(stderr, "rpc call failed (host=%s) -- is packetwyrm-proxyd "
                "reachable and serving TLS there?\n", g_host_arg);
    } else if (g_last_connect_errno) {
        fprintf(stderr, "rpc call failed (socket=%s): %s\n         %s\n",
                sock, strerror(g_last_connect_errno),
                pw_ipc_connect_hint(g_last_connect_errno));
    } else {
        fprintf(stderr, "rpc call failed (socket=%s): the daemon closed the "
                "connection or sent a malformed reply\n", sock);
    }
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

/* Pretty-print per-flow one-way latency from the "flow.stats" response. Shows
 * the measurement method per flow: "same-card" (counter-direct, exact) or
 * "gpio-corrected" (cross-card, J5-offset-corrected). 1 tick = 6.4 ns. */
static void pretty_print_latency(const char *json, size_t len) {
    struct json_tokener *tok = json_tokener_new();
    struct json_object *root = json_tokener_parse_ex(tok, json, (int)len);
    json_tokener_free(tok);
    if (!root) { printf("%.*s\n", (int)len, json); return; }
    struct json_object *err;
    if (json_object_object_get_ex(root, "error", &err)) {
        printf("error: %s\n", json_object_get_string(err)); json_object_put(root); return;
    }
    struct json_object *arr;
    if (!json_object_object_get_ex(root, "flows", &arr) ||
        json_object_get_type(arr) != json_type_array) {
        printf("%.*s\n", (int)len, json); json_object_put(root); return;
    }
    printf("%-5s %-19s %10s %10s %8s %8s  %s\n",
           "flow", "path (tx->rx)", "min(ns)", "max(ns)", "jit(ns)", "samples", "method");
    size_t n = json_object_array_length(arr);
    for (size_t i = 0; i < n; i++) {
        struct json_object *f = json_object_array_get_idx(arr, i), *v;
        int id=0; int valid=0;
        long mn=0, mx=0, jmx=0, samp=0; const char *meth="?";
        const char *txp="?", *rxp="?";
        if (json_object_object_get_ex(f,"id",&v))            id=json_object_get_int(v);
        if (json_object_object_get_ex(f,"tx_port",&v))       txp=json_object_get_string(v);
        if (json_object_object_get_ex(f,"rx_port",&v))       rxp=json_object_get_string(v);
        if (json_object_object_get_ex(f,"latency_valid",&v)) valid=json_object_get_boolean(v);
        if (json_object_object_get_ex(f,"min_latency",&v))   mn=json_object_get_int64(v);
        if (json_object_object_get_ex(f,"max_latency",&v))   mx=json_object_get_int64(v);
        if (json_object_object_get_ex(f,"jitter_max",&v))    jmx=json_object_get_int64(v);
        if (json_object_object_get_ex(f,"sample_count",&v))  samp=json_object_get_int64(v);
        if (json_object_object_get_ex(f,"latency_method",&v))meth=json_object_get_string(v);
        char path[4*PW_NAME_MAX+4]; snprintf(path, sizeof(path), "%s->%s", txp, rxp);
        if (valid && samp > 0)
            printf("%-5d %-19s %10.1f %10.1f %8.1f %8ld  %s\n",
                   id, path, mn*6.4, mx*6.4, jmx*6.4, samp, meth);
        else
            /* no samples yet (no traffic) -> dashes, not a 0xFFFFFFFF sentinel */
            printf("%-5d %-19s %10s %10s %8s %8ld  %s\n",
                   id, path, "-", "-", "-", samp, valid ? "no traffic" : "no latency");
    }
    json_object_put(root);
}

static int cmd_latency(int argc, char **argv) {
    /* pktwyrm latency [--socket PATH] [--flow N] [--json] */
    const char *sock = PW_IPC_DEFAULT_PATH;
    int flow = -1; bool raw = false;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--flow") && i + 1 < argc) flow = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--json")) raw = true;
    }
    char req[128];
    if (flow >= 0) snprintf(req, sizeof(req), "{\"rpc\":\"flow.stats\",\"id\":%d}", flow);
    else           snprintf(req, sizeof(req), "{\"rpc\":\"flow.stats\"}");
    char resp[PW_IPC_FRAME_MAX]; size_t got = 0;
    if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
        rpc_fail(sock); return 1;
    }
    if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); }
    else     pretty_print_latency(resp, got);
    return 0;
}

/* Pretty-print the "tap.stats" response: one block per host-plane TAP. */
static void pretty_print_taps(const char *json, size_t len) {
    struct json_tokener *tok = json_tokener_new();
    struct json_object *root = json_tokener_parse_ex(tok, json, (int)len);
    json_tokener_free(tok);
    if (!root) { fprintf(stderr, "bad response\n"); return; }
    struct json_object *err;
    if (json_object_object_get_ex(root, "error", &err)) {
        printf("error: %s\n", json_object_get_string(err)); json_object_put(root); return;
    }
    struct json_object *arr;
    if (!json_object_object_get_ex(root, "taps", &arr)) { json_object_put(root); return; }
    size_t n = json_object_array_length(arr);
    if (n == 0) { printf("(no TAP interfaces)\n"); json_object_put(root); return; }
    for (size_t i = 0; i < n; i++) {
        struct json_object *o = json_object_array_get_idx(arr, i), *v;
        const char *name = "?", *mac = "";
        int lif = 0, gp = -1, vlan = 0, mtu = 0;
        if (json_object_object_get_ex(o, "name", &v)) name = json_object_get_string(v);
        if (json_object_object_get_ex(o, "logical_if_id", &v)) lif = json_object_get_int(v);
        if (json_object_object_get_ex(o, "mac", &v)) mac = json_object_get_string(v);
        if (json_object_object_get_ex(o, "global_port", &v)) gp = json_object_get_int(v);
        if (json_object_object_get_ex(o, "vlan", &v)) vlan = json_object_get_int(v);
        if (json_object_object_get_ex(o, "mtu", &v)) mtu = json_object_get_int(v);
        bool au = false, ou = false;
        if (json_object_object_get_ex(o, "admin_up", &v)) au = json_object_get_boolean(v);
        if (json_object_object_get_ex(o, "oper_up", &v))  ou = json_object_get_boolean(v);
        printf("%-16s lif=%d  %s  port=%d vlan=%d mtu=%d  [%s%s]\n",
               name, lif, mac, gp, vlan, mtu,
               au ? "UP" : "DOWN", ou ? ",RUNNING" : "");
        struct json_object *ad;
        if (json_object_object_get_ex(o, "addrs", &ad)) {
            size_t na = json_object_array_length(ad);
            if (na) {
                printf("    addrs:");
                for (size_t a = 0; a < na; a++)
                    printf(" %s", json_object_get_string(json_object_array_get_idx(ad, a)));
                printf("\n");
            }
        }
        struct json_object *k;
        if (json_object_object_get_ex(o, "kernel", &k)) {
            long long rxp=0, rxd=0, txp=0, txd=0;
            if (json_object_object_get_ex(k, "rx_packets", &v)) rxp = json_object_get_int64(v);
            if (json_object_object_get_ex(k, "rx_dropped", &v)) rxd = json_object_get_int64(v);
            if (json_object_object_get_ex(k, "tx_packets", &v)) txp = json_object_get_int64(v);
            if (json_object_object_get_ex(k, "tx_dropped", &v)) txd = json_object_get_int64(v);
            printf("    kernel: rx %lld pkt (%lld drop)  tx %lld pkt (%lld drop)\n",
                   rxp, rxd, txp, txd);
        }
        struct json_object *b;
        if (json_object_object_get_ex(o, "bridge", &b)) {
            long long tto=0, ttd=0, fto=0, ftd=0;
            if (json_object_object_get_ex(b, "to_tap_ok", &v))      tto = json_object_get_int64(v);
            if (json_object_object_get_ex(b, "to_tap_dropped", &v)) ttd = json_object_get_int64(v);
            if (json_object_object_get_ex(b, "from_tap_ok", &v))      fto = json_object_get_int64(v);
            if (json_object_object_get_ex(b, "from_tap_dropped", &v)) ftd = json_object_get_int64(v);
            printf("    bridge: FPGA->tap %lld (%lld drop)  tap->FPGA %lld (%lld drop)\n",
                   tto, ttd, fto, ftd);
        }
    }
    json_object_put(root);
}

static int cmd_tap(int argc, char **argv) {
    /* pktwyrm tap [--socket PATH] [--json] */
    const char *sock = PW_IPC_DEFAULT_PATH;
    bool raw = false;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--json")) raw = true;
    }
    char resp[PW_IPC_FRAME_MAX]; size_t got = 0;
    if (rpc_call(sock, "{\"rpc\":\"tap.stats\"}", resp, sizeof(resp), &got) < 0) {
        rpc_fail(sock); return 1;
    }
    if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); }
    else     pretty_print_taps(resp, got);
    return 0;
}

/* Pretty-print the "sfp.info" response: one block per present module. */
static void pretty_print_sfp(const char *json, size_t len) {
    struct json_tokener *tok = json_tokener_new();
    struct json_object *root = json_tokener_parse_ex(tok, json, (int)len);
    json_tokener_free(tok);
    if (!root) { fprintf(stderr, "bad response\n"); return; }
    struct json_object *err;
    if (json_object_object_get_ex(root, "error", &err)) {
        printf("error: %s\n", json_object_get_string(err)); json_object_put(root); return;
    }
    struct json_object *arr;
    if (!json_object_object_get_ex(root, "sfp", &arr)) { json_object_put(root); return; }
    size_t n = json_object_array_length(arr);
    for (size_t i = 0; i < n; i++) {
        struct json_object *o = json_object_array_get_idx(arr, i), *v;
        int card = 0, port = 0; bool present = false;
        if (json_object_object_get_ex(o, "card_id", &v)) card = json_object_get_int(v);
        if (json_object_object_get_ex(o, "port", &v))    port = json_object_get_int(v);
        if (json_object_object_get_ex(o, "present", &v)) present = json_object_get_boolean(v);
        printf("card %d port %d: ", card, port);
        if (!present) {
            if (json_object_object_get_ex(o, "error", &v))
                printf("%s\n", json_object_get_string(v));
            else printf("no module\n");
            continue;
        }
        const char *vendor = "", *part = "", *ser = "";
        if (json_object_object_get_ex(o, "vendor", &v)) vendor = json_object_get_string(v);
        if (json_object_object_get_ex(o, "part", &v))   part   = json_object_get_string(v);
        if (json_object_object_get_ex(o, "serial", &v)) ser    = json_object_get_string(v);
        int br = 0;
        if (json_object_object_get_ex(o, "br_nominal_mbaud", &v)) br = json_object_get_int(v);
        printf("%s %s  s/n %s  %.1f Gb/s\n", vendor, part, ser, br / 1000.0);
        bool domv = false, doms = false, ext = false;
        if (json_object_object_get_ex(o, "dom_valid", &v))     domv = json_object_get_boolean(v);
        if (json_object_object_get_ex(o, "dom_supported", &v)) doms = json_object_get_boolean(v);
        if (json_object_object_get_ex(o, "dom_external_cal", &v)) ext = json_object_get_boolean(v);
        if (domv) {
            double t=0,vcc=0,bias=0,txp=0,rxp=0;
            if (json_object_object_get_ex(o,"temp_c",&v))      t=json_object_get_double(v);
            if (json_object_object_get_ex(o,"vcc_v",&v))       vcc=json_object_get_double(v);
            if (json_object_object_get_ex(o,"tx_bias_ma",&v))  bias=json_object_get_double(v);
            if (json_object_object_get_ex(o,"tx_power_mw",&v)) txp=json_object_get_double(v);
            if (json_object_object_get_ex(o,"rx_power_mw",&v)) rxp=json_object_get_double(v);
            printf("    DOM: %.1f C  %.2f V  bias %.1f mA  TX %.2f dBm  RX %.2f dBm\n",
                   t, vcc, bias,
                   txp > 0 ? 10.0 * log10(txp) : -40.0,
                   rxp > 0 ? 10.0 * log10(rxp) : -40.0);
        } else if (ext) {
            printf("    DOM: externally calibrated -- not decoded\n");
        } else if (!doms) {
            printf("    DOM: not supported (e.g. passive DAC)\n");
        }
    }
    json_object_put(root);
}

static int cmd_sfp(int argc, char **argv) {
    /* pktwyrm sfp [--socket PATH] [--card N] [--port P] [--json] */
    const char *sock = PW_IPC_DEFAULT_PATH;
    int card = -1, port = -1; bool raw = false;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--card") && i + 1 < argc) card = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--json")) raw = true;
    }
    char req[128];
    int off = snprintf(req, sizeof(req), "{\"rpc\":\"sfp.info\"");
    if (card >= 0) off += snprintf(req + off, sizeof(req) - off, ",\"card\":%d", card);
    if (port >= 0) off += snprintf(req + off, sizeof(req) - off, ",\"port\":%d", port);
    snprintf(req + off, sizeof(req) - off, "}");
    char resp[PW_IPC_FRAME_MAX]; size_t got = 0;
    if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
        rpc_fail(sock); return 1;
    }
    if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); }
    else     pretty_print_sfp(resp, got);
    return 0;
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
            rpc_fail(sock);
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

    char req[256];
    int rlen;
    if (card_id >= 0) {
        rlen = snprintf(req, sizeof(req),
                        "{\"rpc\":\"%s\",\"card\":%d}", method, card_id);
    } else {
        rlen = snprintf(req, sizeof(req), "{\"rpc\":\"%s\"}", method);
    }
    if (rlen < 0 || (size_t)rlen >= sizeof(req)) return 1;
    /* Route through rpc_call so the secret is injected and --host (remote
     * HTTPS via packetwyrm-proxyd) is honored, same as every other command. */
    char  resp[PW_IPC_FRAME_MAX];
    size_t got = 0;
    if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
        rpc_fail(sock);
        return 1;
    }
    fwrite(resp, 1, got, stdout);
    fputc('\n', stdout);
    return 0;
}

/* `pktwyrm init [--out FILE]`: discover the PacketWyrm cards in this host and
 * emit a ready-to-edit environment-config skeleton (system + cards + ports +
 * a sample logical interface) with the real PCI BDFs filled in. Non-interactive
 * and scriptable; writes to stdout by default, or --out FILE. This replaces the
 * "run `pktwyrm cards`, copy an example, hand-edit the BDFs" first-run dance. */
static int cmd_init(int argc, char **argv) {
    const char *out = NULL;
    for (int i = 0; i < argc; i++)
        if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];

    struct pw_pci_device devs[PW_MAX_CARDS] = {0};
    int n = pw_pci_discover(PW_DEFAULT_PCI_VENDOR, PW_DEFAULT_PCI_DEVICE, devs, PW_MAX_CARDS);
    if (n < 0) { fprintf(stderr, "PCI discovery failed: %s\n", pw_strerror((pw_status)n)); return 1; }

    FILE *f = stdout;
    if (out) { f = fopen(out, "w"); if (!f) { fprintf(stderr, "cannot write %s: %s\n", out, strerror(errno)); return 1; } }

    fprintf(f,
        "# PacketWyrm environment config (generated by `pktwyrm init`).\n"
        "# Deploy as /etc/packetwyrm/packetwyrm.yaml, then edit as needed.\n"
        "# Pair with a test config (flows/forwards) via `pktwyrm load`.\n"
        "system:\n"
        "  name: \"pw-host\"\n"
        "  mode: \"multi-card\"\n"
        "  default_speed: \"10g\"\n"
        "  # secret: \"change-me\"   # uncomment to require a control-socket secret\n");
    if (n == 0) {
        fprintf(f,
            "# NOTE: no PacketWyrm cards were discovered (vendor=0x%04x device=0x%04x).\n"
            "#   Fill in the PCI BDF(s) below by hand once the card is bound.\n"
            "cards:\n"
            "  - id: 0\n"
            "    name: \"card0\"\n"
            "    pci: \"0000:00:00.0\"   # EDIT ME\n"
            "    ports:\n"
            "      - { local_port: 0, global_port: 0, name: \"p0\" }\n"
            "      - { local_port: 1, global_port: 1, name: \"p1\" }\n",
            PW_DEFAULT_PCI_VENDOR, PW_DEFAULT_PCI_DEVICE);
    } else {
        fprintf(f, "cards:\n");
        int gp = 0;
        for (int i = 0; i < n && i < PW_MAX_CARDS; i++) {
            fprintf(f,
                "  - id: %d\n"
                "    name: \"card%d\"\n"
                "    pci: \"%s\"\n"
                "    ports:\n"
                "      - { local_port: 0, global_port: %d, name: \"c%dp0\" }\n"
                "      - { local_port: 1, global_port: %d, name: \"c%dp1\" }\n",
                i, i, devs[i].bdf, gp, i, gp + 1, i);
            gp += 2;
        }
    }
    fprintf(f,
        "logical_interfaces:\n"
        "  - id: 1000\n"
        "    global_port: 0\n"
        "    vlan: 100\n"
        "    mac: \"02:a5:02:00:00:64\"\n"
        "    mtu: 9000\n"
        "    punt: { arp: false, ipv6_nd: false, lldp: false, icmp: false, bgp: false, ospf: false }\n");
    if (out) { fclose(f); fprintf(stderr, "wrote %s (%d card(s) discovered)\n", out, n); }
    return 0;
}

/* Parse a duration like "10s", "500ms", "2m", or a bare integer (seconds).
 * Returns milliseconds, or -1 on a malformed value. */
static long parse_duration_ms(const char *s) {
    char *end = NULL;
    errno = 0;
    double v = strtod(s, &end);
    if (end == s || v < 0 || errno) return -1;
    if (!*end || !strcmp(end, "s"))  return (long)(v * 1000.0 + 0.5);
    if (!strcmp(end, "ms"))          return (long)(v + 0.5);
    if (!strcmp(end, "m"))           return (long)(v * 60000.0 + 0.5);
    return -1;
}

/* `pktwyrm test run [--duration 10s] [--socket PATH] [--json]`: the whole
 * measurement loop in one verb -- arm (clean baseline) -> start -> wait ->
 * read flow.stats -> stop -> PASS/FAIL. PASS = every measured (rx-bearing)
 * flow saw rx_frames>0 with lost==0 && duplicate==0 && out_of_order==0.
 * Exit 0 on PASS, 1 on FAIL, 2 on usage/RPC error -- so it drops into CI. */
static int cmd_test_run(int argc, char **argv) {
    const char *sock = PW_IPC_DEFAULT_PATH;
    long dur_ms = 10000;   /* default 10 s */
    bool raw = false;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
        else if (!strcmp(argv[i], "--duration") && i + 1 < argc) {
            dur_ms = parse_duration_ms(argv[++i]);
            if (dur_ms < 0) { fprintf(stderr, "bad --duration (try 10s, 500ms, 2m)\n"); return 2; }
        } else if (!strcmp(argv[i], "--json")) raw = true;
    }
    char resp[PW_IPC_FRAME_MAX]; size_t got = 0;
    /* arm: re-push + clear counters for a clean baseline. */
    if (rpc_call(sock, "{\"rpc\":\"test.arm\"}", resp, sizeof resp, &got) < 0) { rpc_fail(sock); return 2; }
    /* start: enable generation (and re-clear + re-prime cross-card correction). */
    if (rpc_call(sock, "{\"rpc\":\"test.start\"}", resp, sizeof resp, &got) < 0) { rpc_fail(sock); return 2; }
    /* Surface the cross-card servo warning if the daemon reported one. */
    {
        struct json_tokener *tk = json_tokener_new();
        struct json_object *r = json_tokener_parse_ex(tk, resp, (int)got);
        json_tokener_free(tk);
        if (r) { struct json_object *w;
            if (json_object_object_get_ex(r, "warning", &w))
                fprintf(stderr, "warning: %s\n", json_object_get_string(w));
            json_object_put(r); }
    }
    if (!raw) fprintf(stderr, "running for %ld ms...\n", dur_ms);
    struct timespec ts = { dur_ms / 1000, (dur_ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
    /* Sample flow.stats, then stop generation. */
    int rc = rpc_call(sock, "{\"rpc\":\"flow.stats\"}", resp, sizeof resp, &got);
    (void)rpc_call(sock, "{\"rpc\":\"test.stop\"}", (char[16]){0}, 16, &(size_t){0});
    if (rc < 0) { rpc_fail(sock); return 2; }
    if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); }
    struct json_tokener *tk = json_tokener_new();
    struct json_object *root = json_tokener_parse_ex(tk, resp, (int)got);
    json_tokener_free(tk);
    if (!root) { if (!raw) { fwrite(resp,1,got,stdout); fputc('\n',stdout);} return 2; }
    struct json_object *arr;
    if (!json_object_object_get_ex(root, "flows", &arr) ||
        json_object_get_type(arr) != json_type_array) {
        fprintf(stderr, "unexpected flow.stats response\n"); json_object_put(root); return 2;
    }
    size_t n = json_object_array_length(arr);
    int measured = 0, failed = 0;
    if (!raw)
        printf("%-4s %-14s %14s %14s %8s %8s %8s  %s\n",
               "flow", "path", "tx_frames", "rx_frames", "lost", "dup", "ooo", "verdict");
    for (size_t i = 0; i < n; i++) {
        struct json_object *f = json_object_array_get_idx(arr, i), *v;
        int id = 0; const char *path = "?";
        int64_t tx=0, rx=0, lost=0, dup=0, ooo=0; bool has_rx = false;
        if (json_object_object_get_ex(f, "id", &v)) id = json_object_get_int(v);
        if (json_object_object_get_ex(f, "rx_port", &v)) path = json_object_get_string(v);
        if (json_object_object_get_ex(f, "tx_frames", &v)) tx = json_object_get_int64(v);
        if (json_object_object_get_ex(f, "rx_frames", &v)) { rx = json_object_get_int64(v); has_rx = true; }
        if (json_object_object_get_ex(f, "lost", &v)) lost = json_object_get_int64(v);
        if (json_object_object_get_ex(f, "duplicate", &v)) dup = json_object_get_int64(v);
        if (json_object_object_get_ex(f, "out_of_order", &v)) ooo = json_object_get_int64(v);
        /* A "measured" flow is one that has an RX checker (background/TX-only
         * flows report no rx path); only those gate PASS/FAIL. */
        bool is_measured = has_rx && json_object_object_get_ex(f, "rx_card_id", &v);
        const char *verdict;
        if (!is_measured)                         verdict = "-- (tx-only)";
        else if (rx == 0)                         { verdict = "FAIL (no rx)"; failed++; measured++; }
        else if (lost || dup || ooo)              { verdict = "FAIL";         failed++; measured++; }
        else                                      { verdict = "PASS";                    measured++; }
        if (!raw)
            printf("%-4d %-14s %14lld %14lld %8lld %8lld %8lld  %s\n",
                   id, path, (long long)tx, (long long)rx,
                   (long long)lost, (long long)dup, (long long)ooo, verdict);
    }
    json_object_put(root);
    if (!raw)
        printf("\n%s: %d measured flow(s), %d failed\n",
               failed ? "FAIL" : "PASS", measured, failed);
    return failed ? 1 : 0;
}

/* `pktwyrm firmware update <file.bin> --card BDF [--boot] [--scratch]`:
 * one guarded command for a bitstream update -- validate the image, read the
 * running build_id, live-program the config flash over PCIe (with a progress
 * line), verify, and (with --boot) trigger an ICAP reload + PCIe rescan and
 * confirm the build_id CHANGED. LOCAL/direct-card (not via the daemon): the
 * card must NOT be owned by a running daemon, and it needs root + vfio. This
 * replaces the error-prone "pw_flash <bdf> <bin> 0 ; pw_reboot <bdf> ; eyeball
 * the build_id" sequence, and refuses offset-0 (boot image) writes without an
 * explicit choice so a fat-fingered scratch/boot mixup can't brick the card. */
static int cmd_firmware(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[0], "update") != 0) {
        fprintf(stderr,
            "usage: pktwyrm firmware update <file.bin> --card BDF [--boot] [--scratch]\n"
            "  Writes the config flash live over PCIe, then (with --boot) reloads.\n"
            "  Default target is the BOOT image (offset 0); --scratch writes the\n"
            "  0xE00000 dev region instead. Needs root; the card must be free\n"
            "  (stop packetwyrmd first).\n");
        return 2;
    }
    const char *file = argv[1];
    const char *bdf = NULL;
    bool boot = false, scratch = false;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--card") && i + 1 < argc) bdf = argv[++i];
        else if (!strcmp(argv[i], "--boot")) boot = true;
        else if (!strcmp(argv[i], "--scratch")) scratch = true;
        else { fprintf(stderr, "unknown arg: %s\n", argv[i]); return 2; }
    }
    if (!bdf) { fprintf(stderr, "--card BDF required (e.g. --card 07:00.0)\n"); return 2; }
    uint32_t off = scratch ? 0x00E00000u : 0u;

    FILE *f = fopen(file, "rb");
    if (!f) { fprintf(stderr, "cannot open %s: %s\n", file, strerror(errno)); return 1; }
    fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
    if (fsz <= 0 || fsz > (16 << 20)) {
        fprintf(stderr, "bad image size %ld (expect a .bin up to 16 MB)\n", fsz);
        fclose(f); return 1;
    }
    if ((uint64_t)off + (uint64_t)fsz > 0x01000000u) {
        fprintf(stderr, "offset 0x%x + %ld B exceeds the 16 MB (3-byte) range\n", off, fsz);
        fclose(f); return 1;
    }
    uint8_t *img = malloc((size_t)fsz);
    if (!img) { fprintf(stderr, "out of memory (%ld bytes)\n", fsz); fclose(f); return 1; }
    if (fread(img, 1, (size_t)fsz, f) != (size_t)fsz) {
        fprintf(stderr, "short read on %s\n", file); free(img); fclose(f); return 1;
    }
    fclose(f);

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "backend open failed for %s -- is it a PacketWyrm card, "
                "bound to vfio-pci, and NOT in use by a running packetwyrmd?\n", bdf);
        free(img); return 1;
    }
    struct pw_card_info before = {0};
    if (be.ops->card_info) be.ops->card_info(be.ctx, &before);
    printf("card %s: build_id=0x%08x version=0x%08x num_flows=%u\n",
           bdf, before.device_id ? before.build_id : 0, before.version, before.num_local_flows);
    printf("writing %ld bytes to the %s region @ 0x%06x (live, PCIe stays up)...\n",
           fsz, scratch ? "scratch" : "BOOT", off);
    fflush(stdout);
    uint64_t mism = 0;
    pw_status s = pw_flash_program(be.ops, be.ctx, off, img, (size_t)fsz, &mism);
    free(img);
    if (s != PW_OK) { fprintf(stderr, "flash program failed (status %d)\n", s); return 1; }
    if (mism != 0) { fprintf(stderr, "VERIFY FAILED: %llu mismatched bytes\n",
                             (unsigned long long)mism); return 1; }
    printf("verify OK: %ld bytes match\n", fsz);

    if (!boot) {
        printf("done (flash written). Pass --boot to reload into it now, or power-cycle.\n");
        return 0;
    }
    if (scratch) {
        fprintf(stderr, "refusing --boot with --scratch: the boot loader reads offset 0, "
                "not the scratch region\n");
        return 2;
    }
    printf("triggering ICAP reload (PCIe link drops, FPGA reloads from flash)...\n");
    fflush(stdout);
    be.ops->write32(be.ctx, PWFPGA_REG_REBOOT, PWFPGA_REBOOT_MAGIC);
    pw_card_backend_close(&be);
    /* PCIe remove + rescan so the host re-enumerates the reloaded device. */
    char rm[256]; char cbdf[13];
    if (pw_pci_normalize_bdf(bdf, cbdf) != PW_OK) { fprintf(stderr, "bad BDF %s\n", bdf); return 1; }
    snprintf(rm, sizeof rm, "/sys/bus/pci/devices/%s/remove", cbdf);
    FILE *w = fopen(rm, "w"); if (w) { fputc('1', w); fclose(w); }
    struct timespec ts = { 2, 0 }; nanosleep(&ts, NULL);
    w = fopen("/sys/bus/pci/rescan", "w"); if (w) { fputc('1', w); fclose(w); }
    nanosleep(&ts, NULL);
    pw_vfio_bind(bdf);
    struct pw_card_backend be2;
    if (pw_bar_backend_open(bdf, &be2) != PW_OK) {
        fprintf(stderr, "card did not re-enumerate after reload -- recover via JTAG\n");
        return 1;
    }
    struct pw_card_info after = {0};
    if (be2.ops->card_info) be2.ops->card_info(be2.ctx, &after);
    pw_card_backend_close(&be2);
    printf("reloaded: build_id 0x%08x -> 0x%08x\n", before.build_id, after.build_id);
    if (after.build_id == before.build_id) {
        fprintf(stderr, "WARNING: build_id unchanged -- the new image may not have "
                "booted (check the .bin, or the flash write region)\n");
        return 1;
    }
    printf("firmware update OK: card is running the new image.\n");
    return 0;
}

static int cmd_help(void) {
    puts("pktwyrm - PacketWyrm CLI");
    puts("");
    puts("Offline commands (operate on a YAML file):");
    puts("  pktwyrm init  [--out FILE]           generate an env-config skeleton from discovered cards");
    puts("  pktwyrm cards                        discover real PacketWyrm PCI cards");
    puts("  pktwyrm cards <config.yaml>          list configured cards from YAML");
    puts("  pktwyrm ports <config.yaml>          list configured ports");
    puts("  pktwyrm map   <config.yaml>          show port -> logical-if map");
    puts("  pktwyrm load  <config.yaml> [--check]  validate offline (--check), else deploy");
    puts("  pktwyrm flow show <config.yaml>      list flows");
    puts("  pktwyrm flow preview <config.yaml> [--flow ID] [--seq N] [--json]  decode+hexdump the generated frame");
    puts("  pktwyrm version");
    puts("");
    puts("Online (talks to a running packetwyrmd over a Unix socket):");
    puts("  pktwyrm rpc version");
    puts("  pktwyrm rpc cards|ports|flows|stats [--socket PATH] [--card N]");
    puts("  pktwyrm stats [--socket PATH] [--card N] [--watch MS] [--json]");
    puts("  pktwyrm latency [--flow N] [--socket PATH] [--json]   per-flow one-way latency");
    puts("                  (same-card: exact; cross-card: J5 GPIO-corrected)");
    puts("  pktwyrm sfp [--card N] [--port P] [--socket PATH] [--json]  SFP id + DOM");
    puts("  pktwyrm tap [--socket PATH] [--json]                 host-plane TAP status + stats");
    puts("  pktwyrm flow start|stop <id> [--socket PATH]");
    puts("  pktwyrm flow stats [--flow N] [--socket PATH] [--watch MS] [--json]");
    puts("  pktwyrm test arm|start|stop [--socket PATH] [--json]");
    puts("  pktwyrm test run [--duration 10s] [--socket PATH] [--json]  arm+start+wait+stop, PASS/FAIL");
    puts("  pktwyrm hist latency --flow N [--socket PATH] [--json]");
    puts("  pktwyrm load <config.yaml> [--socket PATH]      deploy a config to the daemon (default)");
    puts("");
    puts("Firmware (LOCAL, direct card -- root, card free of any daemon):");
    puts("  pktwyrm firmware update <file.bin> --card BDF [--boot] [--scratch]");
    puts("                 validate + live-flash + verify (+ reload with --boot)");
    puts("");
    puts("Global flags (may appear anywhere):");
    puts("  --secret S     control-socket secret (else $PACKETWYRM_SECRET, else --env file)");
    puts("  --env PATH     env config to read the secret from (default /etc/packetwyrm/packetwyrm.yaml)");
    puts("  --host H[:P]   talk to a remote packetwyrm-proxyd over HTTPS (default port 8443)");
    puts("                 instead of the local Unix socket; --socket is then ignored");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return cmd_help();
    /* Consume the global flags (may appear anywhere): --secret S / --env PATH
     * set where the control-socket secret comes from (see resolve_secret).
     * Filter them out of argv so subcommand parsing never sees them (and a
     * leading `--secret S subcmd` still resolves the subcommand). */
    char *fargv[argc]; int fargc = 0;
    fargv[fargc++] = argv[0];
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--secret") && i + 1 < argc)      g_secret_arg = argv[++i];
        else if (!strcmp(argv[i], "--env") && i + 1 < argc)    g_env_arg    = argv[++i];
        else if (!strcmp(argv[i], "--host") && i + 1 < argc)   g_host_arg   = argv[++i];
        else fargv[fargc++] = argv[i];
    }
    argv = fargv; argc = fargc;
    if (argc < 2) return cmd_help();
    const char *sub = argv[1];
    if (!strcmp(sub, "help") || !strcmp(sub, "-h") || !strcmp(sub, "--help")) return cmd_help();
    if (!strcmp(sub, "version") || !strcmp(sub, "--version")) {
        printf("pktwyrm %s\n", pw_version_string()); return 0;
    }
    if (!strcmp(sub, "firmware")) return cmd_firmware(argc - 2, argv + 2);
    if (!strcmp(sub, "init"))   return cmd_init(argc - 2, argv + 2);
    if (!strcmp(sub, "cards"))  return cmd_cards(argc - 2, argv + 2);
    if (!strcmp(sub, "ports"))  return cmd_ports(argc - 2, argv + 2);
    if (!strcmp(sub, "map"))    return cmd_map(argc - 2, argv + 2);
    if (!strcmp(sub, "load"))   return cmd_load(argc - 2, argv + 2);
    if (!strcmp(sub, "rpc"))    return cmd_rpc(argc - 2, argv + 2);
    if (!strcmp(sub, "latency")) return cmd_latency(argc - 2, argv + 2);
    if (!strcmp(sub, "sfp"))    return cmd_sfp(argc - 2, argv + 2);
    if (!strcmp(sub, "tap"))    return cmd_tap(argc - 2, argv + 2);
    if (!strcmp(sub, "stats")) {
        /* `pktwyrm stats clear` -> re-baseline all counters (RX checkers,
         * per-port frames/bytes, drops, histogram) via the daemon, independent
         * of test arm/start/stop. Plain `pktwyrm stats` reads/prints. */
        if (argc >= 3 && !strcmp(argv[2], "clear")) {
            const char *sock = PW_IPC_DEFAULT_PATH;
            for (int i = 3; i < argc; i++)
                if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
            char resp[PW_IPC_FRAME_MAX]; size_t got = 0;
            if (rpc_call(sock, "{\"rpc\":\"stats.clear\"}", resp, sizeof(resp), &got) < 0) {
                rpc_fail(sock);
                return 1;
            }
            fwrite(resp, 1, got, stdout); fputc('\n', stdout);
            return 0;
        }
        return cmd_stats(argc - 2, argv + 2);
    }
    if (!strcmp(sub, "hist")) {
        if (argc < 4 || strcmp(argv[2], "latency")) {
            fprintf(stderr,
                "usage: pktwyrm hist latency --flow N [--socket PATH] [--json]\n");
            return 2;
        }
        const char *sock = PW_IPC_DEFAULT_PATH;
        int flow_id = -1;
        bool raw = false;
        for (int i = 3; i < argc; i++) {
            if (!strcmp(argv[i], "--flow") && i + 1 < argc) flow_id = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
            else if (!strcmp(argv[i], "--json")) raw = true;
        }
        if (flow_id < 0) { fprintf(stderr, "--flow required\n"); return 2; }
        char req[128];
        snprintf(req, sizeof(req), "{\"rpc\":\"flow.hist\",\"id\":%d}", flow_id);
        char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
        if (rpc_call(sock, req, resp, sizeof(resp), &got) < 0) {
            rpc_fail(sock); return 1;
        }
        if (raw) { fwrite(resp, 1, got, stdout); fputc('\n', stdout); return 0; }
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
            /* RTL log2_bucket = highest set bit of the latency in ticks, so
             * bucket i holds [2^i, 2^(i+1)) ticks -- except bucket 0, which
             * holds [0, 2) ticks (values 0 and 1) and needs an upper bound. */
            if (i == 0)
                printf("  [%2zu] (<  %lu ns) %10ld  %s\n",
                       i, pw_ticks_to_ns(2ULL), (long)v, line);
            else
                printf("  [%2zu] (>= %lu ns) %10ld  %s\n",
                       i, pw_ticks_to_ns(1ULL << i), (long)v, line);
        }
        json_object_put(root);
        return 0;
    }
    if (!strcmp(sub, "test")) {
        if (argc < 3) {
            fprintf(stderr,
                "usage: pktwyrm test arm|start|stop [--socket PATH] [--json]\n"
                "       pktwyrm test run [--duration 10s] [--socket PATH] [--json]\n");
            return 2;
        }
        const char *action = argv[2];
        if (!strcmp(action, "run")) return cmd_test_run(argc - 3, argv + 3);
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
            rpc_fail(sock);
            return 1;
        }
        fwrite(resp, 1, got, stdout); fputc('\n', stdout);
        return 0;
    }
    if (!strcmp(sub, "flash")) {
        if (argc < 3) {
            fprintf(stderr,
                "usage: pktwyrm flash write <file> [--offset 0xADDR] [--socket PATH]\n"
                "       pktwyrm flash id [--socket PATH]\n"
                "  Live config-flash write over PCIe (FPGA keeps running). Default\n"
                "  offset 0x00E00000 (scratch, past the boot image); 0 = boot image.\n");
            return 2;
        }
        const char *what = argv[2];
        const char *sock = PW_IPC_DEFAULT_PATH;
        if (!strcmp(what, "id")) {
            for (int i = 3; i < argc; i++)
                if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
            char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
            if (rpc_call(sock, "{\"rpc\":\"flash.id\"}", resp, sizeof(resp), &got) < 0) {
                rpc_fail(sock); return 1;
            }
            fwrite(resp, 1, got, stdout); fputc('\n', stdout);
            return 0;
        }
        if (!strcmp(what, "write")) {
            if (argc < 4) { fprintf(stderr, "usage: pktwyrm flash write <file> [--offset 0xADDR] [--socket PATH]\n"); return 2; }
            const char *file = argv[3];
            long off = 0x00E00000;
            for (int i = 4; i < argc; i++) {
                if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock = argv[++i];
                else if (!strcmp(argv[i], "--offset") && i + 1 < argc) off = strtol(argv[++i], NULL, 0);
            }
            /* Absolute path so the daemon (any cwd) opens the right file. */
            char abspath[4096];
            if (!realpath(file, abspath)) { fprintf(stderr, "cannot resolve %s\n", file); return 1; }
            struct json_object *req = json_object_new_object();
            json_object_object_add(req, "rpc",    json_object_new_string("flash.write"));
            json_object_object_add(req, "path",   json_object_new_string(abspath));
            json_object_object_add(req, "offset", json_object_new_int64(off));
            const char *req_str = json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN);
            char  resp[PW_IPC_FRAME_MAX]; size_t got = 0;
            int rc = rpc_call(sock, req_str, resp, sizeof(resp), &got);
            json_object_put(req);
            if (rc < 0) { rpc_fail(sock); return 1; }
            fwrite(resp, 1, got, stdout); fputc('\n', stdout);
            struct json_tokener *tk = json_tokener_new();
            struct json_object  *r  = json_tokener_parse_ex(tk, resp, (int)got);
            json_tokener_free(tk);
            int ok = 0;
            if (r) { struct json_object *v;
                     if (json_object_object_get_ex(r, "verified", &v)) ok = json_object_get_boolean(v);
                     json_object_put(r); }
            return ok ? 0 : 1;
        }
        fprintf(stderr, "unknown flash subcommand: %s\n", what);
        return 2;
    }
    if (!strcmp(sub, "flow")) {
        if (argc < 3) {
            fprintf(stderr,
                "usage: pktwyrm flow show <config.yaml>\n"
                "       pktwyrm flow preview <config.yaml> [--flow ID] [--seq N] [--json]\n"
                "       pktwyrm flow start <id> [--socket PATH]\n"
                "       pktwyrm flow stop  <id> [--socket PATH]\n");
            return 2;
        }
        const char *what = argv[2];
        if (!strcmp(what, "show")) return cmd_flow_show(argc - 3, argv + 3);
        if (!strcmp(what, "preview")) return cmd_flow_preview(argc - 3, argv + 3);
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
                    rpc_fail(sock);
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
                        printf("%-4s %-19s %10s %10s %8s %8s %8s %10s %10s %10s %s\n",
                               "id", "path (tx->rx)", "tx_frames", "rx_frames",
                               "lost", "dup", "reord",
                               "min_ns", "avg_ns", "max_ns", "lat_valid");
                        size_t n = json_object_array_length(arr);
                        for (size_t i = 0; i < n; i++) {
                            struct json_object *f = json_object_array_get_idx(arr, i);
                            struct json_object *v;
                            int64_t fid=0,tx=0,rx=0,lost=0,dup=0,reord=0;
                            int64_t mn=0,mx=0,avg=0,samp=0; bool lv=false;
                            const char *txp="?", *rxp="?";
                            #define GETI(k, dst) do { if (json_object_object_get_ex(f, k, &v)) dst = json_object_get_int64(v); } while(0)
                            #define GETB(k, dst) do { if (json_object_object_get_ex(f, k, &v)) dst = json_object_get_boolean(v); } while(0)
                            #define GETS(k, dst) do { if (json_object_object_get_ex(f, k, &v)) dst = json_object_get_string(v); } while(0)
                            GETI("id", fid);
                            GETS("tx_port", txp);
                            GETS("rx_port", rxp);
                            GETI("tx_frames", tx);
                            GETI("rx_frames", rx);
                            GETI("lost", lost);
                            GETI("duplicate", dup);
                            GETI("out_of_order", reord);
                            GETI("min_latency", mn);
                            GETI("max_latency", mx);
                            GETI("avg_latency", avg);
                            GETI("sample_count", samp);
                            GETB("latency_valid", lv);
                            #undef GETI
                            #undef GETB
                            #undef GETS
                            char path[4*PW_NAME_MAX+4];
                            snprintf(path, sizeof path, "%s->%s", txp, rxp);
                            /* No samples yet (no traffic / not started) -> show
                             * "-" rather than a latency number: min in HW is a
                             * 0xFFFFFFFF sentinel until the first packet, and 0
                             * would read as a real 0 ns measurement. */
                            char mns[16], ans[16], xns[16];
                            if (lv && samp > 0) {
                                snprintf(mns, sizeof mns, "%ld", (long)pw_ticks_to_ns((unsigned long long)mn));
                                snprintf(ans, sizeof ans, "%ld", (long)pw_ticks_to_ns((unsigned long long)avg));
                                snprintf(xns, sizeof xns, "%ld", (long)pw_ticks_to_ns((unsigned long long)mx));
                            } else {
                                snprintf(mns, sizeof mns, "-");
                                snprintf(ans, sizeof ans, "-");
                                snprintf(xns, sizeof xns, "-");
                            }
                            printf("%-4ld %-19s %10ld %10ld %8ld %8ld %8ld %10s %10s %10s %s\n",
                                   (long)fid, path,
                                   (long)tx, (long)rx,
                                   (long)lost, (long)dup, (long)reord,
                                   mns, ans, xns,
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
                rpc_fail(sock);
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
