/* PacketWyrm Phase 3: cross-card ONE-WAY latency over a card-to-card 10G link,
 * corrected by the J5 GPIO counter offset.
 *
 * Topology: card A port0 --DAC-- card B port0, J5 wired A<->B.
 *   - Card A generates a TEST flow out port0. pw_ts_insert stamps tx_wire_ts in
 *     A's free-running counter at A's MAC TX.
 *   - Card B classifies the inbound TEST frames (flow-id map -> TEST_RX) and the
 *     checker records latency = rx_wire_ts_B - tx_ts_A. Those two stamps are in
 *     DIFFERENT card counters, so the raw figure is true_latency - offset(A-B)
 *     (wraps negative). B does NOT generate (would collide on the shared link).
 *   - The J5 sync gives offset(A-B) = A_counter - B_counter at a shared edge
 *     (pw_gpio_sync: A master, B slave). true_one_way = raw + offset(A-B).
 *
 * Skew (~1.6 ppm) drifts the offset, so this measures the offset just before and
 * after a SHORT traffic burst and corrects with the average; the before/after
 * spread bounds the residual skew error. Min latency is the cleanest figure.
 *
 *   sudo pw_xcard_latency <bdfA-gen> <bdfB-rx> [burst_ms=300] [flow_id=7]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t *d, uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}
/* read a card's latched GPIO-sync counter (low-then-high latches a coherent 64b) */
static uint64_t gpio_ts(const struct pw_card_backend_ops *o, void *ctx) {
    uint32_t lo = 0, hi = 0;
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_LOW,  &lo);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_HIGH, &hi);
    return ((uint64_t)hi << 32) | lo;
}
static uint32_t gpio_ctrl(int en,int master,int rep,int in_sel,int out_sel,int per){
    return (uint32_t)((en&1)|((master&1)<<1)|((rep&1)<<2)|((in_sel&7)<<4)|((out_sel&7)<<8)|((per&0xf)<<16));
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <bdfA-gen> <bdfB-rx> [burst_ms=300] [flow_id=7]\n", argv[0]);
        return 2;
    }
    const char *bdfA = argv[1], *bdfB = argv[2];
    int burst_ms = (argc > 3) ? atoi(argv[3]) : 300;
    uint32_t fid = (argc > 4) ? (uint32_t)atoi(argv[4]) : 7;
    const uint32_t SLOT = 0;

    pw_vfio_bind(bdfA); pw_vfio_bind(bdfB);
    struct pw_card_backend ba, bb;
    if (pw_bar_backend_open(bdfA, &ba) != PW_OK) { fprintf(stderr, "open A %s failed\n", bdfA); return 1; }
    if (pw_bar_backend_open(bdfB, &bb) != PW_OK) { fprintf(stderr, "open B %s failed\n", bdfB); return 1; }
    const struct pw_card_backend_ops *oa = ba.ops, *ob = bb.ops;
    struct pw_card_info ia = {0}, ib = {0};
    if (oa->card_info) oa->card_info(ba.ctx, &ia);
    if (ob->card_info) ob->card_info(bb.ctx, &ib);
    printf("A(gen)=%s build=0x%08x  B(rx)=%s build=0x%08x  flow_id=%u burst=%dms\n",
           bdfA, ia.build_id, bdfB, ib.build_id, fid, burst_ms);

    /* --- disable any generators on BOTH cards (B must not gen onto the link) --- */
    struct pwfpga_flow_config zf = {0};
    unsigned nfa = ia.num_local_flows ? ia.num_local_flows : 32;
    unsigned nfb = ib.num_local_flows ? ib.num_local_flows : 32;
    for (unsigned r = 0; r < nfa; r++) oa->flow_write(ba.ctx, r, &zf);
    oa->flow_commit(ba.ctx);
    for (unsigned r = 0; r < nfb; r++) ob->flow_write(bb.ctx, r, &zf);
    ob->flow_commit(bb.ctx);

    /* --- card B: classify inbound TEST flow_id -> TEST_RX checker SLOT --- */
    ob->write32(bb.ctx, PWFPGA_FLOWID_MAP_ENTRY(PWFPGA_WIN_FLOWID_MAP, fid),
                PWFPGA_FLOWID_MAP_VALID | SLOT);

    /* --- card A: one TEST gen flow out port0 (pw_ts_insert stamps tx_wire_ts) --- */
    struct pwfpga_flow_config f = {0};
    f.enable = 1; f.egress_local_port = 0; f.global_flow_id = fid; f.local_flow_id = SLOT;
    set_mac(f.dst_mac, 0x02a502000002ULL); set_mac(f.src_mac, 0x02a502000001ULL);
    f.ip_version = 4; f.src_ipv4 = 0xC0000201; f.dst_ipv4 = 0xC0000202;
    f.ttl = 64; f.udp_src_port = 49152; f.udp_dst_port = 50000 + fid;
    f.frame_len_min = 256; f.frame_len_max = 256; f.frame_len_step = 1;
    f.rate_bps = 1000000000ULL;
    { unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
      unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
      f.tokens_per_tick_fp = (uint32_t)(num / den); }
    f.burst_bytes = 256; f.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence = 1; f.insert_timestamp = 1; f.tx_enable = 1;
    if (oa->flow_write(ba.ctx, SLOT, &f) != PW_OK || oa->flow_commit(ba.ctx) != PW_OK) {
        fprintf(stderr, "A gen program failed\n"); return 1;
    }

    /* --- J5: A master, B slave (for the offset) --- */
    ob->write32(bb.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, gpio_ctrl(1,0,0,0,1,0));
    oa->write32(ba.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, gpio_ctrl(1,1,0,0,1,15));

    /* baseline B checker, let the J5 edges + traffic settle */
    ob->write32(bb.ctx, PWFPGA_REG_STATS_CLEAR, 1);
    struct timespec settle = {0, 50*1000000L}; nanosleep(&settle, NULL);

    uint64_t off_before = gpio_ts(oa, ba.ctx) - gpio_ts(ob, bb.ctx);

    struct timespec burst = { burst_ms/1000, (long)(burst_ms%1000)*1000000L };
    nanosleep(&burst, NULL);

    uint64_t off_after = gpio_ts(oa, ba.ctx) - gpio_ts(ob, bb.ctx);

    /* read B checker stats for SLOT */
    if (ob->stats_snapshot) ob->stats_snapshot(bb.ctx);
    struct pw_flow_stats rs = {0};
    ob->flow_stats_read(bb.ctx, SLOT, &rs);

    /* stop the generator + sync */
    f.tx_enable = 0; f.enable = 0; oa->flow_write(ba.ctx, SLOT, &f); oa->flow_commit(ba.ctx);
    oa->write32(ba.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, 0);
    ob->write32(bb.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, 0);

    /* --- correct: true_one_way = raw + offset(A-B), 32-bit (min/max are u32) --- */
    uint64_t avg_off = off_before + (off_after - off_before) / 2;
    uint32_t off32   = (uint32_t)avg_off;
    uint32_t cmin = (uint32_t)(rs.min_latency + off32);
    uint32_t cmax = (uint32_t)(rs.max_latency + off32);
    long long drift = (long long)(off_after - off_before);

    printf("\n=== cross-card link + latency ===\n");
    printf("B rx_frames=%llu samples=%llu  (rx_frames>0 confirms A.port0 -> B.port0 link)\n",
           (unsigned long long)rs.rx_frames, (unsigned long long)rs.sample_count);
    if (rs.sample_count == 0) {
        printf("NO TEST samples on B -- check the DAC link / flow_id map / that A is generating.\n");
        pw_card_backend_close(&ba); pw_card_backend_close(&bb); return 1;
    }
    printf("offset(A-B): before=%llu after=%llu avg=%llu (drift over burst=%lld ticks = skew)\n",
           (unsigned long long)off_before, (unsigned long long)off_after,
           (unsigned long long)avg_off, drift);
    printf("raw checker latency (B-timebase, uncorrected): min=%u max=%u ticks\n",
           rs.min_latency, rs.max_latency);
    printf("CORRECTED one-way latency: min=%u max=%u ticks  =>  min=%.1f ns  max=%.1f ns\n",
           cmin, cmax, cmin * 6.4, cmax * 6.4);
    printf("  (residual precision bounded by skew drift over the burst: ~%lld ticks = %.1f ns)\n",
           drift < 0 ? -drift : drift, (drift < 0 ? -drift : drift) * 6.4);

    pw_card_backend_close(&ba);
    pw_card_backend_close(&bb);
    return 0;
}
