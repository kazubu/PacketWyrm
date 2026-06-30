/* PacketWyrm Phase 3: general port-to-port one-way latency.
 *
 * Measures the one-way latency from a TX endpoint (card + egress port) to an RX
 * endpoint (card + ingress port), the SAME way whether or not the path crosses
 * cards -- and it does NOT assume a symmetric path (unlike a PTP two-way swap),
 * so asymmetric routes are fine.
 *
 *   same card  (tx_bdf == rx_bdf): tx_wire_ts and rx_wire_ts are the SAME card
 *     counter, so latency = rx_wire_ts - tx_ts directly. No GPIO, no offset.
 *   cross card (tx_bdf != rx_bdf): the two stamps are in different counters;
 *     the J5 sync (TX card master, RX card slave) supplies offset = TXcnt-RXcnt
 *     and latency = raw + offset. Offset is re-measured every run (so skew
 *     between runs is irrelevant); a short burst bounds within-run skew smear.
 *
 * The TX card stamps tx_wire_ts at its MAC TX (pw_ts_insert); the RX card stamps
 * rx_wire_ts at the arriving port's MAC RX. The RX checker records the diff.
 *
 * Optional baseline (ticks) subtracts a fixture/zero-point so the result is the
 * DUT-attributable latency (corrected - baseline); the fixed cross-card GPIO-
 * sync bias cancels in that subtraction. Without a baseline the cross-card
 * absolute carries a small fixed bias (slave 2FF + J5, tens of ns).
 *
 *   sudo pw_port_latency <tx_bdf> <tx_port> <rx_bdf> <rx_port> [burst_ms=20] [fid=7] [baseline=0]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t *d, uint64_t v) { for (int i=0;i<6;i++) d[i]=(uint8_t)(v>>(8*(5-i))); }
static uint64_t gpio_ts(const struct pw_card_backend_ops *o, void *ctx) {
    uint32_t lo=0, hi=0;
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_LOW,  &lo);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_HIGH, &hi);
    return ((uint64_t)hi<<32)|lo;
}
static uint32_t gpio_ctrl(int en,int m,int rep,int in,int out,int per){
    return (uint32_t)((en&1)|((m&1)<<1)|((rep&1)<<2)|((in&7)<<4)|((out&7)<<8)|((per&0xf)<<16));
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <tx_bdf> <tx_port> <rx_bdf> <rx_port> [burst_ms=20] [fid=7] [baseline=0]\n", argv[0]);
        return 2;
    }
    const char *tx_bdf = argv[1]; int tx_port = atoi(argv[2]);
    const char *rx_bdf = argv[3]; int rx_port = atoi(argv[4]);
    int burst_ms = (argc>5)?atoi(argv[5]):20;
    uint32_t fid = (argc>6)?(uint32_t)atoi(argv[6]):7;
    int32_t baseline = (argc>7)?(int32_t)atoi(argv[7]):0;
    const uint32_t SLOT = 0;
    int same = (strcmp(tx_bdf, rx_bdf) == 0);

    pw_vfio_bind(tx_bdf); if (!same) pw_vfio_bind(rx_bdf);
    struct pw_card_backend bt, br;
    if (pw_bar_backend_open(tx_bdf, &bt) != PW_OK) { fprintf(stderr,"open tx %s failed\n",tx_bdf); return 1; }
    if (!same && pw_bar_backend_open(rx_bdf, &br) != PW_OK) { fprintf(stderr,"open rx %s failed\n",rx_bdf); return 1; }
    const struct pw_card_backend_ops *ot = bt.ops;
    void *tc = bt.ctx;
    const struct pw_card_backend_ops *orx = same ? ot : br.ops;
    void *rc = same ? tc : br.ctx;

    struct pw_card_info it={0}; if (ot->card_info) ot->card_info(tc,&it);
    printf("TX=%s port%d  RX=%s port%d  mode=%s  build=0x%08x  fid=%u burst=%dms\n",
           tx_bdf, tx_port, rx_bdf, rx_port, same?"SAME-CARD (counter-direct)":"CROSS-CARD (GPIO-corrected)",
           it.build_id, fid, burst_ms);

    /* disable all generators on both cards (a stray gen on the RX card would
     * collide on the link; on the TX card we then program exactly one). */
    struct pwfpga_flow_config zf = {0};
    unsigned nft = it.num_local_flows?it.num_local_flows:32;
    for (unsigned r=0;r<nft;r++) ot->flow_write(tc,r,&zf);
    ot->flow_commit(tc);
    if (!same) {
        struct pw_card_info ir={0}; if (orx->card_info) orx->card_info(rc,&ir);
        unsigned nfr = ir.num_local_flows?ir.num_local_flows:32;
        for (unsigned r=0;r<nfr;r++) orx->flow_write(rc,r,&zf);
        orx->flow_commit(rc);
    }

    /* RX card: classify inbound TEST fid -> TEST_RX checker SLOT */
    orx->write32(rc, PWFPGA_FLOWID_MAP_ENTRY(PWFPGA_WIN_FLOWID_MAP, fid), PWFPGA_FLOWID_MAP_VALID|SLOT);

    /* TX card: one TEST gen flow out tx_port */
    struct pwfpga_flow_config f = {0};
    f.enable=1; f.egress_local_port=(uint8_t)tx_port; f.global_flow_id=fid; f.local_flow_id=SLOT;
    set_mac(f.dst_mac,0x02a502000002ULL); set_mac(f.src_mac,0x02a502000001ULL);
    f.ip_version=4; f.src_ipv4=0xC0000201; f.dst_ipv4=0xC0000202;
    f.ttl=64; f.udp_src_port=49152; f.udp_dst_port=50000+fid;
    f.frame_len_min=256; f.frame_len_max=256; f.frame_len_step=1;
    f.rate_bps=1000000000ULL;
    { unsigned __int128 num=(unsigned __int128)f.rate_bps*65536u;
      unsigned __int128 den=(unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ*8u;
      f.tokens_per_tick_fp=(uint32_t)(num/den); }
    f.burst_bytes=256; f.payload_mode=PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence=1; f.insert_timestamp=1; f.tx_enable=1;
    if (ot->flow_write(tc,SLOT,&f)!=PW_OK || ot->flow_commit(tc)!=PW_OK) { fprintf(stderr,"gen program failed\n"); return 1; }

    /* cross-card: J5 sync TX=master, RX=slave */
    if (!same) {
        orx->write32(rc, PWFPGA_REG_GPIO_SYNC_CTRL, gpio_ctrl(1,0,0,0,1,0));
        ot->write32(tc, PWFPGA_REG_GPIO_SYNC_CTRL, gpio_ctrl(1,1,0,0,1,15));
    }

    orx->write32(rc, PWFPGA_REG_STATS_CLEAR, 1);
    struct timespec settle={0,50*1000000L}; nanosleep(&settle,NULL);

    uint64_t off_b=0, off_a=0;
    if (!same) off_b = gpio_ts(ot,tc) - gpio_ts(orx,rc);
    struct timespec burst={burst_ms/1000,(long)(burst_ms%1000)*1000000L}; nanosleep(&burst,NULL);
    if (!same) off_a = gpio_ts(ot,tc) - gpio_ts(orx,rc);

    if (orx->stats_snapshot) orx->stats_snapshot(rc);
    struct pw_flow_stats rs={0}; orx->flow_stats_read(rc,SLOT,&rs);

    /* stop */
    f.tx_enable=0; f.enable=0; ot->flow_write(tc,SLOT,&f); ot->flow_commit(tc);
    if (!same) { ot->write32(tc,PWFPGA_REG_GPIO_SYNC_CTRL,0); orx->write32(rc,PWFPGA_REG_GPIO_SYNC_CTRL,0); }

    uint32_t off32 = same ? 0 : (uint32_t)(off_b + (off_a-off_b)/2);
    int32_t cmin = (int32_t)(uint32_t)(rs.min_latency + off32);
    int32_t cmax = (int32_t)(uint32_t)(rs.max_latency + off32);

    printf("\n=== port-to-port one-way latency ===\n");
    printf("RX rx_frames=%llu samples=%llu\n",
           (unsigned long long)rs.rx_frames, (unsigned long long)rs.sample_count);
    if (rs.sample_count==0) { printf("NO samples -- check the %s link / cabling / flow_id.\n",
                                     same?"port%d->port%d":"cross-card");
        pw_card_backend_close(&bt); if(!same) pw_card_backend_close(&br); return 1; }
    if (!same) {
        long long drift=(long long)(off_a-off_b);
        printf("offset(TX-RX): avg=%u (drift over burst=%lld ticks = skew, bounds precision)\n", off32, drift);
    }
    printf("one-way latency: min=%d max=%d ticks  =>  min=%.1f ns  max=%.1f ns%s\n",
           cmin, cmax, cmin*6.4, cmax*6.4, same?"  (counter-direct, exact)":"");
    if (baseline==0 && !same)
        printf("ZERO-POINT: re-run with baseline=%d for DUT-only latency (bias cancels).\n", cmin);
    else if (baseline!=0)
        printf("DUT latency (minus baseline %d): min=%d max=%d ticks => %.1f .. %.1f ns\n",
               baseline, cmin-baseline, cmax-baseline, (cmin-baseline)*6.4, (cmax-baseline)*6.4);

    pw_card_backend_close(&bt); if(!same) pw_card_backend_close(&br);
    return 0;
}
