/* PacketWyrm Phase 3 hardware IPv6 generation test (one-shot).
 *
 * Generates an IPv6/UDP test flow on egress 0; over the DAC the frames
 * arrive on RX1 where a classifier PUNT rule (udp_dst + magic) sends them
 * to the host. The host checks each frame: ethertype 0x86DD, the IPv6
 * src/dst addresses, and a VALID UDP checksum (IPv6 mandates a non-zero
 * checksum) -- proving IPv6 frame generation + UDP checksum on silicon.
 *
 *   gen[0] IPv6/UDP -> TX0 -> DAC -> RX1 -[PUNT]-> slow_path_rx
 *
 *   sudo pw_phase3_ipv6gen <bdf> [frames]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"
#include "pw_tool_fc.h"

static void set_mac(uint8_t d[6], uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}

/* UDP checksum over an IPv6 frame in buf (len bytes). Valid -> folded
 * 1's-complement sum (including the csum field) == 0xFFFF. */
static int udp6_csum_ok(const uint8_t *f, int len) {
    if (len < 62) return 0;
    uint32_t s = 0;
    uint16_t ulen = ((uint16_t)f[58] << 8) | f[59];         /* UDP length */
    for (int w = 0; w < 8; w++) s += ((uint32_t)f[22 + w*2] << 8) | f[22 + w*2 + 1];  /* src */
    for (int w = 0; w < 8; w++) s += ((uint32_t)f[38 + w*2] << 8) | f[38 + w*2 + 1];  /* dst */
    s += ulen;                                              /* upper-layer length */
    s += 17;                                                /* next-header */
    int n16 = ulen / 2;                                     /* UDP header + payload words */
    for (int w = 0; w < n16; w++) s += ((uint32_t)f[54 + w*2] << 8) | f[54 + w*2 + 1];
    if (ulen & 1) s += (uint32_t)f[54 + ulen - 1] << 8;     /* odd tail */
    s = (s & 0xFFFF) + (s >> 16);
    s = (s & 0xFFFF) + (s >> 16);
    return (s & 0xFFFF) == 0xFFFF;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [frames]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int want = (argc >= 3) ? atoi(argv[2]) : 16;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->slow_path_rx) { fprintf(stderr, "no slow_path_rx\n"); return 1; }

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: build=0x%08x\n", bdf, info.build_id);

    /* IPv6 gen flow on egress 0. src 2001:db8::1, dst 2001:db8::2. */
    struct pwfpga_flow_config f = {0};
    f.enable = 1; f.egress_local_port = 0; f.global_flow_id = 2; f.local_flow_id = 0;
    set_mac(f.dst_mac, 0x02a502000004ULL); set_mac(f.src_mac, 0x02a502000003ULL);
    f.ip_version = 6;
    memset(f.ipv6_src, 0, 16); f.ipv6_src[0]=0x20; f.ipv6_src[1]=0x01; f.ipv6_src[2]=0x0d; f.ipv6_src[3]=0xb8; f.ipv6_src[15]=0x01;
    memset(f.ipv6_dst, 0, 16); f.ipv6_dst[0]=0x20; f.ipv6_dst[1]=0x01; f.ipv6_dst[2]=0x0d; f.ipv6_dst[3]=0xb8; f.ipv6_dst[15]=0x02;
    f.udp_src_port = 49152; f.udp_dst_port = 50001;
    f.dscp = 46;            /* EF -> IPv6 traffic class 0xB8 (byte14 0x6B, byte15 0x80) */
    f.ttl  = 64;            /* hop limit */
    /* IPv6 dst-address modifier: rotate the low byte (byte 53) per frame. */
    f.dst_ipv4_mod = PWFPGA_FIELD_INCREMENT; f.dst_ipv4_mask = 0x000000FFu;
    f.frame_len_min = 256; f.frame_len_max = 256; f.frame_len_step = 1;
    f.rate_bps = 10000000ULL;
    { unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
      unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
      f.tokens_per_tick_fp = (uint32_t)(num / den); }
    f.burst_bytes = 256; f.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence = 1; f.insert_timestamp = 1; f.tx_enable = 1;

    { struct pwfpga_flow_config zf = {0};
      unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
      for (unsigned r=0;r<nf;r++) o->flow_write(be.ctx,r,&zf); }
    /* Data-plane soft reset clears the gen/SAF/arbiters so a previous test's
     * in-flight traffic does not pollute the punt path; then drain any frame
     * already sitting in the punt window. */
    if (o->write32) o->write32(be.ctx, PWFPGA_REG_DP_RESET, 1);
    { uint8_t tmp[2048]; uint32_t l; for (int i = 0; i < 256; i++)
        if (o->slow_path_rx(be.ctx, tmp, sizeof tmp, &l, NULL) <= 0) break; }

    if (pw_tool_fc_ing_udp(o, be.ctx, 0, 0, /*ingress*/1, /*udp_dst*/50001,
                       PWFPGA_ACT_PUNT_TO_HOST, /*egress*/0, /*lfid*/0, /*lif*/0x66) != PW_OK) {
        fprintf(stderr, "FATAL: classifier programming failed (BAR write error?)\n"); return 1;
    }
    if (o->flow_write(be.ctx, 0, &f) != PW_OK || o->flow_commit(be.ctx) != PW_OK) {
        fprintf(stderr, "FATAL: flow_write/commit failed\n"); return 1;
    }

    printf("gen IPv6/UDP egress0 (src 2001:db8::1 dst ::2); PUNT(ingress1) -> host\n");

    int got=0, v6_ok=0, csum_ok=0, addr_ok=0, tc_ok=0, hop_ok=0;
    uint8_t dlo_seen[256] = {0}; int dlo_distinct=0;
    uint8_t buf[2048];
    for (long s=0; s<50000000L && got<want; s++) {
        uint32_t lif=0; int n = o->slow_path_rx(be.ctx, buf, sizeof(buf), &lif, NULL);
        if (n <= 0) continue;
        got++;
        int is6 = (n >= 54 && buf[12]==0x86 && buf[13]==0xDD);
        if (is6) v6_ok++;
        /* fixed bytes: src 2001:db8::1, dst prefix incl byte 52; low byte (53) rotates */
        if (is6 && buf[22]==0x20 && buf[23]==0x01 && buf[37]==0x01 && buf[52]==0x00) addr_ok++;
        if (is6 && buf[14]==0x6B && buf[15]==0x80) tc_ok++;     /* traffic class = DSCP<<2 */
        if (is6 && buf[21]==64) hop_ok++;                       /* hop limit */
        if (is6 && udp6_csum_ok(buf, n)) csum_ok++;
        if (is6 && !dlo_seen[buf[53]]) { dlo_seen[buf[53]]=1; dlo_distinct++; }
        if (got<=3) printf("  frame %d: %d bytes ethertype=%02x%02x tc=%02x%02x hop=%d dst_lo=%02x csum_ok=%d\n",
                           got, n, buf[12], buf[13], buf[14], buf[15], buf[21], buf[53], is6 && udp6_csum_ok(buf,n));
    }

    printf("RESULT: punted=%d ipv6=%d addr_ok=%d csum_ok=%d tc_ok=%d hop_ok=%d dst_lo_distinct=%d (want %d each)\n",
           got, v6_ok, addr_ok, csum_ok, tc_ok, hop_ok, dlo_distinct, want);
    int pass = (got>=want) && (v6_ok==got) && (addr_ok==got) && (csum_ok==got)
               && (tc_ok==got) && (hop_ok==got) && (dlo_distinct>=4);
    printf("%s\n", pass ? "PASS" : "FAIL");

    f.tx_enable=0; f.enable=0; o->flow_write(be.ctx,0,&f); o->flow_commit(be.ctx);
    pw_card_backend_close(&be);
    return pass ? 0 : 1;
}
