/* Shared generated-frame builder -- see packetwyrm/frame_preview.h. */
#include "packetwyrm/frame_preview.h"
#include "packetwyrm/types.h"
#include <string.h>

static uint16_t ones_csum(const uint8_t *p, size_t n, uint32_t sum) {
    for (size_t i = 0; i + 1 < n; i += 2) sum += (uint32_t)(p[i] << 8) | p[i+1];
    if (n & 1) sum += (uint32_t)p[n-1] << 8;
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint16_t)~sum;
}
static void wbe16(uint8_t *b, uint16_t v) { b[0] = v >> 8; b[1] = v & 0xFF; }

/* Per-packet field modifiers -- mirror pw_flow_gen_multi.sv exactly so the
 * preview shows the SAME per-seq variation the hardware emits. mode: 0=static
 * (base), 1=increment (seq in the masked bits), 2=random (xorshift-scrambled
 * seq in the masked bits); unmasked bits keep the base. */
static uint32_t pv_scramble(uint32_t x) {
    x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x;
}
static uint32_t pv_mod32(uint8_t mode, uint32_t base, uint32_t mask, uint32_t seq) {
    if (mode == 0) return base;
    uint32_t rot = (mode == 2) ? pv_scramble(seq) : seq;
    return (base & ~mask) | (rot & mask);
}
static uint16_t pv_mod16(uint8_t mode, uint16_t base, uint16_t mask, uint32_t seq) {
    if (mode == 0) return base;
    uint16_t rot = (mode == 2) ? (uint16_t)(pv_scramble(seq) >> 3) : (uint16_t)seq;
    return (uint16_t)((base & ~mask) | (rot & mask));
}
static uint64_t pv_mod48(uint8_t mode, uint64_t base, uint64_t mask, uint64_t seq) {
    if (mode == 0) return base;
    uint64_t rnd = ((uint64_t)pv_scramble((uint32_t)(seq >> 32)) << 32) | pv_scramble((uint32_t)seq);
    uint64_t rot = (mode == 2) ? (rnd & 0xFFFFFFFFFFFFULL) : (seq & 0xFFFFFFFFFFFFULL);
    return (base & ~mask) | (rot & mask);
}
/* 128-bit v6 modifier: 4 independent 32-bit lanes, lane 0 = low 32 bits (last 4
 * address bytes). in/out and mask are MSB-first byte arrays [0]=bits[127:120]. */
static void pv_mod128(uint8_t mode, const uint8_t base[16], const uint8_t mask[16],
                      uint32_t seq, uint32_t field_salt, uint8_t out[16]) {
    static const uint32_t lsalt[4] = {0, 0x9E3779B1u, 0x85EBCA77u, 0xC2B2AE3Du};
    static const uint32_t loff[4]  = {0, 0x10000000u, 0x20000000u, 0x30000000u};
    for (int l = 0; l < 4; l++) {
        int p = (3 - l) * 4;   /* byte offset of this lane (MSB-first) */
        uint32_t b = (uint32_t)base[p]<<24 | (uint32_t)base[p+1]<<16 | (uint32_t)base[p+2]<<8 | base[p+3];
        uint32_t m = (uint32_t)mask[p]<<24 | (uint32_t)mask[p+1]<<16 | (uint32_t)mask[p+2]<<8 | mask[p+3];
        uint32_t e;
        if (mode == 0) e = b;
        else {
            uint32_t rot = (mode == 2) ? pv_scramble(seq ^ field_salt ^ lsalt[l]) : (seq + loff[l]);
            e = (b & ~m) | (rot & m);
        }
        out[p]=e>>24; out[p+1]=e>>16; out[p+2]=e>>8; out[p+3]=e;
    }
}
static uint64_t mac_to_u48(const uint8_t m[6]) {
    return (uint64_t)m[0]<<40 | (uint64_t)m[1]<<32 | (uint64_t)m[2]<<24 |
           (uint64_t)m[3]<<16 | (uint64_t)m[4]<<8  | m[5];
}
static void u48_to_mac(uint64_t v, uint8_t m[6]) {
    m[0]=v>>40; m[1]=v>>32; m[2]=v>>24; m[3]=v>>16; m[4]=v>>8; m[5]=v;
}

/* Returns total L2 length (pre-FCS), or -1 on unsupported/overflow.
 * *built receives the number of header+test-header bytes (rest is zero pad). */
int pw_flow_build_preview(const struct pw_flow *f, uint32_t seq,
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

    /* Apply the per-packet field modifiers for this seq (same as the RTL). The
     * effective values feed the header bytes AND the checksums; the outer
     * (encap) IP + the EtherIP inner MAC are NOT modified (RTL parity). */
    const struct pw_flow_modifiers *md = &f->mod;
    uint8_t  eff_dmac[6], eff_smac[6];
    u48_to_mac(pv_mod48(md->dst_mac.mode, mac_to_u48(f->l2.dst_mac), md->dst_mac.mask, seq), eff_dmac);
    u48_to_mac(pv_mod48(md->src_mac.mode, mac_to_u48(f->l2.src_mac), md->src_mac.mask, seq), eff_smac);
    uint16_t eff_vlan = pv_mod16(md->vlan.mode, (uint16_t)(f->l2.vlan & 0x0FFF),
                                 (uint16_t)(md->vlan.mask & 0x0FFF), seq) & 0x0FFF;
    uint16_t eff_sp = pv_mod16(md->udp_src.mode, f->udp.src_port, (uint16_t)md->udp_src.mask, seq);
    uint16_t eff_dp = pv_mod16(md->udp_dst.mode, f->udp.dst_port, (uint16_t)md->udp_dst.mask, seq);
    uint32_t eff_sip = pv_mod32(md->src_ipv4.mode, f->ipv4.src, (uint32_t)md->src_ipv4.mask, seq);
    uint32_t eff_dip = pv_mod32(md->dst_ipv4.mode, f->ipv4.dst, (uint32_t)md->dst_ipv4.mask, seq);
    uint8_t  eff_v6src[16], eff_v6dst[16];
    /* v6 mode lives in src_ipv4/dst_ipv4; mask is the 128-bit src/dst_ipv6_mask.
     * field_salt: src=0 (SALT_SIP), dst=0x5A5A5A5A (SALT_DIP). */
    pv_mod128(md->src_ipv4.mode, f->ipv6.src, md->src_ipv6_mask, seq, 0x00000000u, eff_v6src);
    pv_mod128(md->dst_ipv4.mode, f->ipv6.dst, md->dst_ipv6_mask, seq, 0x5A5A5A5Au, eff_v6dst);

    size_t o = 0;
    #define PUT(b)  do { if (o >= cap) return -1; buf[o++] = (uint8_t)(b); } while (0)
    #define PUTMAC(m) do { for (int _i=0;_i<6;_i++) PUT((m)[_i]); } while (0)

    /* Ethernet + optional 802.1Q */
    PUTMAC(eff_dmac); PUTMAC(eff_smac);
    if (f->l2.vlan_set) {
        PUT(0x81); PUT(0x00);
        uint16_t tci = ((uint16_t)(f->l2.pcp & 7) << 13) | (eff_vlan & 0x0FFF);
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
    /* TEST frames carry a 32-byte test header as the first payload bytes, so the
     * frame has a minimum length. The generator (flow_compiler pw_flow_min_legal_
     * frame) CLAMPS a too-short length UP to this floor, so mirror that here for
     * RTL parity -- the preview then shows the same frame the HW emits. Clamping
     * (not just checking) also keeps the direct buf[t+0..31] stores below in
     * bounds: after the clamp t+32 = prefix+iphl+l4hl+32 <= frame_len, and the
     * re-check below re-establishes frame_len <= cap. */
    size_t min_pl = (tmpl == PW_FRAME_TEMPLATE_TEST) ? 32 : 0;
    size_t min_frame = prefix + inner_iphl + l4hl + min_pl;
    if (frame_len < min_frame) frame_len = min_frame;   /* RTL clamps up */
    if (frame_len > cap) return -1;                      /* clamp may exceed buf */
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
        for (int i=0;i<16;i++) PUT(eff_v6src[i]);
        for (int i=0;i<16;i++) PUT(eff_v6dst[i]);
    } else {
        uint16_t tot = (uint16_t)(20 + ip_pl);
        PUT(0x45); PUT(f->ipv4.dscp << 2); PUT(tot >> 8); PUT(tot & 0xFF);
        PUT(0); PUT(0); PUT(0x40); PUT(0);
        PUT(f->ipv4.ttl ? f->ipv4.ttl : 64);
        PUT(tmpl == PW_FRAME_TEMPLATE_L3RAW ? 0xFD : (is_tcp ? 6 : 17));
        PUT(0); PUT(0);   /* csum below */
        PUT(eff_sip >> 24); PUT(eff_sip >> 16); PUT(eff_sip >> 8); PUT(eff_sip);
        PUT(eff_dip >> 24); PUT(eff_dip >> 16); PUT(eff_dip >> 8); PUT(eff_dip);
        wbe16(&buf[iph + 10], ones_csum(&buf[iph], 20, 0));
    }

    if (tmpl == PW_FRAME_TEMPLATE_L3RAW) { *built = o; return (int)frame_len; }

    /* ---- L4 (UDP/TCP) ---- */
    size_t l4 = o;
    PUT(eff_sp >> 8); PUT(eff_sp & 0xFF);
    PUT(eff_dp >> 8); PUT(eff_dp & 0xFF);
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
        if (inner_v6) { for (int i=0;i<16;i++){ sum += (uint32_t)eff_v6src[i]<<((i&1)?0:8);}
                        for (int i=0;i<16;i++){ sum += (uint32_t)eff_v6dst[i]<<((i&1)?0:8);} }
        else { sum += (eff_sip>>16)&0xFFFF; sum += eff_sip&0xFFFF;
               sum += (eff_dip>>16)&0xFFFF; sum += eff_dip&0xFFFF; }
        uint16_t c = ones_csum(&buf[l4], frame_len - l4, sum);
        if (is_tcp) wbe16(&buf[l4 + 16], c);
        else        wbe16(&buf[l4 + 6],  c);   /* incl. v4 UDP (valid; HW sends 0) */
    }
    #undef PUT
    #undef PUTMAC
    return (int)frame_len;
}
