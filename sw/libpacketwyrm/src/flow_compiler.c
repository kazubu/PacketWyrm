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
        free(p->per_card[i].flow_rows);
        free(p->per_card[i].map_entries);
        free(p->per_card[i].fc_cmps);
        free(p->per_card[i].fc_udfs);
        free(p->per_card[i].fc_rules);
        free(p->per_card[i].hash_entries);
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

static pw_status append_flow(struct pw_card_program *cp,
                             const struct pwfpga_flow_config *f) {
    struct pwfpga_flow_config *na = realloc(
        cp->flow_rows, sizeof(*cp->flow_rows) * (cp->n_flow_rows + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->flow_rows = na;
    cp->flow_rows[cp->n_flow_rows++] = *f;
    return PW_OK;
}

static pw_status append_map(struct pw_card_program *cp,
                            uint32_t flow_id, uint32_t local_flow_id) {
    struct pw_flowid_map_entry *na = realloc(
        cp->map_entries, sizeof(*cp->map_entries) * (cp->n_map_entries + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->map_entries = na;
    cp->map_entries[cp->n_map_entries++] =
        (struct pw_flowid_map_entry){ .flow_id = flow_id, .local_flow_id = local_flow_id };
    return PW_OK;
}

/* Append a field comparator, deduping identical {src,mask,value}. Returns the
 * comparator-bit index (= field comparator index) in *bit_out. */
static pw_status append_fc_cmp(struct pw_card_program *cp, uint8_t src,
                               uint32_t mask, uint32_t value, size_t *bit_out) {
    for (size_t i = 0; i < cp->n_fc_cmps; i++)
        if (cp->fc_cmps[i].src == src && cp->fc_cmps[i].mask == mask &&
            cp->fc_cmps[i].value == value) { *bit_out = i; return PW_OK; }
    if (cp->n_fc_cmps >= PWFPGA_NUM_CMP) return PW_E_NO_RESOURCES;
    struct pw_fc_cmp *na = realloc(cp->fc_cmps, sizeof(*cp->fc_cmps) * (cp->n_fc_cmps + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->fc_cmps = na;
    cp->fc_cmps[cp->n_fc_cmps] = (struct pw_fc_cmp){ .src = src, .mask = mask, .value = value };
    *bit_out = cp->n_fc_cmps++;
    return PW_OK;
}

/* Emit up to 4 field comparators for a 128-bit IPv6 address match (addr[0]=MSB,
 * bitwise mask, 1 = must match). sel[w] is the comparator source selector for
 * address word w (w=0 -> bytes [0:3] = [127:96], w=3 -> bytes [12:15] = [31:0]).
 * A word whose 32-bit mask is zero emits NO comparator (wildcard) -> a /64
 * prefix costs 2 comparators, not 4. The shared 12-comparator pool + dedup +
 * PW_E_NO_RESOURCES are handled by append_fc_cmp. */
static pw_status append_ipv6_cmps(struct pw_card_program *cp, const uint8_t addr[16],
                                  const uint8_t mask[16], const uint8_t sel[4],
                                  uint16_t *care) {
    for (int w = 0; w < 4; w++) {
        const uint8_t *mb = &mask[w * 4], *ab = &addr[w * 4];
        uint32_t m = ((uint32_t)mb[0] << 24) | ((uint32_t)mb[1] << 16) |
                     ((uint32_t)mb[2] << 8) | mb[3];
        if (m == 0) continue;
        uint32_t v = ((uint32_t)ab[0] << 24) | ((uint32_t)ab[1] << 16) |
                     ((uint32_t)ab[2] << 8) | ab[3];
        v &= m;   /* mask the value so two prefixes differing only in don't-care
                   * (host) bits dedup to one comparator (the RTL masks too). */
        size_t bit; pw_status er = append_fc_cmp(cp, sel[w], m, v, &bit);
        if (er != PW_OK) return er;
        *care |= (uint16_t)(1u << bit);
    }
    return PW_OK;
}

/* Append a UDF comparator (deduped). Returns the comparator-bit index
 * (= PWFPGA_NUM_CMP + udf index) in *bit_out. */
static pw_status append_fc_udf(struct pw_card_program *cp, uint16_t offset,
                               uint32_t mask, uint32_t value, size_t *bit_out) {
    for (size_t i = 0; i < cp->n_fc_udfs; i++)
        if (cp->fc_udfs[i].offset == offset && cp->fc_udfs[i].mask == mask &&
            cp->fc_udfs[i].value == value) { *bit_out = PWFPGA_NUM_CMP + i; return PW_OK; }
    if (cp->n_fc_udfs >= PWFPGA_NUM_UDF) return PW_E_NO_RESOURCES;
    struct pw_fc_udf *na = realloc(cp->fc_udfs, sizeof(*cp->fc_udfs) * (cp->n_fc_udfs + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->fc_udfs = na;
    cp->fc_udfs[cp->n_fc_udfs] = (struct pw_fc_udf){ .offset = offset, .mask = mask, .value = value };
    *bit_out = PWFPGA_NUM_CMP + cp->n_fc_udfs++;
    return PW_OK;
}

static pw_status append_fc_rule(struct pw_card_program *cp, const struct pw_fc_rule *rule) {
    if (cp->n_fc_rules >= PWFPGA_NUM_RULE) return PW_E_NO_RESOURCES;
    struct pw_fc_rule *na = realloc(cp->fc_rules, sizeof(*cp->fc_rules) * (cp->n_fc_rules + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->fc_rules = na;
    cp->fc_rules[cp->n_fc_rules++] = *rule;
    return PW_OK;
}

/* Build the 11 field-aligned hash key words from a flow's header tuple:
 * l3_dst (w0..3, IPv4 dst in w0), l3_src (w4..7), {l4_src,l4_dst} (w8),
 * {vlan,ethertype} (w9), {0,proto} (w10). Bit-identical to the RTL assemble(). */
static void pw_fc_l3_words(unsigned __int128 a, uint32_t w[4]) {
    w[0] = (uint32_t)(a & 0xFFFFFFFFu);
    w[1] = (uint32_t)((a >> 32) & 0xFFFFFFFFu);
    w[2] = (uint32_t)((a >> 64) & 0xFFFFFFFFu);
    w[3] = (uint32_t)((a >> 96) & 0xFFFFFFFFu);
}
static void pw_fc_hash_words(const struct pw_flow *f, uint32_t w[11]) {
    uint8_t tmpl = f->traffic.frame_template;
    /* Raw L2 template: the frame is Ethernet [+VLAN] + ethertype + a ZERO
     * payload, so the RX parser reads zeros for any L3/L4 it attempts. Only
     * vlan + ethertype distinguish it (the key has no MAC). Two L2RAW flows on
     * one card must therefore differ in ethertype or VLAN (else the collision
     * post-pass rejects them). */
    if (tmpl == PW_FRAME_TEMPLATE_L2RAW) {
        for (int i = 0; i < 8; i++) w[i] = 0;
        w[8] = 0;
        uint32_t et = f->l2.ethertype ? (uint32_t)f->l2.ethertype
                                      : (f->ipv6.present ? 0x86DDu : 0x0800u);
        uint32_t vlan16 = f->l2.vlan_set ? (f->l2.vlan & 0x0FFFu) : 0u;
        w[9]  = (vlan16 << 16) | (et & 0xFFFFu);
        w[10] = 0;
        return;
    }
    unsigned __int128 dst = 0, src = 0;
    if (f->ipv6.present) {
        for (int i = 0; i < 16; i++) dst = (dst << 8) | f->ipv6.dst[i];  /* dst[0] = MSB */
        for (int i = 0; i < 16; i++) src = (src << 8) | f->ipv6.src[i];
    } else { dst = f->ipv4.dst; src = f->ipv4.src; }
    pw_fc_l3_words(dst, &w[0]);
    pw_fc_l3_words(src, &w[4]);
    /* L3RAW carries no L4 header; the RX parser reads zero L4 ports from the raw
     * payload, so key on zero to match. L4RAW/TEST emit a real L4 header. */
    w[8]  = (tmpl == PW_FRAME_TEMPLATE_L3RAW)
            ? 0u : (((uint32_t)f->udp.src_port << 16) | f->udp.dst_port);
    uint32_t eth   = f->ipv6.present ? 0x86DDu : 0x0800u;
    uint32_t vlan16 = f->l2.vlan_set ? (f->l2.vlan & 0x0FFFu) : 0u;
    w[9]  = (vlan16 << 16) | eth;
    w[10] = f->udp.l4_proto ? f->udp.l4_proto : 17u;   /* L3 proto: 6 TCP / 17 UDP */
}
/* XOR-fold the 11 (masked) words + multiply-shift -> bucket. Identical to RTL. */
static uint16_t pw_fc_hash_index(const uint32_t w[11], uint32_t seed) {
    uint32_t k32 = 0;
    for (int i = 0; i < 11; i++) k32 ^= w[i];
    uint32_t prod = k32 * (seed | 1u);
    int idx_w = 0; for (unsigned d = PWFPGA_HASH_DEPTH; d > 1; d >>= 1) idx_w++;
    return (uint16_t)(prod >> (32 - idx_w));
}

static pw_status append_hash_entry(struct pw_card_program *cp,
                                   const uint32_t w[11], uint32_t lfid) {
    if (cp->n_hash_entries >= PWFPGA_HASH_DEPTH) return PW_E_NO_RESOURCES;
    struct pw_fc_hash_entry *na = realloc(
        cp->hash_entries, sizeof(*cp->hash_entries) * (cp->n_hash_entries + 1));
    if (!na) return PW_E_NO_RESOURCES;
    cp->hash_entries = na;
    struct pw_fc_hash_entry *e = &cp->hash_entries[cp->n_hash_entries++];
    e->index = 0; e->local_flow_id = lfid;
    for (int i = 0; i < 11; i++) e->key_word[i] = w[i];   /* unmasked; masked in post-pass */
    return PW_OK;
}

/* Header-classified RX flow: classify by an EXACT (masked) header key via the
 * hash exact table -- payload-agnostic, scaling to NUM_FLOWS. The bucket index
 * + the global key mask are assigned in a per-card post-pass (so randomized /
 * unmatched bits are masked out and the keys land collision-free). */
static pw_status compile_header_classify(struct pw_card_program *rx_cp,
                                         const struct pw_flow *f, uint32_t rx_lfid) {
    uint32_t w[11];
    pw_fc_hash_words(f, w);
    return append_hash_entry(rx_cp, w, rx_lfid);
}

/* Clear the bits a flow's modifiers randomize (and narrow by its match masks)
 * from the global hash key mask, so those bits don't break classification. */
static void pw_fc_relax_mask(uint32_t mask[11], const struct pw_flow *f) {
    /* l3_dst (w0, IPv4 dst low 32 / IPv6 low 32) */
    if (f->mod.dst_ipv4.mode != PWFPGA_FIELD_STATIC) mask[0] &= ~(uint32_t)f->mod.dst_ipv4.mask;
    if (f->match_ipv4_dst_mask != 0xFFFFFFFFu)       mask[0] &=  f->match_ipv4_dst_mask;
    /* l3_src (w4) */
    if (f->mod.src_ipv4.mode != PWFPGA_FIELD_STATIC) mask[4] &= ~(uint32_t)f->mod.src_ipv4.mask;
    /* IPv6 full-128 modifier high words: dst w1..3 / src w5..7 also rotate (w0/w4
     * cleared above via the low mask). Hash word w -> MSB-first mask bytes
     * [(3-w)*4 .. +3]. */
    if (f->ipv6.present) {
        if (f->mod.dst_ipv4.mode != PWFPGA_FIELD_STATIC)
            for (int w = 1; w < 4; w++) {
                const uint8_t *b = &f->mod.dst_ipv6_mask[(3 - w) * 4];
                mask[w] &= ~(((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]);
            }
        if (f->mod.src_ipv4.mode != PWFPGA_FIELD_STATIC)
            for (int w = 1; w < 4; w++) {
                const uint8_t *b = &f->mod.src_ipv6_mask[(3 - w) * 4];
                mask[4 + w] &= ~(((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]);
            }
    }
    /* IPv6 match narrowing: dst -> w0..3, src -> w4..7 (hash word layout:
     * w[0]=addr low 32 = bytes[12:15], w[3]=high = bytes[0:3]). */
    if (f->match_ipv6_dst_set) {
        for (int i = 0; i < 4; i++) {
            const uint8_t *b = &f->match_ipv6_dst_mask[(3 - i) * 4];
            mask[i] &= ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        }
    }
    if (f->match_ipv6_src_set) {
        for (int i = 0; i < 4; i++) {
            const uint8_t *b = &f->match_ipv6_src_mask[(3 - i) * 4];
            mask[4 + i] &= ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        }
    }
    /* l4_dst (w8 low 16) / l4_src (w8 high 16) */
    if (f->mod.udp_dst.mode != PWFPGA_FIELD_STATIC)  mask[8] &= ~((uint32_t)f->mod.udp_dst.mask & 0xFFFFu);
    if (f->match_udp_dst_mask != 0xFFFFu)            mask[8] &= (0xFFFF0000u | f->match_udp_dst_mask);
    if (f->mod.udp_src.mode != PWFPGA_FIELD_STATIC)  mask[8] &= ~(((uint32_t)f->mod.udp_src.mask & 0xFFFFu) << 16);
    /* vlan (w9 high 16) */
    if (f->mod.vlan.mode != PWFPGA_FIELD_STATIC)     mask[9] &= ~(((uint32_t)f->mod.vlan.mask & 0x0FFFu) << 16);
}

/* Minimum legal on-wire frame (bytes), mirroring RTL pw_frame_bytes(row, 32B
 * test payload). The generator clamps the swept length UP to this, and the
 * token-bucket cost uses it -- so the bucket cap and the rate_pps byte basis
 * must both meter at least this many bytes, else the bucket never reaches the
 * cost (cap < cost -> the flow never transmits) and pps is metered against the
 * wrong size. Accounts for VLAN, encap (outer IP + tunnel), inner IP family,
 * and the L4 protocol (TCP 20 / UDP 8). */
static uint32_t pw_flow_min_legal_frame(const struct pw_flow *f) {
    uint32_t l = 14u;                                       /* Ethernet (incl ethertype) */
    if (f->l2.vlan_set) l += 4u;                            /* VLAN tag */
    /* Raw L2 template: Ethernet [+VLAN] only (payload floor 0). */
    if (f->traffic.frame_template == PW_FRAME_TEMPLATE_L2RAW)
        return l;
    /* Raw L3 template: Ethernet [+VLAN] + inner IP (no L4, no test header). */
    if (f->traffic.frame_template == PW_FRAME_TEMPLATE_L3RAW)
        return l + (f->ipv6.present ? 40u : 20u);
    /* TEST / L4RAW: full inner IP + L4 (+ optional encap). */
    if (f->encap.present) {
        l += f->encap.outer_ipv6.present ? 40u : 20u;       /* outer IP */
        if (f->encap.type == PWFPGA_ENCAP_GRE)          l += 4u;
        else if (f->encap.type == PWFPGA_ENCAP_ETHERIP) l += 16u;
    }
    l += f->ipv6.present ? 40u : 20u;                       /* inner IP */
    l += (f->udp.l4_proto == 6) ? 20u : 8u;                 /* L4 (TCP / UDP) */
    /* Only TEST reserves the 32-byte test-header payload region; L4RAW does not. */
    if (f->traffic.frame_template == PW_FRAME_TEMPLATE_TEST)
        l += 32u;
    return l;
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

    /* Fail early if either card is already at the FPGA flow-table capacity,
     * rather than letting append_flow() build a program with an out-of-range
     * local_flow_id that pw_program_card_tables() would only reject at write
     * time. A background flow consumes a TX row only. (The caller attributes
     * the PW_E_NO_RESOURCES to this flow in its diagnostic.) */
    if (tx_cp->n_flow_rows >= PWFPGA_FLOW_TABLE_ROWS) return PW_E_NO_RESOURCES;
    if (!same_card && !f->background && rx_cp->n_flow_rows >= PWFPGA_FLOW_TABLE_ROWS)
        return PW_E_NO_RESOURCES;

    uint32_t tx_lfid = (uint32_t)tx_cp->n_flow_rows;
    /* Background flows allocate no RX row, so they must NOT derive rx_lfid from
     * rx_cp->n_flow_rows -- that slot is never appended and a later real flow
     * would reuse it, making this flow's meta alias the real flow's RX slot.
     * Point it at tx_lfid (informational; rx_slot_valid=false tells the daemon
     * to ignore it entirely). */
    uint32_t rx_lfid = (same_card || f->background) ? tx_lfid
                                                    : (uint32_t)rx_cp->n_flow_rows;

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
    /* Encapsulation: outer L3 + tunnel header wrapping the inner frame. */
    if (f->encap.present) {
        tx_row.encap_type = f->encap.type;
        tx_row.rx_expect  = f->rx_expect;
        if (f->encap.outer_ipv6.present) {
            tx_row.outer_ip_version = 6;
            memcpy(tx_row.outer_ipv6_src, f->encap.outer_ipv6.src, 16);
            memcpy(tx_row.outer_ipv6_dst, f->encap.outer_ipv6.dst, 16);
            tx_row.outer_ttl  = f->encap.outer_ipv6.hop_limit;
            tx_row.outer_dscp = f->encap.outer_ipv6.dscp;
        } else {
            tx_row.outer_ip_version = 4;
            tx_row.outer_src_ipv4 = f->encap.outer_ipv4.src;
            tx_row.outer_dst_ipv4 = f->encap.outer_ipv4.dst;
            tx_row.outer_ttl  = f->encap.outer_ipv4.ttl;
            tx_row.outer_dscp = f->encap.outer_ipv4.dscp;
        }
        /* EtherIP inner Ethernet MAC: explicit inner_l2, or reuse the flow MAC. */
        mac_set(tx_row.inner_src_mac, f->encap.inner_mac_set ? f->encap.inner_src_mac : f->l2.src_mac);
        mac_set(tx_row.inner_dst_mac, f->encap.inner_mac_set ? f->encap.inner_dst_mac : f->l2.dst_mac);
    }
    tx_row.udp_src_port = f->udp.src_port;
    tx_row.udp_dst_port = f->udp.dst_port;
    tx_row.l4_proto     = f->udp.l4_proto ? f->udp.l4_proto : 17;  /* 6 TCP / 17 UDP */
    tx_row.tcp_flags    = f->udp.tcp_flags;
    /* Frame template + L2RAW ethertype (default 0 => IP-family default). */
    tx_row.frame_template = f->traffic.frame_template;
    tx_row.l2_ethertype   = f->l2.ethertype;
    /* Per-field modifiers (DUT-facing flow diversification). */
    tx_row.src_ipv4_mod  = f->mod.src_ipv4.mode; tx_row.src_ipv4_mask = (uint32_t)f->mod.src_ipv4.mask;
    tx_row.dst_ipv4_mod  = f->mod.dst_ipv4.mode; tx_row.dst_ipv4_mask = (uint32_t)f->mod.dst_ipv4.mask;
    /* IPv6 full-128 mask: low 32 bits are in src/dst_ipv4_mask (above); the high
     * 96 bits go to *_ipv6_mask_hi. config mask is MSB-first (mask[0]=[127:120]);
     * the wire hi array is little-endian by byte (index 0 = address [39:32]), so
     * hi[i] = mask[11-i]. Zero for v4 flows. */
    if (f->ipv6.present) {
        for (int i = 0; i < 12; i++) {
            tx_row.src_ipv6_mask_hi[i] = f->mod.src_ipv6_mask[11 - i];
            tx_row.dst_ipv6_mask_hi[i] = f->mod.dst_ipv6_mask[11 - i];
        }
    }
    tx_row.udp_src_mod   = f->mod.udp_src.mode;  tx_row.udp_src_mask  = (uint16_t)f->mod.udp_src.mask;
    tx_row.udp_dst_mod   = f->mod.udp_dst.mode;  tx_row.udp_dst_mask  = (uint16_t)f->mod.udp_dst.mask;
    /* MAC masks are 6 bytes, MSB-first (byte 0 = address bits 47..40). */
    tx_row.src_mac_mod = f->mod.src_mac.mode;
    tx_row.dst_mac_mod = f->mod.dst_mac.mode;
    for (int i = 0; i < 6; i++) {
        tx_row.src_mac_mask[i] = (uint8_t)(f->mod.src_mac.mask >> (8 * (5 - i)));
        tx_row.dst_mac_mask[i] = (uint8_t)(f->mod.dst_mac.mask >> (8 * (5 - i)));
    }
    tx_row.vlan_mod  = f->mod.vlan.mode;
    tx_row.vlan_mask = (uint16_t)(f->mod.vlan.mask & 0x0FFF);
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
        /* The token bucket meters frame bytes. rate_bps is that byte rate (x8);
         * rate_pps is realized as pps x (metered frame bytes) x 8, where the
         * metered frame is the min/fixed size (matches the bucket cost, which
         * also uses the minimum frame). Exactly one of the two is set (validated
         * at parse time). */
        uint64_t eff_rate_bps = f->traffic.rate_bps;
        if (eff_rate_bps == 0 && f->traffic.rate_pps) {
            uint32_t flen = f->traffic.frame_len_fixed_set ? f->traffic.frame_len_fixed
                                                           : f->traffic.frame_len_min;
            uint32_t minf = pw_flow_min_legal_frame(f);     /* RTL clamps up to this */
            if (flen < minf) flen = minf;
            eff_rate_bps = f->traffic.rate_pps * (uint64_t)flen * 8u;
        }
        unsigned __int128 num = (unsigned __int128)eff_rate_bps * 65536u;
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
        uint32_t minf = pw_flow_min_legal_frame(f);    /* cap must cover the clamped cost */
        if (flen < minf) flen = minf;
        uint32_t bsz  = f->traffic.burst_size ? f->traffic.burst_size : 1u;
        uint64_t cap  = (uint64_t)bsz * flen;
        /* Cap must cover at least one frame's cost or the bucket never reaches
         * it and the flow never transmits. (A single small-frame flow at cap=1
         * still reaches line rate: the generator keeps the active slot's pick
         * pipeline primed through its own emit, so there is no per-frame drain
         * bubble -- see pw_flow_gen_multi. So no 2-frame floor is needed.) */
        if (cap < flen) cap = flen;
        tx_row.burst_bytes = (cap > 0xFFFFu) ? 0xFFFFu : (uint16_t)cap;
    }
    tx_row.payload_mode = f->traffic.payload_mode;
    tx_row.payload_seed = f->traffic.payload_seed;
    tx_row.insert_sequence = f->traffic.insert_sequence ? 1 : 0;
    tx_row.insert_timestamp = f->traffic.insert_timestamp ? 1 : 0;
    tx_row.tx_enable = 1;
    /* Background (load) flows generate TX only -- no RX check, no classifier. */
    tx_row.rx_check_enable = (same_card && !f->background) ? 1 : 0;
    if ((r = append_flow(tx_cp, &tx_row)) != PW_OK) return r;

    /* Populate flow_meta HERE (before the background early-return): the daemon
     * requires cfg->flows[i] and prog->flow_meta[i] to be 1:1 -- the flows /
     * flow.stats RPCs, test.start/stop, and the config.load quiesce all index by
     * flow_index. A background (TX-only) flow left this zero-initialized, so those
     * paths read flow_id 0 / card 0 / slot 0 for it. latency_valid is false for
     * background (no RX check); otherwise same_card. */
    out->flow_meta[flow_index] = (struct pw_flow_meta){
        .global_flow_id = f->id,
        .tx_card_id = tx.card_id,
        .rx_card_id = rx.card_id,
        .tx_local_flow_id = tx_lfid,
        .rx_local_flow_id = rx_lfid,
        .latency_valid = same_card && !f->background,
        .rx_slot_valid = !f->background,   /* background = TX-only, no RX slot */
    };

    if (f->background)
        return PW_OK;   /* no RX flow row, no classifier entry (frees a slot) */

    /* RX flow row for cross-card */
    if (!same_card) {
        struct pwfpga_flow_config rx_row = tx_row;
        rx_row.local_flow_id = rx_lfid;
        rx_row.egress_local_port = rx.local_port_id;  /* informational */
        rx_row.tx_enable = 0;
        rx_row.rx_check_enable = 1;
        if ((r = append_flow(rx_cp, &rx_row)) != PW_OK) return r;
    }

    /* Effective classifier match masks: start from the configured match mask
     * (default full), then drop the bits any active modifier rotates so the
     * RX rule still matches the fixed part of a modified field. Requires the
     * bitwise-masked classifier (pw_classifier); 0xFFFF/0 behave as before. */
    uint16_t udp_dst_mask = f->match_udp_dst_mask;
    if (f->mod.udp_dst.mode != PWFPGA_FIELD_STATIC)
        udp_dst_mask &= (uint16_t)~f->mod.udp_dst.mask;
    uint32_t ipv4_dst_mask = f->match_ipv4_dst_mask;
    if (f->mod.dst_ipv4.mode != PWFPGA_FIELD_STATIC)
        ipv4_dst_mask &= ~(uint32_t)f->mod.dst_ipv4.mask;

    /* RX TEST_RX: program the flow-id map (the generated test header carries a
     * unique flow_id, so test_flow_id -> checker slot is a direct index) rather
     * than a per-flow classifier rule. This is what lets test flows scale past
     * the classifier's ~16-entry routability limit -- the parser's magic match
     * (is_test) gates it, and the unique flow_id identifies the flow, so the
     * udp_dst / ipv4 / ipv6 match fields were redundant. The mask vars (for the
     * old bitwise classifier compare) are no longer needed here. */
    (void)udp_dst_mask; (void)ipv4_dst_mask;
    if (f->classify_header) {
        /* Header-defined classification (generic slice classifier): match on
         * the flow's header fields, so the payload carries no classification
         * dependency. Caps at the slice-classifier capacity. */
        if ((r = compile_header_classify(rx_cp, f, rx_lfid)) != PW_OK) return r;
    } else {
        /* Default: TEST_RX flow-id map keyed on the test header flow_id. */
        if (f->id >= PWFPGA_FLOWID_MAP_DEPTH) return PW_E_INVAL;  // flow_id out of map range
        if ((r = append_map(rx_cp, f->id, rx_lfid)) != PW_OK) return r;
    }

    /* flow_meta was populated above (before the background early-return). */
    return PW_OK;
}

/* Emit one PUNT rule: ingress (+ optional vlan / ethertype / l3_proto / one L4
 * port / one UDF) field comparators ANDed into a PUNT rule carrying
 * logical_if_id. Pass 0 to skip eth / l3p / l4port / udf_val. l4lane selects
 * PWFPGA_FC_SRC_L4_DST or _L4_SRC. udf_off is relative to the parser's inner-
 * frame (L3) base; udf_val is a 2-byte field in the high half (value<<16, mask
 * 0xFFFF0000), matching the slice extractor's big-endian MSB-first lane. */
static pw_status add_punt_rule(struct pw_card_program *cp,
                               const struct pwfpga_port_ref *ref,
                               const struct pw_logical_if *l,
                               uint16_t eth, uint8_t l3p,
                               uint8_t l4lane, uint16_t l4port,
                               uint16_t udf_off, uint32_t udf_val, uint8_t prio) {
    uint16_t care = 0; size_t bit; pw_status er;
    er = append_fc_cmp(cp, PWFPGA_FC_SRC_INGRESS, 0xFu, ref->local_port_id, &bit);
    if (er != PW_OK) return er;
    care |= (uint16_t)(1u << bit);
    if (l->vlan) {
        er = append_fc_cmp(cp, PWFPGA_FC_SRC_VLAN, 0x0FFFu, l->vlan, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
    }
    if (eth) {
        er = append_fc_cmp(cp, PWFPGA_FC_SRC_ETHERTYPE, 0xFFFFu, eth, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
    }
    if (l3p) {
        er = append_fc_cmp(cp, PWFPGA_FC_SRC_L3_PROTO, 0xFFu, l3p, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
    }
    if (l4port) {
        er = append_fc_cmp(cp, l4lane, 0xFFFFu, l4port, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
    }
    if (udf_val) {
        er = append_fc_udf(cp, udf_off, 0xFFFF0000u, udf_val, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
    }
    struct pw_fc_rule rule = { .care = care, .action = PWFPGA_ACT_PUNT_TO_HOST,
        .egress = 0, .local_flow_id = 0, .logical_if_id = l->id, .priority = prio };
    return append_fc_rule(cp, &rule);
}

static pw_status compile_punt_rules(struct pw_program *out, const struct pw_config *cfg) {
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        const struct pw_logical_if *l = &cfg->logical_if[i];
        struct pwfpga_port_ref ref;
        pw_status r = pw_config_resolve_port(cfg, l->global_port, &ref);
        if (r != PW_OK) return r;
        struct pw_card_program *cp = card_slot(out, ref.card_id);
        if (!cp) return PW_E_UNKNOWN_CARD;

        /* PUNT(...) = add_punt_rule(cp, &ref, l, ...) with error propagation. */
        #define PUNT(...) do { if ((r = add_punt_rule(cp, &ref, l, __VA_ARGS__)) != PW_OK) return r; } while (0)

        if (l->punt.arp)     PUNT(0x0806, 0,  0, 0, 0, 0, 20);
        if (l->punt.ipv6_nd) PUNT(0x86DD, 58, 0, 0, 0, 0, 20);   /* ICMPv6 (ND/RS/RA) */
        if (l->punt.lldp)    PUNT(0x88CC, 0,  0, 0, 0, 0, 20);
        if (l->punt.icmp)    PUNT(0x0800, 1,  0, 0, 0, 0, 25);   /* ICMPv4 */
        /* BGP: TCP/179 only -- one rule per direction (listener dst:179,
         * initiator src:179) so generated TCP test traffic (e.g. a SYN flood on
         * other ports) is NOT swallowed by the slow path. */
        if (l->punt.bgp) {
            PUNT(0x0800, 6, PWFPGA_FC_SRC_L4_DST, 179, 0, 0, 30);
            PUNT(0x0800, 6, PWFPGA_FC_SRC_L4_SRC, 179, 0, 0, 30);
        }
        if (l->punt.ospf)    PUNT(0x0800, 89, 0, 0, 0, 0, 30);   /* OSPFv2 */
        /* IPv6 control plane. NB (API semantics): `ipv6_nd` acts as the per-lif
         * "IPv6 control-plane enable" -- with it set, the ospf/bgp flags emit their
         * IPv6 variants too (OSPFv3 = next-hdr 89; BGP-over-IPv6 = TCP/179), not
         * just ICMPv6 ND. This is deliberate (IPv6 always needs ND), but it means
         * `ipv6_nd` is broader than its name; a future schema could split it into
         * ipv6_nd / ospf3 / bgp_ipv6 for finer control. The 0x86DD ethertype
         * comparator is shared with the ND rule and the proto/L4 comparators with
         * the IPv4 rules, so these cost ~0 extra field comparators (deduped). */
        if (l->punt.ospf && l->punt.ipv6_nd) PUNT(0x86DD, 89, 0, 0, 0, 0, 30);
        if (l->punt.bgp  && l->punt.ipv6_nd) {
            PUNT(0x86DD, 6, PWFPGA_FC_SRC_L4_DST, 179, 0, 0, 30);
            PUNT(0x86DD, 6, PWFPGA_FC_SRC_L4_SRC, 179, 0, 0, 30);
        }
        /* IS-IS rides 802.3/LLC (no ethertype), identified by DSAP=SSAP=0xFE at
         * the LLC header. Match that via a UDF instead of a catch-all (the old
         * ethertype=0/proto=0 rule punted EVERY frame on the ingress). Fails
         * safe: if the parser's L3 base differs for length-encoded frames the
         * UDF simply won't match (no punt) rather than over-matching. */
        if (l->punt.is_is)   PUNT(0, 0, 0, 0, /*udf_off*/0, /*0xFEFE*/0xFEFE0000u, 30);
        #undef PUNT
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

        uint16_t care = 0; size_t bit; pw_status er;
        er = append_fc_cmp(cp, PWFPGA_FC_SRC_INGRESS, 0xFu, ing.local_port_id, &bit);
        if (er != PW_OK) return er;
        care |= (uint16_t)(1u << bit);
        if (fr->vlan) {
            er = append_fc_cmp(cp, PWFPGA_FC_SRC_VLAN, 0x0FFFu, fr->vlan, &bit);
            if (er != PW_OK) return er;
            care |= (uint16_t)(1u << bit);
        }
        if (fr->ethertype) {
            er = append_fc_cmp(cp, PWFPGA_FC_SRC_ETHERTYPE, 0xFFFFu, fr->ethertype, &bit);
            if (er != PW_OK) return er;
            care |= (uint16_t)(1u << bit);
        }
        if (fr->ip_proto) {
            er = append_fc_cmp(cp, PWFPGA_FC_SRC_L3_PROTO, 0xFFu, fr->ip_proto, &bit);
            if (er != PW_OK) return er;
            care |= (uint16_t)(1u << bit);
        }
        if (fr->udp_dst) {
            er = append_fc_cmp(cp, PWFPGA_FC_SRC_L4_DST, 0xFFFFu, fr->udp_dst, &bit);
            if (er != PW_OK) return er;
            care |= (uint16_t)(1u << bit);
        }
        if (fr->ipv6_dst_set || fr->ipv6_src_set) {
            /* An IPv6 address match must also require is_ipv6 -- otherwise an
             * IPv4 packet (whose ipv6_src/dst key words are zero) would match a
             * mask like ::/0. Costs one more of the 12 shared comparators. */
            er = append_fc_cmp(cp, PWFPGA_FC_SRC_FLAGS, PWFPGA_FC_FLAG_IS_IPV6,
                               PWFPGA_FC_FLAG_IS_IPV6, &bit);
            if (er != PW_OK) return er;
            care |= (uint16_t)(1u << bit);
        }
        if (fr->ipv6_dst_set) {
            static const uint8_t dsel[4] = {
                PWFPGA_FC_SRC_IPV6_DST_3, PWFPGA_FC_SRC_IPV6_DST_2,
                PWFPGA_FC_SRC_IPV6_DST_1, PWFPGA_FC_SRC_IPV6_DST_0 };
            er = append_ipv6_cmps(cp, fr->ipv6_dst, fr->ipv6_dst_mask, dsel, &care);
            if (er != PW_OK) return er;
        }
        if (fr->ipv6_src_set) {
            static const uint8_t ssel[4] = {
                PWFPGA_FC_SRC_IPV6_SRC_3, PWFPGA_FC_SRC_IPV6_SRC_2,
                PWFPGA_FC_SRC_IPV6_SRC_1, PWFPGA_FC_SRC_IPV6_SRC_0 };
            er = append_ipv6_cmps(cp, fr->ipv6_src, fr->ipv6_src_mask, ssel, &care);
            if (er != PW_OK) return er;
        }

        struct pw_fc_rule rule = { .care = care, .action = PWFPGA_ACT_FORWARD_PORT,
            .egress = egr.local_port_id, .local_flow_id = 0, .logical_if_id = 0,
            .priority = fr->priority };
        er = append_fc_rule(cp, &rule);
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
        if (r != PW_OK) {
            if (r == PW_E_NO_RESOURCES && diag) {
                diag->code = r;
                snprintf(diag->path, sizeof diag->path, "flows[%zu]", i);
                snprintf(diag->message, sizeof diag->message,
                         "flow %u: per-card resource capacity exceeded "
                         "(flow-table rows max %u/card, or comparator/hash pool)",
                         cfg->flows[i].id, (unsigned)PWFPGA_FLOW_TABLE_ROWS);
            }
            return r;
        }
    }

    r = compile_punt_rules(out, cfg);
    if (r != PW_OK) {
        if (r == PW_E_NO_RESOURCES && diag) {
            diag->code = r;
            snprintf(diag->path, sizeof diag->path, "punt");
            snprintf(diag->message, sizeof diag->message,
                     "field-comparator pool exhausted (limit NCMP=%u, shared across "
                     "punt+forward rules); reduce per-rule match conditions",
                     (unsigned)PWFPGA_NUM_CMP);
        }
        return r;
    }
    r = compile_forward_rules(out, cfg);
    if (r != PW_OK) {
        if (r == PW_E_NO_RESOURCES && diag) {
            diag->code = r;
            snprintf(diag->path, sizeof diag->path, "forwards");
            snprintf(diag->message, sizeof diag->message,
                     "field-comparator pool exhausted (limit NCMP=%u, shared across "
                     "punt+forward rules); a /128 IPv6 match costs 4 + 1 is_ipv6, "
                     "/64 costs 2 + 1; reduce per-rule match conditions",
                     (unsigned)PWFPGA_NUM_CMP);
        }
        return r;
    }

    /* Per-card hash-table seed search: pick a seed so every configured
     * header-key lands in a distinct bucket (the hash only chooses the bucket;
     * the HW still verifies the full key). Search a deterministic seed sequence;
     * a clean placement is found quickly while the load factor stays low
     * (n_hash_entries << PWFPGA_HASH_DEPTH). */
    for (size_t c = 0; c < out->n_cards; c++) {
        struct pw_card_program *cp = &out->per_card[c];
        if (cp->n_hash_entries == 0) continue;

        /* Global key mask: start keying on every field, then relax the bits any
         * header-classified flow on this card randomizes (modifiers) or narrows
         * (match masks), so those bits don't break the exact match. */
        for (int w = 0; w < 11; w++) cp->hash_mask[w] = 0xFFFFFFFFu;
        for (size_t i = 0; i < cfg->n_flows; i++) {
            const struct pw_flow *f = &cfg->flows[i];
            if (!f->classify_header) continue;
            struct pwfpga_port_ref rx;
            if (pw_config_resolve_port(cfg, f->rx_global_port, &rx) != PW_OK) continue;
            if (rx.card_id != cp->card_id) continue;
            pw_fc_relax_mask(cp->hash_mask, f);
        }
        /* Apply the mask to each stored key (HW masks the frame key the same). */
        for (size_t i = 0; i < cp->n_hash_entries; i++)
            for (int w = 0; w < 11; w++)
                cp->hash_entries[i].key_word[w] &= cp->hash_mask[w];

        /* Two flows with IDENTICAL masked keys can never be separated by any
         * seed -- this happens when a field that distinguishes them is
         * randomized by some flow's modifier (the global mask drops it) or
         * cleared by a match mask. Report it clearly rather than as a generic
         * "table full" after the seed search. */
        for (size_t i = 0; i < cp->n_hash_entries; i++)
            for (size_t j = 0; j < i; j++)
                if (memcmp(cp->hash_entries[i].key_word, cp->hash_entries[j].key_word,
                           sizeof cp->hash_entries[i].key_word) == 0) {
                    if (diag) {
                        diag->code = PW_E_INVAL;
                        snprintf(diag->path, sizeof diag->path,
                                 "card[%u].hash", cp->card_id);
                        snprintf(diag->message, sizeof diag->message,
                                 "header-classify flows in slots %u and %u are "
                                 "indistinguishable under the hash key mask (a "
                                 "field that separates them is randomized by a "
                                 "modifier or cleared by match); make them differ "
                                 "in a non-randomized field, or use classify: map",
                                 cp->hash_entries[j].local_flow_id,
                                 cp->hash_entries[i].local_flow_id);
                    }
                    return PW_E_INVAL;
                }

        /* Seed search: place the masked keys collision-free. */
        bool placed = false;
        for (uint32_t attempt = 0; attempt < 4096 && !placed; attempt++) {
            uint32_t seed = 0x9E3779B1u * (attempt + 1u) + 1u;   /* odd, well-mixed */
            bool used[PWFPGA_HASH_DEPTH] = {0};
            bool collision = false;
            for (size_t i = 0; i < cp->n_hash_entries; i++) {
                uint16_t idx = pw_fc_hash_index(cp->hash_entries[i].key_word, seed);
                if (used[idx]) { collision = true; break; }
                used[idx] = true;
                cp->hash_entries[i].index = idx;
            }
            if (!collision) { cp->hash_seed = seed; placed = true; }
        }
        if (!placed) return PW_E_NO_RESOURCES;   /* keys collide even varying the seed */
    }
    return PW_OK;
}
