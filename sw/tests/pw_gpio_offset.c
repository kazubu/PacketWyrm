/* PacketWyrm Phase 3: J5 cross-card counter OFFSET / SKEW measurement.
 *
 * Opens TWO cards in one process and reads their pw_gpio_sync latched
 * timestamps back-to-back (a few us apart, << the master's pulse period), so
 * both reflect the SAME shared J5 edge. With one card master and the other
 * slave, the difference of the two latched counters is the inter-card counter
 * OFFSET at that instant; its drift over time is the SKEW (relative clock-rate
 * error). This is the raw input a software time-sync servo would consume.
 *
 * Pairing: each card bumps an edge sequence; seqA-seqB is constant while both
 * track every edge. Samples where seqA-seqB equals the steady delta are a
 * coherent same-edge pair; samples where an edge fell between the two reads
 * (delta +/-1) are dropped.
 *
 *   sudo pw_gpio_offset <bdfA(master)> <bdfB(slave)> [samples=30] [interval_ms=200]
 *
 * (Configure roles first: pw_gpio_sync <A> master ; pw_gpio_sync <B> slave.)
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void rd(const struct pw_card_backend_ops *o, void *ctx, uint32_t *seq, uint64_t *ts) {
    uint32_t lo = 0, hi = 0;
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_LOW,  &lo);   /* low first latches high */
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_HIGH, &hi);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_SEQ,     seq);
    *ts = ((uint64_t)hi << 32) | lo;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <bdfA-master> <bdfB-slave> [samples=30] [interval_ms=200]\n", argv[0]);
        return 2;
    }
    const char *bdfA = argv[1], *bdfB = argv[2];
    int n  = (argc > 3) ? atoi(argv[3]) : 30;
    int ms = (argc > 4) ? atoi(argv[4]) : 200;

    pw_vfio_bind(bdfA); pw_vfio_bind(bdfB);
    struct pw_card_backend ba, bb;
    if (pw_bar_backend_open(bdfA, &ba) != PW_OK) { fprintf(stderr, "open %s failed\n", bdfA); return 1; }
    if (pw_bar_backend_open(bdfB, &bb) != PW_OK) { fprintf(stderr, "open %s failed\n", bdfB); return 1; }
    const struct pw_card_backend_ops *oa = ba.ops, *ob = bb.ops;

    struct timespec iv = { ms / 1000, (long)(ms % 1000) * 1000000L };

    /* establish the steady seq delta from a first read */
    uint32_t sa0 = 0, sb0 = 0; uint64_t ta0 = 0, tb0 = 0;
    rd(oa, ba.ctx, &sa0, &ta0); rd(ob, bb.ctx, &sb0, &tb0);
    int64_t D = (int64_t)sa0 - (int64_t)sb0;
    printf("steady seqA-seqB delta D=%lld (edges A leads B); pulse must be running\n",
           (long long)D);

    int64_t off_min = INT64_MAX, off_max = INT64_MIN;
    long double off_sum = 0; int kept = 0, dropped = 0;
    int64_t first_off = 0, last_off = 0; uint64_t first_ts = 0, last_ts = 0;

    for (int i = 0; i < n; i++) {
        uint32_t sa = 0, sb = 0; uint64_t ta = 0, tb = 0;
        rd(oa, ba.ctx, &sa, &ta);
        rd(ob, bb.ctx, &sb, &tb);
        int64_t d = (int64_t)sa - (int64_t)sb;
        int64_t off = (int64_t)(ta - tb);   /* A_counter - B_counter at the shared edge */
        int coherent = (d == D);
        printf("[%2d] seqA=%u seqB=%u d=%lld %s offset(A-B)=%lld ticks\n",
               i, sa, sb, (long long)d, coherent ? "OK " : "skip",
               (long long)off);
        if (coherent) {
            if (off < off_min) off_min = off;
            if (off > off_max) off_max = off;
            off_sum += off;
            if (kept == 0) { first_off = off; first_ts = ta; }
            last_off = off; last_ts = ta;
            kept++;
        } else dropped++;
        if (i < n - 1) nanosleep(&iv, NULL);
    }

    printf("\n=== offset/skew summary ===\n");
    if (kept >= 1) {
        long double avg = off_sum / kept;
        printf("offset(A-B): avg=%.1Lf  min=%lld  max=%lld  spread=%lld ticks  (kept %d, dropped %d)\n",
               avg, (long long)off_min, (long long)off_max,
               (long long)(off_max - off_min), kept, dropped);
        printf("  (1 tick = 6.4 ns @156.25MHz -> avg offset ~= %.3Lf us; spread ~= %.1Lf ns)\n",
               avg * 6.4L / 1000.0L, (long double)(off_max - off_min) * 6.4L);
        if (kept >= 2 && last_ts != first_ts) {
            long double dskew = (long double)(last_off - first_off);
            long double dtime = (long double)(last_ts - first_ts);   /* A ticks elapsed */
            long double ppm = dskew / dtime * 1e6L;
            printf("skew: d(offset)=%lld ticks over %.0Lf ticks elapsed -> %.3Lf ppm\n",
                   (long long)(last_off - first_off), dtime, ppm);
        }
    } else {
        printf("no coherent samples -- is the master pulsing and the slave wired/listening?\n");
    }

    pw_card_backend_close(&ba);
    pw_card_backend_close(&bb);
    return kept > 0 ? 0 : 1;
}
