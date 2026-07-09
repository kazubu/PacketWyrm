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
