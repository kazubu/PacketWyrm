/* YAML AST -> pw_config schema walker plus pw_config bookkeeping. */

#include "packetwyrm/config.h"
#include "packetwyrm/csr.h"
#include "scalar.h"
#include "yaml.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void diag_set(struct pw_diag *d, pw_status code, const char *path, const char *fmt, ...) {
    if (!d) return;
    d->code = code;
    if (path) snprintf(d->path, sizeof(d->path), "%s", path);
    else d->path[0] = '\0';
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(d->message, sizeof(d->message), fmt, ap);
    va_end(ap);
}

static void copy_str(char *dst, size_t dstn, const char *src) {
    if (!dstn) return;
    if (!src) { dst[0] = '\0'; return; }
    size_t i = 0;
    for (; i + 1 < dstn && src[i]; i++) dst[i] = src[i];
    dst[i] = '\0';
}

struct pw_config *pw_config_new(void) {
    return (struct pw_config *)calloc(1, sizeof(struct pw_config));
}

void pw_config_free(struct pw_config *cfg) {
    if (!cfg) return;
    free(cfg->cards);
    free(cfg->logical_if);
    free(cfg->flows);
    free(cfg->forwards);
    free(cfg);
}

const struct pw_card *pw_config_card_by_id(const struct pw_config *cfg, uint16_t card_id) {
    if (!cfg) return NULL;
    for (size_t i = 0; i < cfg->n_cards; i++)
        if (cfg->cards[i].id == card_id) return &cfg->cards[i];
    return NULL;
}

const struct pw_logical_if *pw_config_logical_if_by_id(const struct pw_config *cfg, uint32_t lif_id) {
    if (!cfg) return NULL;
    for (size_t i = 0; i < cfg->n_logical_if; i++)
        if (cfg->logical_if[i].id == lif_id) return &cfg->logical_if[i];
    return NULL;
}

const struct pw_flow *pw_config_flow_by_id(const struct pw_config *cfg, uint32_t flow_id) {
    if (!cfg) return NULL;
    for (size_t i = 0; i < cfg->n_flows; i++)
        if (cfg->flows[i].id == flow_id) return &cfg->flows[i];
    return NULL;
}

pw_status pw_config_resolve_port(const struct pw_config *cfg, uint16_t gp, struct pwfpga_port_ref *out) {
    if (!cfg || !out) return PW_E_INVAL;
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *c = &cfg->cards[i];
        for (size_t j = 0; j < c->n_ports; j++) {
            if (c->ports[j].global_port == gp) {
                out->card_id = c->id;
                out->local_port_id = c->ports[j].local_port;
                out->global_port_id = gp;
                return PW_OK;
            }
        }
    }
    return PW_E_UNKNOWN_GLOBAL_PORT;
}

/* --- schema walker --- */

#define REQ_MAP(node, path) do { \
    if (!(node) || (node)->kind != PW_YAML_MAP) { \
        diag_set(diag, PW_E_PARSE, (path), "expected mapping"); \
        return PW_E_PARSE; \
    } \
} while (0)

#define REQ_SEQ(node, path) do { \
    if (!(node) || (node)->kind != PW_YAML_SEQ) { \
        diag_set(diag, PW_E_PARSE, (path), "expected sequence"); \
        return PW_E_PARSE; \
    } \
} while (0)

static pw_status get_scalar(const pw_yaml_node *m, const char *key, const char *path_prefix,
                            bool required, const char **out, struct pw_diag *diag) {
    const pw_yaml_node *v = pw_yaml_map_get(m, key);
    if (!v) {
        if (required) {
            char buf[256];
            snprintf(buf, sizeof(buf), "%s.%s", path_prefix, key);
            diag_set(diag, PW_E_MISSING_FIELD, buf, "missing required field");
            return PW_E_MISSING_FIELD;
        }
        *out = NULL;
        return PW_OK;
    }
    if (v->kind != PW_YAML_SCALAR) {
        char buf[256];
        snprintf(buf, sizeof(buf), "%s.%s", path_prefix, key);
        diag_set(diag, PW_E_PARSE, buf, "expected scalar");
        return PW_E_PARSE;
    }
    *out = v->u.scalar.value;
    return PW_OK;
}

static pw_status parse_system(const pw_yaml_node *m, struct pw_system *sys, struct pw_diag *diag) {
    REQ_MAP(m, "system");
    const char *s;
    pw_status r;

    if ((r = get_scalar(m, "name", "system", true, &s, diag)) != PW_OK) return r;
    copy_str(sys->name, sizeof(sys->name), s);

    if ((r = get_scalar(m, "mode", "system", true, &s, diag)) != PW_OK) return r;
    copy_str(sys->mode, sizeof(sys->mode), s);
    if (strcmp(sys->mode, "multi-card") != 0) {
        diag_set(diag, PW_E_INVAL, "system.mode", "must be \"multi-card\"");
        return PW_E_INVAL;
    }

    if ((r = get_scalar(m, "default_speed", "system", true, &s, diag)) != PW_OK) return r;
    copy_str(sys->default_speed, sizeof(sys->default_speed), s);
    if (strcmp(sys->default_speed, "10g") != 0) {
        diag_set(diag, PW_E_INVAL, "system.default_speed", "only \"10g\" is supported");
        return PW_E_INVAL;
    }

    if ((r = get_scalar(m, "stats_poll_interval_ms", "system", false, &s, diag)) != PW_OK) return r;
    sys->stats_poll_interval_ms = 100;
    if (s && !pw_parse_u32(s, &sys->stats_poll_interval_ms)) {
        diag_set(diag, PW_E_PARSE, "system.stats_poll_interval_ms", "expected unsigned integer");
        return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "control_socket", "system", false, &s, diag)) != PW_OK) return r;
    copy_str(sys->control_socket, sizeof(sys->control_socket),
             s ? s : "/var/run/packetwyrm/packetwyrmd.sock");

    return PW_OK;
}

static pw_status parse_card_port(const pw_yaml_node *m, struct pw_card_port *p,
                                 const char *path, struct pw_diag *diag) {
    REQ_MAP(m, path);
    const char *s;
    pw_status r;

    if ((r = get_scalar(m, "local_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u8(s, &p->local_port) || p->local_port >= PW_PORTS_PER_CARD) {
        diag_set(diag, PW_E_OUT_OF_RANGE, path, "local_port must be 0 or 1");
        return PW_E_OUT_OF_RANGE;
    }

    if ((r = get_scalar(m, "global_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &p->global_port)) {
        diag_set(diag, PW_E_PARSE, path, "global_port must be unsigned integer");
        return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "name", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(p->name, sizeof(p->name), s);
    else snprintf(p->name, sizeof(p->name), "p%u", (unsigned)p->global_port);

    return PW_OK;
}

static pw_status parse_card(const pw_yaml_node *m, struct pw_card *c,
                            size_t idx, struct pw_diag *diag) {
    char path[64];
    snprintf(path, sizeof(path), "cards[%zu]", idx);
    REQ_MAP(m, path);
    const char *s;
    pw_status r;

    if ((r = get_scalar(m, "id", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &c->id)) {
        diag_set(diag, PW_E_PARSE, path, "id must be unsigned integer"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "name", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(c->name, sizeof(c->name), s);
    else snprintf(c->name, sizeof(c->name), "card%u", (unsigned)c->id);

    if ((r = get_scalar(m, "pci", path, true, &s, diag)) != PW_OK) return r;
    copy_str(c->pci, sizeof(c->pci), s);

    const pw_yaml_node *ports = pw_yaml_map_get(m, "ports");
    char ppath[80];
    snprintf(ppath, sizeof(ppath), "%s.ports", path);
    REQ_SEQ(ports, ppath);
    if (ports->u.seq.n == 0 || ports->u.seq.n > PW_PORTS_PER_CARD) {
        diag_set(diag, PW_E_OUT_OF_RANGE, ppath, "must have 1 or 2 entries");
        return PW_E_OUT_OF_RANGE;
    }
    c->n_ports = ports->u.seq.n;
    for (size_t i = 0; i < c->n_ports; i++) {
        char pp[96];
        snprintf(pp, sizeof(pp), "%s[%zu]", ppath, i);
        if ((r = parse_card_port(ports->u.seq.items[i], &c->ports[i], pp, diag)) != PW_OK)
            return r;
    }
    return PW_OK;
}

static pw_status parse_logical_if(const pw_yaml_node *m, struct pw_logical_if *lif,
                                  size_t idx, struct pw_diag *diag) {
    char path[80];
    snprintf(path, sizeof(path), "logical_interfaces[%zu]", idx);
    REQ_MAP(m, path);
    const char *s;
    pw_status r;

    if ((r = get_scalar(m, "id", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u32(s, &lif->id)) {
        diag_set(diag, PW_E_PARSE, path, "id must be unsigned integer"); return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "global_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &lif->global_port)) {
        diag_set(diag, PW_E_PARSE, path, "global_port must be unsigned integer"); return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "vlan", path, false, &s, diag)) != PW_OK) return r;
    lif->vlan = 0;
    if (s && (!pw_parse_u16(s, &lif->vlan) || lif->vlan >= 4095)) {
        diag_set(diag, PW_E_OUT_OF_RANGE, path, "vlan must be 0..4094"); return PW_E_OUT_OF_RANGE;
    }

    if ((r = get_scalar(m, "name", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(lif->name, sizeof(lif->name), s);
    else pw_tap_name(lif->name, sizeof(lif->name), lif->global_port, lif->vlan);

    if ((r = get_scalar(m, "mac", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_mac(s, lif->mac)) {
        diag_set(diag, PW_E_PARSE, path, "mac must be aa:bb:cc:dd:ee:ff"); return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "mtu", path, false, &s, diag)) != PW_OK) return r;
    lif->mtu = 1500;
    if (s && !pw_parse_u16(s, &lif->mtu)) {
        diag_set(diag, PW_E_PARSE, path, "mtu must be unsigned integer"); return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "netns", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(lif->netns, sizeof(lif->netns), s);

    const pw_yaml_node *punt = pw_yaml_map_get(m, "punt");
    if (punt) {
        char ppath[112];
        snprintf(ppath, sizeof(ppath), "%s.punt", path);
        REQ_MAP(punt, ppath);
#define PUNT(field) do { \
            const char *pv = NULL; \
            if ((r = get_scalar(punt, #field, ppath, false, &pv, diag)) != PW_OK) return r; \
            if (pv && !pw_parse_bool(pv, &lif->punt.field)) { \
                diag_set(diag, PW_E_PARSE, ppath, "punt." #field " must be boolean"); \
                return PW_E_PARSE; \
            } \
        } while (0)
        PUNT(arp); PUNT(ipv6_nd); PUNT(lldp); PUNT(icmp);
        PUNT(bgp); PUNT(ospf); PUNT(is_is);
#undef PUNT
    }

    return PW_OK;
}

/* Parse one optional field-modifier submap: { mode: static|increment|random,
 * mask: <u32> }. Absent key leaves the modifier at its zeroed default. */
static pw_status parse_field_mod(const pw_yaml_node *parent, const char *key,
                                 const char *path, struct pw_field_mod *fm,
                                 struct pw_diag *diag) {
    const pw_yaml_node *n = pw_yaml_map_get(parent, key);
    if (!n) return PW_OK;
    char p[112]; snprintf(p, sizeof(p), "%s.%s", path, key);
    REQ_MAP(n, p);
    const char *s; pw_status r;
    if ((r = get_scalar(n, "mode", p, false, &s, diag)) != PW_OK) return r;
    if (s) {
        if      (!strcmp(s, "static"))    fm->mode = 0;
        else if (!strcmp(s, "increment")) fm->mode = 1;
        else if (!strcmp(s, "random"))    fm->mode = 2;
        else { diag_set(diag, PW_E_PARSE, p, "mode must be static|increment|random"); return PW_E_PARSE; }
    }
    if ((r = get_scalar(n, "mask", p, false, &s, diag)) != PW_OK) return r;
    if (s && (!pw_parse_u64(s, &fm->mask) || fm->mask > 0xFFFFFFFFFFFFull)) {
        diag_set(diag, PW_E_PARSE, p, "mask must be an unsigned (hex/dec) value <= 48 bits"); return PW_E_PARSE;
    }
    return PW_OK;
}

static pw_status parse_flow(const pw_yaml_node *m, struct pw_flow *f,
                            size_t idx, struct pw_diag *diag) {
    char path[64];
    snprintf(path, sizeof(path), "flows[%zu]", idx);
    REQ_MAP(m, path);
    const char *s;
    pw_status r;

    if ((r = get_scalar(m, "id", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u32(s, &f->id)) {
        diag_set(diag, PW_E_PARSE, path, "id must be unsigned integer"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "name", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(f->name, sizeof(f->name), s);

    if ((r = get_scalar(m, "tx_global_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &f->tx_global_port)) {
        diag_set(diag, PW_E_PARSE, path, "tx_global_port must be unsigned integer"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "rx_global_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &f->rx_global_port)) {
        diag_set(diag, PW_E_PARSE, path, "rx_global_port must be unsigned integer"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "logical_if_id", path, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u32(s, &f->logical_if_id)) {
        diag_set(diag, PW_E_PARSE, path, "logical_if_id must be unsigned integer"); return PW_E_PARSE;
    }

    /* l2 */
    const pw_yaml_node *l2 = pw_yaml_map_get(m, "l2");
    if (l2) {
        char l2p[96]; snprintf(l2p, sizeof(l2p), "%s.l2", path);
        REQ_MAP(l2, l2p);
        if ((r = get_scalar(l2, "src_mac", l2p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_mac(s, f->l2.src_mac)) {
            diag_set(diag, PW_E_PARSE, l2p, "src_mac"); return PW_E_PARSE;
        }
        if ((r = get_scalar(l2, "dst_mac", l2p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_mac(s, f->l2.dst_mac)) {
            diag_set(diag, PW_E_PARSE, l2p, "dst_mac"); return PW_E_PARSE;
        }
        if ((r = get_scalar(l2, "vlan", l2p, false, &s, diag)) != PW_OK) return r;
        if (s) {
            if (!pw_parse_u16(s, &f->l2.vlan) || f->l2.vlan >= 4095) {
                diag_set(diag, PW_E_OUT_OF_RANGE, l2p, "vlan must be 0..4094"); return PW_E_OUT_OF_RANGE;
            }
            f->l2.vlan_set = true;
        }
        if ((r = get_scalar(l2, "pcp", l2p, false, &s, diag)) != PW_OK) return r;
        if (s && !pw_parse_u8(s, &f->l2.pcp)) {
            diag_set(diag, PW_E_PARSE, l2p, "pcp"); return PW_E_PARSE;
        }
    }

    /* exactly one of ipv4 / ipv6 */
    const pw_yaml_node *v4 = pw_yaml_map_get(m, "ipv4");
    const pw_yaml_node *v6 = pw_yaml_map_get(m, "ipv6");
    if (v4 && v6) {
        diag_set(diag, PW_E_INVAL, path, "set exactly one of ipv4 / ipv6"); return PW_E_INVAL;
    }
    if (!v4 && !v6) {
        diag_set(diag, PW_E_MISSING_FIELD, path, "flow requires an ipv4 or ipv6 block");
        return PW_E_MISSING_FIELD;
    }
    if (v6) {
        char v6p[96]; snprintf(v6p, sizeof(v6p), "%s.ipv6", path);
        REQ_MAP(v6, v6p);
        if ((r = get_scalar(v6, "src", v6p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_ipv6(s, f->ipv6.src)) {
            diag_set(diag, PW_E_PARSE, v6p, "src must be an IPv6 address"); return PW_E_PARSE;
        }
        if ((r = get_scalar(v6, "dst", v6p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_ipv6(s, f->ipv6.dst)) {
            diag_set(diag, PW_E_PARSE, v6p, "dst must be an IPv6 address"); return PW_E_PARSE;
        }
        f->ipv6.hop_limit = 64;
        if ((r = get_scalar(v6, "hop_limit", v6p, false, &s, diag)) != PW_OK) return r;
        if (s && !pw_parse_u8(s, &f->ipv6.hop_limit)) {
            diag_set(diag, PW_E_PARSE, v6p, "hop_limit"); return PW_E_PARSE;
        }
        if ((r = get_scalar(v6, "dscp", v6p, false, &s, diag)) != PW_OK) return r;
        if (s && (!pw_parse_u8(s, &f->ipv6.dscp) || f->ipv6.dscp > 63)) {
            diag_set(diag, PW_E_OUT_OF_RANGE, v6p, "dscp 0..63"); return PW_E_OUT_OF_RANGE;
        }
        f->ipv6.present = true;
    } else {
        char v4p[96]; snprintf(v4p, sizeof(v4p), "%s.ipv4", path);
        REQ_MAP(v4, v4p);
        if ((r = get_scalar(v4, "src", v4p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_ipv4(s, &f->ipv4.src)) {
            diag_set(diag, PW_E_PARSE, v4p, "src must be IPv4 address"); return PW_E_PARSE;
        }
        if ((r = get_scalar(v4, "dst", v4p, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_ipv4(s, &f->ipv4.dst)) {
            diag_set(diag, PW_E_PARSE, v4p, "dst must be IPv4 address"); return PW_E_PARSE;
        }
        if ((r = get_scalar(v4, "ttl", v4p, false, &s, diag)) != PW_OK) return r;
        f->ipv4.ttl = 64;
        if (s && !pw_parse_u8(s, &f->ipv4.ttl)) { diag_set(diag, PW_E_PARSE, v4p, "ttl"); return PW_E_PARSE; }
        if ((r = get_scalar(v4, "dscp", v4p, false, &s, diag)) != PW_OK) return r;
        if (s && (!pw_parse_u8(s, &f->ipv4.dscp) || f->ipv4.dscp > 63)) {
            diag_set(diag, PW_E_OUT_OF_RANGE, v4p, "dscp 0..63"); return PW_E_OUT_OF_RANGE;
        }
        f->ipv4.present = true;
    }

    /* udp */
    const pw_yaml_node *udp = pw_yaml_map_get(m, "udp");
    if (!udp) {
        diag_set(diag, PW_E_MISSING_FIELD, path, "flow requires udp block"); return PW_E_MISSING_FIELD;
    }
    char up[96]; snprintf(up, sizeof(up), "%s.udp", path);
    REQ_MAP(udp, up);
    if ((r = get_scalar(udp, "src_port", up, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &f->udp.src_port)) { diag_set(diag, PW_E_PARSE, up, "src_port"); return PW_E_PARSE; }
    if ((r = get_scalar(udp, "dst_port", up, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &f->udp.dst_port)) { diag_set(diag, PW_E_PARSE, up, "dst_port"); return PW_E_PARSE; }

    /* traffic */
    const pw_yaml_node *tr = pw_yaml_map_get(m, "traffic");
    if (!tr) {
        diag_set(diag, PW_E_MISSING_FIELD, path, "flow requires traffic block"); return PW_E_MISSING_FIELD;
    }
    char tp[96]; snprintf(tp, sizeof(tp), "%s.traffic", path);
    REQ_MAP(tr, tp);
    if ((r = get_scalar(tr, "frame_len", tp, false, &s, diag)) != PW_OK) return r;
    if (s) {
        if (!pw_parse_u16(s, &f->traffic.frame_len_fixed)) {
            diag_set(diag, PW_E_PARSE, tp, "frame_len"); return PW_E_PARSE;
        }
        f->traffic.frame_len_fixed_set = true;
    } else {
        if ((r = get_scalar(tr, "frame_len_min", tp, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_u16(s, &f->traffic.frame_len_min)) { diag_set(diag, PW_E_PARSE, tp, "frame_len_min"); return PW_E_PARSE; }
        if ((r = get_scalar(tr, "frame_len_max", tp, true, &s, diag)) != PW_OK) return r;
        if (!pw_parse_u16(s, &f->traffic.frame_len_max)) { diag_set(diag, PW_E_PARSE, tp, "frame_len_max"); return PW_E_PARSE; }
        if ((r = get_scalar(tr, "frame_len_step", tp, false, &s, diag)) != PW_OK) return r;
        f->traffic.frame_len_step = 1;
        if (s && !pw_parse_u16(s, &f->traffic.frame_len_step)) { diag_set(diag, PW_E_PARSE, tp, "frame_len_step"); return PW_E_PARSE; }
    }
    if ((r = get_scalar(tr, "rate_bps", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u64(s, &f->traffic.rate_bps)) { diag_set(diag, PW_E_PARSE, tp, "rate_bps"); return PW_E_PARSE; }
    if ((r = get_scalar(tr, "rate_pps", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u64(s, &f->traffic.rate_pps)) { diag_set(diag, PW_E_PARSE, tp, "rate_pps"); return PW_E_PARSE; }
    if ((r = get_scalar(tr, "burst_size", tp, false, &s, diag)) != PW_OK) return r;
    f->traffic.burst_size = 1;
    if (s && !pw_parse_u32(s, &f->traffic.burst_size)) { diag_set(diag, PW_E_PARSE, tp, "burst_size"); return PW_E_PARSE; }
    if ((r = get_scalar(tr, "burst_gap_ticks", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u32(s, &f->traffic.burst_gap_ticks)) { diag_set(diag, PW_E_PARSE, tp, "burst_gap_ticks"); return PW_E_PARSE; }
    if ((r = get_scalar(tr, "payload", tp, false, &s, diag)) != PW_OK) return r;
    f->traffic.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    if (s) {
        if (!strcmp(s, "zero")) f->traffic.payload_mode = PWFPGA_PAYLOAD_ZERO;
        else if (!strcmp(s, "increment")) f->traffic.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
        else if (!strcmp(s, "prbs")) f->traffic.payload_mode = PWFPGA_PAYLOAD_PRBS;
        else if (!strcmp(s, "random")) f->traffic.payload_mode = PWFPGA_PAYLOAD_RANDOM;
        else { diag_set(diag, PW_E_INVAL, tp, "payload must be zero|increment|prbs|random"); return PW_E_INVAL; }
    }
    if ((r = get_scalar(tr, "payload_seed", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u32(s, &f->traffic.payload_seed)) { diag_set(diag, PW_E_PARSE, tp, "payload_seed"); return PW_E_PARSE; }
    f->traffic.insert_sequence = true;
    f->traffic.insert_timestamp = true;
    if ((r = get_scalar(tr, "insert_sequence", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_bool(s, &f->traffic.insert_sequence)) { diag_set(diag, PW_E_PARSE, tp, "insert_sequence"); return PW_E_PARSE; }
    if ((r = get_scalar(tr, "insert_timestamp", tp, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_bool(s, &f->traffic.insert_timestamp)) { diag_set(diag, PW_E_PARSE, tp, "insert_timestamp"); return PW_E_PARSE; }

    /* measurements */
    const pw_yaml_node *meas = pw_yaml_map_get(m, "measurements");
    if (meas) {
        char mp[96]; snprintf(mp, sizeof(mp), "%s.measurements", path);
        REQ_MAP(meas, mp);
#define MFLAG(field) do { \
            if ((r = get_scalar(meas, #field, mp, false, &s, diag)) != PW_OK) return r; \
            if (s && !pw_parse_bool(s, &f->meas.field)) { \
                diag_set(diag, PW_E_PARSE, mp, #field); return PW_E_PARSE; \
            } \
        } while (0)
        MFLAG(loss); MFLAG(latency); MFLAG(jitter);
#undef MFLAG
    }

    /* per-field modifiers (DUT-facing flow diversification) */
    const pw_yaml_node *mods = pw_yaml_map_get(m, "modifiers");
    if (mods) {
        char xp[96]; snprintf(xp, sizeof(xp), "%s.modifiers", path);
        REQ_MAP(mods, xp);
        /* Address modifiers use the flow's active family key (src_ipv4/dst_ipv4
         * for v4, src_ipv6/dst_ipv6 for v6); both populate the same wire slot,
         * which the generator applies to the active address (v6 = low 32 bits). */
        const char *src_key = f->ipv6.present ? "src_ipv6" : "src_ipv4";
        const char *dst_key = f->ipv6.present ? "dst_ipv6" : "dst_ipv4";
        if ((r = parse_field_mod(mods, src_key, xp, &f->mod.src_ipv4, diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, dst_key, xp, &f->mod.dst_ipv4, diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, "udp_src",  xp, &f->mod.udp_src,  diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, "udp_dst",  xp, &f->mod.udp_dst,  diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, "src_mac",  xp, &f->mod.src_mac,  diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, "dst_mac",  xp, &f->mod.dst_mac,  diag)) != PW_OK) return r;
        if ((r = parse_field_mod(mods, "vlan",     xp, &f->mod.vlan,     diag)) != PW_OK) return r;
    }

    /* Background (load) traffic: TX only, no classifier rule / measurement. */
    if ((r = get_scalar(m, "background", path, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_bool(s, &f->background)) {
        diag_set(diag, PW_E_PARSE, path, "background must be true/false"); return PW_E_PARSE;
    }

    /* Classifier match masks: default to a full (exact) match; an optional
     * `match:` block narrows them for partial-field classification. */
    f->match_udp_dst_mask  = 0xFFFFu;
    f->match_ipv4_dst_mask = 0xFFFFFFFFu;
    const pw_yaml_node *mm = pw_yaml_map_get(m, "match");
    if (mm) {
        char mp[96]; snprintf(mp, sizeof(mp), "%s.match", path);
        REQ_MAP(mm, mp);
        if ((r = get_scalar(mm, "udp_dst", mp, false, &s, diag)) != PW_OK) return r;
        if (s && !pw_parse_u16(s, &f->match_udp_dst_mask)) {
            diag_set(diag, PW_E_PARSE, mp, "udp_dst mask must be 16-bit"); return PW_E_PARSE;
        }
        if ((r = get_scalar(mm, "ipv4_dst", mp, false, &s, diag)) != PW_OK) return r;
        if (s && !pw_parse_u32(s, &f->match_ipv4_dst_mask)) {
            diag_set(diag, PW_E_PARSE, mp, "ipv4_dst mask must be 32-bit"); return PW_E_PARSE;
        }
    }

    return PW_OK;
}

static pw_status parse_forward(const pw_yaml_node *m, struct pw_forward_rule *fr,
                               size_t idx, struct pw_diag *diag) {
    char path[64];
    snprintf(path, sizeof(path), "forwards[%zu]", idx);
    REQ_MAP(m, path);
    const char *s;
    pw_status r;
    uint16_t u16;

    if ((r = get_scalar(m, "ingress_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &fr->ingress_port)) {
        diag_set(diag, PW_E_PARSE, path, "ingress_port must be unsigned integer"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "egress_port", path, true, &s, diag)) != PW_OK) return r;
    if (!pw_parse_u16(s, &fr->egress_port)) {
        diag_set(diag, PW_E_PARSE, path, "egress_port must be unsigned integer"); return PW_E_PARSE;
    }

    if ((r = get_scalar(m, "name", path, false, &s, diag)) != PW_OK) return r;
    if (s) copy_str(fr->name, sizeof(fr->name), s);

    fr->priority = 40;
    if ((r = get_scalar(m, "priority", path, false, &s, diag)) != PW_OK) return r;
    if (s) {
        if (!pw_parse_u8(s, &fr->priority)) {
            diag_set(diag, PW_E_OUT_OF_RANGE, path, "priority must be 0..255"); return PW_E_OUT_OF_RANGE;
        }
    }

    /* optional match key (0 / absent = don't care) */
    if ((r = get_scalar(m, "ethertype", path, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u16(s, &fr->ethertype)) {
        diag_set(diag, PW_E_PARSE, path, "ethertype must be a 16-bit value"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "ip_proto", path, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u8(s, &fr->ip_proto)) {
        diag_set(diag, PW_E_PARSE, path, "ip_proto must be 0..255"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "udp_dst", path, false, &s, diag)) != PW_OK) return r;
    if (s && !pw_parse_u16(s, &fr->udp_dst)) {
        diag_set(diag, PW_E_PARSE, path, "udp_dst must be a 16-bit value"); return PW_E_PARSE;
    }
    if ((r = get_scalar(m, "vlan", path, false, &s, diag)) != PW_OK) return r;
    if (s) {
        if (!pw_parse_u16(s, &u16) || u16 >= 4095) {
            diag_set(diag, PW_E_OUT_OF_RANGE, path, "vlan must be 0..4094"); return PW_E_OUT_OF_RANGE;
        }
        fr->vlan = u16;
    }
    return PW_OK;
}

static pw_status parse_root(const pw_yaml_node *root, struct pw_config *cfg, struct pw_diag *diag) {
    REQ_MAP(root, "");

    const pw_yaml_node *sys = pw_yaml_map_get(root, "system");
    pw_status r = parse_system(sys, &cfg->system, diag);
    if (r != PW_OK) return r;

    const pw_yaml_node *cards = pw_yaml_map_get(root, "cards");
    REQ_SEQ(cards, "cards");
    if (cards->u.seq.n > PW_MAX_CARDS) {
        diag_set(diag, PW_E_OUT_OF_RANGE, "cards", "too many cards (max %d)", PW_MAX_CARDS);
        return PW_E_OUT_OF_RANGE;
    }
    cfg->cards = (struct pw_card *)calloc(cards->u.seq.n, sizeof(struct pw_card));
    if (!cfg->cards) return PW_E_NO_RESOURCES;
    cfg->n_cards = cards->u.seq.n;
    for (size_t i = 0; i < cfg->n_cards; i++) {
        if ((r = parse_card(cards->u.seq.items[i], &cfg->cards[i], i, diag)) != PW_OK) return r;
    }

    const pw_yaml_node *lifs = pw_yaml_map_get(root, "logical_interfaces");
    if (lifs) {
        REQ_SEQ(lifs, "logical_interfaces");
        cfg->logical_if = (struct pw_logical_if *)calloc(lifs->u.seq.n, sizeof(struct pw_logical_if));
        if (!cfg->logical_if && lifs->u.seq.n) return PW_E_NO_RESOURCES;
        cfg->n_logical_if = lifs->u.seq.n;
        for (size_t i = 0; i < cfg->n_logical_if; i++) {
            if ((r = parse_logical_if(lifs->u.seq.items[i], &cfg->logical_if[i], i, diag)) != PW_OK) return r;
        }
    }

    const pw_yaml_node *flows = pw_yaml_map_get(root, "flows");
    if (flows) {
        REQ_SEQ(flows, "flows");
        cfg->flows = (struct pw_flow *)calloc(flows->u.seq.n, sizeof(struct pw_flow));
        if (!cfg->flows && flows->u.seq.n) return PW_E_NO_RESOURCES;
        cfg->n_flows = flows->u.seq.n;
        for (size_t i = 0; i < cfg->n_flows; i++) {
            if ((r = parse_flow(flows->u.seq.items[i], &cfg->flows[i], i, diag)) != PW_OK) return r;
        }
    }

    const pw_yaml_node *fwds = pw_yaml_map_get(root, "forwards");
    if (fwds) {
        REQ_SEQ(fwds, "forwards");
        cfg->forwards = (struct pw_forward_rule *)calloc(fwds->u.seq.n, sizeof(struct pw_forward_rule));
        if (!cfg->forwards && fwds->u.seq.n) return PW_E_NO_RESOURCES;
        cfg->n_forwards = fwds->u.seq.n;
        for (size_t i = 0; i < cfg->n_forwards; i++) {
            if ((r = parse_forward(fwds->u.seq.items[i], &cfg->forwards[i], i, diag)) != PW_OK) return r;
        }
    }

    return PW_OK;
}

pw_status pw_config_parse_string(const char *yaml, size_t len, struct pw_config *cfg, struct pw_diag *diag) {
    if (!yaml || !cfg) return PW_E_INVAL;
    if (diag) { diag->code = PW_OK; diag->path[0] = 0; diag->message[0] = 0; }
    pw_yaml_err yerr = { .message = {0}, .line = 0 };
    pw_yaml_node *root = pw_yaml_parse(yaml, len, &yerr);
    if (!root) {
        if (diag) {
            diag->code = PW_E_PARSE;
            snprintf(diag->path, sizeof(diag->path), "line %d", yerr.line);
            snprintf(diag->message, sizeof(diag->message), "%s",
                     yerr.message[0] ? yerr.message : "YAML parse error");
        }
        return PW_E_PARSE;
    }
    pw_status r = parse_root(root, cfg, diag);
    pw_yaml_free(root);
    return r;
}

pw_status pw_config_parse_file(const char *path, struct pw_config *cfg, struct pw_diag *diag) {
    if (!path || !cfg) return PW_E_INVAL;
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (diag) {
            diag->code = PW_E_IO;
            snprintf(diag->path, sizeof(diag->path), "%s", path);
            snprintf(diag->message, sizeof(diag->message), "open: %s", strerror(errno));
        }
        return PW_E_IO;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return PW_E_IO; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return PW_E_NO_RESOURCES; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    buf[got] = '\0';
    fclose(f);
    pw_status r = pw_config_parse_string(buf, got, cfg, diag);
    free(buf);
    return r;
}
