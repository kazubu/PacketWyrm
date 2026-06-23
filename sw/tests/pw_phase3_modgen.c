/* PacketWyrm Phase 3 hardware field-modifier test (one-shot).
 *
 * Generates a test flow on egress 0 with a dst-IPv4 field modifier (low 10
 * bits incrementing). Over the DAC the frames arrive on RX1, where a
 * classifier PUNT rule (keyed on the *unmodified* udp_dst + magic) sends
 * them to the host. The host inspects the punted bytes: the dst-IP low bits
 * must rotate, the high bits stay fixed, and the IPv4 header checksum must
 * be valid -- proving the modifier + checksum fix on silicon.
 *
 *   gen[0] (dst_ip mod) -> TX0 -> DAC -> RX1 -[PUNT]-> slow_path_rx
 *
 *   sudo pw_phase3_modgen <bdf> [frames]
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

/* 1's-complement sum of the 20-byte IPv4 header at buf+14; valid -> 0xFFFF. */
static int ip_csum_ok(const uint8_t *f) {
    uint32_t s = 0;
    for (int w = 0; w < 10; w++) s += ((uint32_t)f[14 + w*2] << 8) | f[14 + w*2 + 1];
    s = (s & 0xFFFF) + (s >> 16);
    s = (s & 0xFFFF) + (s >> 16);
    return (s & 0xFFFF) == 0xFFFF;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [frames]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int want = (argc >= 3) ? atoi(argv[2]) : 32;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->slow_path_rx) { fprintf(stderr, "no slow_path_rx\n"); return 1; }

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x build=0x%08x\n", bdf, info.device_id, info.build_id);

    /* Gen flow on egress 0, dst-IP low 10 bits incrementing, modest rate. */
    struct pwfpga_flow_config f = {0};
    f.enable = 1; f.egress_local_port = 0; f.global_flow_id = 2; f.local_flow_id = 0;
    set_mac(f.dst_mac, 0x02a502000004ULL); set_mac(f.src_mac, 0x02a502000003ULL);
    f.ip_version = 4; f.src_ipv4 = 0xC6336401; f.dst_ipv4 = 0xC6336400;  /* .100.0 base */
    f.ttl = 64; f.udp_src_port = 49152; f.udp_dst_port = 50001;
    f.frame_len_min = 256; f.frame_len_max = 256; f.frame_len_step = 1;
    f.rate_bps = 10000000ULL;
    { unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
      unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
      f.tokens_per_tick_fp = (uint32_t)(num / den); }
    f.burst_bytes = 256; f.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence = 1; f.insert_timestamp = 1; f.tx_enable = 1;
    f.dst_ipv4_mod = PWFPGA_FIELD_INCREMENT; f.dst_ipv4_mask = 0x000003FF;   /* low 10 bits */

    { struct pwfpga_flow_config zf = {0};
      unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
      for (unsigned r=0;r<nf;r++) o->flow_write(be.ctx,r,&zf); }

    /* Field-classifier PUNT rule on ingress 1, keyed on udp_dst (NOT modified --
     * the dst-IP modifier rotates a different field). */
    pw_tool_fc_ing_udp(o, be.ctx, 0, 0, /*ingress*/1, /*udp_dst*/50001,
                       PWFPGA_ACT_PUNT_TO_HOST, /*egress*/0, /*lfid*/0, /*lif*/0x42);
    o->flow_write(be.ctx, 0, &f); o->flow_commit(be.ctx);

    printf("gen egress0 dst_ip=198.51.100.0 mod=increment mask=0x3ff; PUNT(ingress1) -> host\n");

    int got=0, csum_ok=0, hi_const=1; uint32_t hi0=0; int hi0_set=0;
    uint32_t seen[64]; int n_seen=0;
    uint8_t buf[2048];
    for (long s=0; s<50000000L && got<want; s++) {
        uint32_t lif=0; int n = o->slow_path_rx(be.ctx, buf, sizeof(buf), &lif, NULL);
        if (n <= 0) continue;
        got++;
        uint32_t dip = ((uint32_t)buf[30]<<24)|((uint32_t)buf[31]<<16)|((uint32_t)buf[32]<<8)|buf[33];
        if (ip_csum_ok(buf)) csum_ok++;
        if (!hi0_set) { hi0 = dip & 0xFFFFFC00u; hi0_set = 1; }
        else if ((dip & 0xFFFFFC00u) != hi0) hi_const = 0;
        /* track distinct dst IPs (cap 64) */
        int dup=0; for (int i=0;i<n_seen;i++) if (seen[i]==dip) dup=1;
        if (!dup && n_seen<64) seen[n_seen++]=dip;
        if (got<=4) printf("  frame %d: dst_ip=%u.%u.%u.%u csum_ok=%d\n",
                           got, buf[30],buf[31],buf[32],buf[33], ip_csum_ok(buf));
    }

    printf("RESULT: punted=%d distinct_dst_ip=%d csum_ok=%d/%d hi_bits_const=%d\n",
           got, n_seen, csum_ok, got, hi_const);
    int pass = (got>=want) && (csum_ok==got) && hi_const && (n_seen>=4);
    printf("%s\n", pass ? "PASS" : "FAIL");

    f.tx_enable=0; f.enable=0; o->flow_write(be.ctx,0,&f); o->flow_commit(be.ctx);
    pw_card_backend_close(&be);
    return pass ? 0 : 1;
}
