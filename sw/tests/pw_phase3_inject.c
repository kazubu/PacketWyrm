/* PacketWyrm Phase 3 hardware slow-path TX inject test (one-shot).
 *
 * Round-trips a host-composed frame through BOTH slow-path directions on
 * silicon: the host injects a frame out egress 0; over the DAC it arrives
 * on RX1, where a classifier PUNT rule sends it back to the host. The host
 * reads it via slow_path_rx and byte-compares against what it sent.
 *
 *   slow_path_tx(frame, egress=0) -> TX0 -> DAC -> RX1
 *      -[classifier: PUNT, lif=LIF]-> punt window -> slow_path_rx
 *
 * The frame is a plain IPv4/UDP frame (no test magic, so egress timestamp
 * insertion leaves it untouched) -> the looped-back bytes must match
 * exactly. Validates slow_path_tx and slow_path_rx end-to-end.
 *
 *   sudo pw_phase3_inject <bdf>
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"
#include "pw_tool_fc.h"

static void set_mac(uint8_t *d, uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}
static void be16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf>\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    const uint32_t LIF = 0x00000055u;
    const uint16_t UDP_DST = 0xBEEF;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->slow_path_tx || !o->slow_path_rx) { fprintf(stderr, "backend lacks slow_path ops\n"); return 1; }

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x version=0x%08x\n", bdf, info.device_id, info.version);

    /* Clear stale flow rows. */
    {
        struct pwfpga_flow_config zf = {0};
        unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
        for (unsigned r = 0; r < nf; r++) if (o->flow_write) o->flow_write(be.ctx, r, &zf);
    }

    /* Field-classifier rule: PUNT UDP/0xBEEF arriving on ingress 1. */
    pw_tool_fc_ing_udp(o, be.ctx, 0, 0, /*ingress*/1, /*udp_dst*/UDP_DST,
                       PWFPGA_ACT_PUNT_TO_HOST, /*egress*/0, /*lfid*/0, LIF);

    /* Compose a plain Eth/IPv4/UDP frame (no FCS -- the MAC appends it). */
    uint8_t f[64]; memset(f, 0, sizeof(f));
    size_t n = 0;
    set_mac(&f[0], 0x02a5020000aaULL);   n += 6;   /* dst mac */
    set_mac(&f[6], 0x02a5020000bbULL);   n += 6;   /* src mac */
    be16(&f[12], 0x0800);                n += 2;   /* ethertype IPv4 */
    uint8_t *ip = &f[14];
    ip[0] = 0x45; ip[1] = 0x00;                    /* ver/ihl, tos */
    be16(&ip[2], 36);                              /* total len = 20 IP + 8 UDP + 8 payload */
    ip[8] = 64; ip[9] = 17;                        /* ttl, proto=UDP */
    ip[12]=198; ip[13]=51; ip[14]=100; ip[15]=1;   /* src 198.51.100.1 */
    ip[16]=198; ip[17]=51; ip[18]=100; ip[19]=2;   /* dst 198.51.100.2 */
    uint8_t *udp = &f[34];
    be16(&udp[0], 0xC000); be16(&udp[2], UDP_DST); /* src/dst port */
    be16(&udp[4], 16);                             /* udp len = 8 + 8 payload */
    memcpy(&f[42], "INJECT01", 8);                 /* payload */
    n = 50;                                        /* total frame bytes */

    printf("inject %zu-byte UDP/0x%04x frame out egress 0 (PUNT back on ingress 1, lif=0x%x)\n",
           n, UDP_DST, LIF);

    pw_status tr = o->slow_path_tx(be.ctx, f, n, 0 /*lif unused*/, 0 /*egress 0*/);
    if (tr != PW_OK) { fprintf(stderr, "slow_path_tx failed: %d\n", (int)tr); return 1; }

    /* Drain the looped-back copy. */
    uint8_t rx[2048]; uint32_t got_lif = 0; int rn = 0;
    for (long s = 0; s < 20000000L && rn == 0; s++)
        rn = o->slow_path_rx(be.ctx, rx, sizeof(rx), &got_lif);

    if (rn <= 0) { printf("RESULT: FAIL -- no frame looped back (rn=%d)\n", rn); return 1; }

    /* The TX MAC pads frames up to the 60-byte Ethernet minimum, so a
     * sub-60 inject comes back padded -- accept exact length or padded-to-60,
     * and compare only the bytes we actually sent (the rest are MAC zeros). */
    int len_ok = (rn == (int)n) || (rn == 60 && (int)n <= 60);
    int lif_ok = (got_lif == LIF);
    int data_ok = (rn >= (int)n) && (memcmp(rx, f, n) == 0);
    printf("looped back: %d bytes (sent %zu; >= sent is MAC min-frame padding), "
           "lif=0x%x, len_ok=%d lif_ok=%d data_ok=%d\n",
           rn, n, got_lif, len_ok, lif_ok, data_ok);
    if (!data_ok) {
        printf("  byte diffs (idx sent/recv):");
        for (size_t i = 0; i < n && i < (size_t)rn; i++)
            if (f[i] != rx[i]) printf(" [%zu]%02x/%02x", i, f[i], rx[i]);
        printf("\n");
    }
    printf("RESULT: %s\n", (len_ok && lif_ok && data_ok) ? "PASS" : "FAIL");

    pw_card_backend_close(&be);
    return (len_ok && lif_ok && data_ok) ? 0 : 1;
}
