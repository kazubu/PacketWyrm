/* Flow compiler: turn a validated pw_config into per-card programming
 * records. See docs/design/flow-compiler.md. */

#include "packetwyrm/flow_compiler.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct pw_program *pw_program_new(void) {
    return (struct pw_program *)calloc(1, sizeof(struct pw_program));
}

void pw_program_free(struct pw_program *p) {
    if (!p) return;
    for (size_t i = 0; i < p->n_cards; i++) {
        free(p->per_card[i].classifier_rows);
        free(p->per_card[i].flow_rows);
    }
    free(p->per_card);
    free(p->flow_meta);
    free(p);
}

static struct pw_card_program *card_slot(struct pw_program *p, uint16_t card_id) {
    for (size_t i = 0; i < p->n_cards; i++)
        if (p->per_card[i].card_id == card_id) return &p->per_card[i];
    return NULL;
}

static pw_status append_classifier(struct pw_card_program *cp,
                                   const struct pwfpga_classifier_entry *e) {
    struct pwfpga_classifier_entry *na = realloc(
        cp->classifier_rows, sizeof(*cp->classifier_rows) * (cp->n_classifier_rows + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->classifier_rows = na;
    cp->classifier_rows[cp->n_classifier_rows++] = *e;
    return PW_OK;
}

static pw_status append_flow(struct pw_card_program *cp,
                             const struct pwfpga_flow_config *f) {
    struct pwfpga_flow_config *na = realloc(
        cp->flow_rows, sizeof(*cp->flow_rows) * (cp->n_flow_rows + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->flow_rows = na;
    cp->flow_rows[cp->n_flow_rows++] = *f;
    return PW_OK;
}

static void mac_set(uint8_t *dst, const uint8_t *src) { memcpy(dst, src, 6); }

static pw_status compile_one_flow(struct pw_program *out,
                                  const struct pw_config *cfg,
                                  const struct pw_flow *f,
                                  size_t flow_index) {
    struct pwfpga_port_ref tx, rx;
    pw_status r = pw_config_resolve_port(cfg, f->tx_global_port, &tx);
    if (r != PW_OK) return r;
    r = pw_config_resolve_port(cfg, f->rx_global_port, &rx);
    if (r != PW_OK) return r;

    bool same_card = (tx.card_id == rx.card_id);
    struct pw_card_program *tx_cp = card_slot(out, tx.card_id);
    struct pw_card_program *rx_cp = card_slot(out, rx.card_id);
    if (!tx_cp || !rx_cp) return PW_E_UNKNOWN_CARD;

    uint32_t tx_lfid = (uint32_t)tx_cp->n_flow_rows;
    uint32_t rx_lfid = same_card ? tx_lfid : (uint32_t)rx_cp->n_flow_rows;

    /* TX flow row */
    struct pwfpga_flow_config tx_row = {0};
    /* enable = "this row is active" (wire offset 0); the RTL flow window
     * gates the generator on enable && tx_enable (pw_flow_window.sv), and
     * the classifier-style row arbiter only considers enabled rows. A
     * populated row must set enable=1. */
    tx_row.enable = 1;
    tx_row.egress_local_port = tx.local_port_id;
    tx_row.global_flow_id = f->id;
    tx_row.local_flow_id = tx_lfid;
    tx_row.logical_if_id = f->logical_if_id;
    mac_set(tx_row.src_mac, f->l2.src_mac);
    mac_set(tx_row.dst_mac, f->l2.dst_mac);
    tx_row.vlan_enable = f->l2.vlan_set ? 1 : 0;
    tx_row.vlan_id = f->l2.vlan;
    tx_row.pcp = f->l2.pcp;
    if (f->ipv6.present) {
        tx_row.ip_version = 6;
        memcpy(tx_row.ipv6_src, f->ipv6.src, 16);
        memcpy(tx_row.ipv6_dst, f->ipv6.dst, 16);
        tx_row.ttl = f->ipv6.hop_limit;
        tx_row.dscp = f->ipv6.dscp;
    } else {
        tx_row.ip_version = 4;
        tx_row.src_ipv4 = f->ipv4.src;
        tx_row.dst_ipv4 = f->ipv4.dst;
        tx_row.ttl = f->ipv4.ttl;
        tx_row.dscp = f->ipv4.dscp;
    }
    tx_row.udp_src_port = f->udp.src_port;
    tx_row.udp_dst_port = f->udp.dst_port;
    /* Per-field modifiers (DUT-facing flow diversification). */
    tx_row.src_ipv4_mod  = f->mod.src_ipv4.mode; tx_row.src_ipv4_mask = f->mod.src_ipv4.mask;
    tx_row.dst_ipv4_mod  = f->mod.dst_ipv4.mode; tx_row.dst_ipv4_mask = f->mod.dst_ipv4.mask;
    tx_row.udp_src_mod   = f->mod.udp_src.mode;  tx_row.udp_src_mask  = (uint16_t)f->mod.udp_src.mask;
    tx_row.udp_dst_mod   = f->mod.udp_dst.mode;  tx_row.udp_dst_mask  = (uint16_t)f->mod.udp_dst.mask;
    if (f->traffic.frame_len_fixed_set) {
        tx_row.frame_len_min = f->traffic.frame_len_fixed;
        tx_row.frame_len_max = f->traffic.frame_len_fixed;
        tx_row.frame_len_step = 1;
    } else {
        tx_row.frame_len_min = f->traffic.frame_len_min;
        tx_row.frame_len_max = f->traffic.frame_len_max;
        tx_row.frame_len_step = f->traffic.frame_len_step ? f->traffic.frame_len_step : 1;
    }
    tx_row.rate_bps = f->traffic.rate_bps;
    tx_row.rate_pps = f->traffic.rate_pps;
    tx_row.burst_size = f->traffic.burst_size;
    tx_row.burst_gap_ticks = f->traffic.burst_gap_ticks;
    /* Pre-compute the RTL's token bucket Q16.16 bytes/cycle so the
     * FPGA does not need a divider. tokens_per_tick = rate_Bps *
     * 65536 / clock_hz = rate_bps * 65536 / (8 * clock_hz). The
     * intermediate fits in 128 bits worst case; we clamp at the
     * 32-bit Q16.16 maximum (= 65535.99 bytes/cycle, well beyond
     * any line rate we target). */
    {
        unsigned __int128 num = (unsigned __int128)f->traffic.rate_bps * 65536u;
        unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
        unsigned __int128 q   = den ? (num / den) : 0;
        tx_row.tokens_per_tick_fp = (q > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)q;
    }
    /* burst_bytes is the token-bucket CAP in BYTES (integer part of the
     * Q16.16 bucket in pw_flow_gen_axis: cap = burst_bytes << 16). The
     * config's burst_size is a FRAME count, so the cap must be at least
     * one frame's worth of bytes -- otherwise the bucket can never hold
     * enough tokens to cover a frame's cost and the generator starves. */
    {
        uint32_t flen = tx_row.frame_len_max ? tx_row.frame_len_max : 1518u;
        uint32_t bsz  = f->traffic.burst_size ? f->traffic.burst_size : 1u;
        uint64_t cap  = (uint64_t)bsz * flen;
        if (cap < flen) cap = flen;
        tx_row.burst_bytes = (cap > 0xFFFFu) ? 0xFFFFu : (uint16_t)cap;
    }
    tx_row.payload_mode = f->traffic.payload_mode;
    tx_row.payload_seed = f->traffic.payload_seed;
    tx_row.insert_sequence = f->traffic.insert_sequence ? 1 : 0;
    tx_row.insert_timestamp = f->traffic.insert_timestamp ? 1 : 0;
    tx_row.tx_enable = 1;
    tx_row.rx_check_enable = same_card ? 1 : 0;
    if ((r = append_flow(tx_cp, &tx_row)) != PW_OK) return r;

    /* RX flow row for cross-card */
    if (!same_card) {
        struct pwfpga_flow_config rx_row = tx_row;
        rx_row.local_flow_id = rx_lfid;
        rx_row.egress_local_port = rx.local_port_id;  /* informational */
        rx_row.tx_enable = 0;
        rx_row.rx_check_enable = 1;
        if ((r = append_flow(rx_cp, &rx_row)) != PW_OK) return r;
    }

    /* RX classifier row */
    struct pwfpga_classifier_entry ce = {0};
    ce.action = PWFPGA_ACT_TEST_RX;
    ce.flags = PWFPGA_CLS_FLAG_ENABLE;
    ce.priority = 10;
    ce.local_flow_id = rx_lfid;
    ce.logical_if_id = f->logical_if_id;
    ce.key.ingress_local_port = rx.local_port_id;
    ce.mask.ingress_local_port = 0xff;
    if (f->l2.vlan_set) {
        ce.key.vlan_id = f->l2.vlan;
        ce.mask.vlan_id = 0x0FFF;
    }
    ce.key.udp_dst_port = f->udp.dst_port;
    ce.mask.udp_dst_port = 0xFFFF;
    if (!f->ipv6.present) {
        ce.key.ipv4_dst = f->ipv4.dst;
        ce.mask.ipv4_dst = 0xFFFFFFFFu;
        ce.key.ip_version = 4;
        ce.mask.ip_version = 0xff;
    } else {
        /* IPv6: no v4 dst to match; udp_dst + l3_proto + magic + flow_id
         * identify the test flow (the parser sets l3_proto = next-header). */
        ce.key.ip_version = 6;
        ce.mask.ip_version = 0xff;
    }
    ce.key.l3_proto = 17; /* UDP (IPv6 next-header for our frames) */
    ce.mask.l3_proto = 0xff;
    ce.key.test_magic = PW_TEST_HDR_MAGIC;
    ce.mask.test_magic = 0xFFFFFFFFu;
    ce.key.global_flow_id = f->id;
    ce.mask.global_flow_id = 0xFFFFFFFFu;
    if ((r = append_classifier(rx_cp, &ce)) != PW_OK) return r;

    out->flow_meta[flow_index] = (struct pw_flow_meta){
        .global_flow_id = f->id,
        .tx_card_id = tx.card_id,
        .rx_card_id = rx.card_id,
        .tx_local_flow_id = tx_lfid,
        .rx_local_flow_id = rx_lfid,
        .latency_valid = same_card,
    };
    return PW_OK;
}

static pw_status compile_punt_rules(struct pw_program *out, const struct pw_config *cfg) {
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        const struct pw_logical_if *l = &cfg->logical_if[i];
        struct pwfpga_port_ref ref;
        pw_status r = pw_config_resolve_port(cfg, l->global_port, &ref);
        if (r != PW_OK) return r;
        struct pw_card_program *cp = card_slot(out, ref.card_id);
        if (!cp) return PW_E_UNKNOWN_CARD;

        /* Helper to emit one punt rule. */
        #define EMIT(eth, l3p, prio_) do { \
            struct pwfpga_classifier_entry e = {0}; \
            e.action = PWFPGA_ACT_PUNT_TO_HOST; \
            e.flags  = PWFPGA_CLS_FLAG_ENABLE; \
            e.priority = (prio_); \
            e.logical_if_id = l->id; \
            e.key.ingress_local_port = ref.local_port_id; \
            e.mask.ingress_local_port = 0xff; \
            if (l->vlan) { e.key.vlan_id = l->vlan; e.mask.vlan_id = 0x0FFF; } \
            if ((eth)) { e.key.ethertype = (eth); e.mask.ethertype = 0xFFFF; } \
            if ((l3p)) { e.key.l3_proto = (l3p); e.mask.l3_proto = 0xff; } \
            pw_status er = append_classifier(cp, &e); \
            if (er != PW_OK) return er; \
        } while (0)

        if (l->punt.arp)     EMIT(0x0806, 0,  20);
        if (l->punt.ipv6_nd) EMIT(0x86DD, 58, 20);    /* ICMPv6 */
        if (l->punt.lldp)    EMIT(0x88CC, 0,  20);
        if (l->punt.icmp)    EMIT(0x0800, 1,  25);    /* ICMPv4 */
        if (l->punt.bgp)     EMIT(0x0800, 6,  30);    /* TCP, classifier narrows on port 179 in HW */
        if (l->punt.ospf)    EMIT(0x0800, 89, 30);
        if (l->punt.is_is)   EMIT(0x0000, 0,  30);    /* IS-IS sub-network entity, capability-gated */
        #undef EMIT
    }
    return PW_OK;
}

static pw_status compile_forward_rules(struct pw_program *out, const struct pw_config *cfg) {
    for (size_t i = 0; i < cfg->n_forwards; i++) {
        const struct pw_forward_rule *fr = &cfg->forwards[i];
        struct pwfpga_port_ref ing, egr;
        pw_status r = pw_config_resolve_port(cfg, fr->ingress_port, &ing);
        if (r != PW_OK) return r;
        if ((r = pw_config_resolve_port(cfg, fr->egress_port, &egr)) != PW_OK) return r;
        if (ing.card_id != egr.card_id) return PW_E_INVAL;
        struct pw_card_program *cp = card_slot(out, ing.card_id);
        if (!cp) return PW_E_UNKNOWN_CARD;

        struct pwfpga_classifier_entry e = {0};
        e.action            = PWFPGA_ACT_FORWARD_PORT;
        e.flags             = PWFPGA_CLS_FLAG_ENABLE;
        e.priority          = fr->priority;
        e.egress_local_port = egr.local_port_id;
        e.key.ingress_local_port  = ing.local_port_id;
        e.mask.ingress_local_port = 0xff;
        if (fr->vlan)      { e.key.vlan_id    = fr->vlan;      e.mask.vlan_id    = 0x0FFF;   }
        if (fr->ethertype) { e.key.ethertype  = fr->ethertype; e.mask.ethertype  = 0xFFFF;  }
        if (fr->ip_proto)  { e.key.l3_proto   = fr->ip_proto;  e.mask.l3_proto   = 0xff;    }
        if (fr->udp_dst)   { e.key.udp_dst_port = fr->udp_dst; e.mask.udp_dst_port = 0xFFFF; }

        pw_status er = append_classifier(cp, &e);
        if (er != PW_OK) return er;
    }
    return PW_OK;
}

pw_status pw_flow_compile(const struct pw_config *cfg, struct pw_program *out,
                          struct pw_diag *diag) {
    if (!cfg || !out) return PW_E_INVAL;
    /* Re-run validation defensively. */
    pw_status r = pw_config_validate(cfg, diag);
    if (r != PW_OK) return r;

    out->per_card = calloc(cfg->n_cards, sizeof(*out->per_card));
    if (!out->per_card && cfg->n_cards) return PW_E_NO_RESOURCES;
    out->n_cards = cfg->n_cards;
    for (size_t i = 0; i < cfg->n_cards; i++)
        out->per_card[i].card_id = cfg->cards[i].id;

    out->flow_meta = calloc(cfg->n_flows, sizeof(*out->flow_meta));
    if (!out->flow_meta && cfg->n_flows) return PW_E_NO_RESOURCES;
    out->n_flow_meta = cfg->n_flows;

    for (size_t i = 0; i < cfg->n_flows; i++) {
        r = compile_one_flow(out, cfg, &cfg->flows[i], i);
        if (r != PW_OK) return r;
    }

    r = compile_punt_rules(out, cfg);
    if (r != PW_OK) return r;
    return compile_forward_rules(out, cfg);
}
