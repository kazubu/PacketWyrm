/* PacketWyrm RFC 2544 benchmark driver (single-card / loopback or DUT).
 *
 * Automates the RFC 2544 methodology on the streaming data plane: for each of
 * the standard frame sizes it
 *   - Throughput: binary-searches the max offered rate with zero sequence loss,
 *   - Latency:    reports min/avg/max one-way latency at that rate,
 *   - Frame loss: sweeps the rate and reports loss% at each point.
 *
 * One TEST_RX flow generates on egress 1; over the DAC (or DUT) the frames
 * arrive on RX0 where the flow-id map classifies them into checker slot 0. The
 * generator is rate-limited in HW (token bucket), the checker measures loss +
 * latency, so each trial is just: program {rate, frame_len} -> clear -> run ->
 * snapshot. On a cable loopback this characterises the tester itself (the
 * "DUT" is lossless); cable it to a DUT for a real RFC 2544 run.
 *
 *   sudo pw_rfc2544 <bdf> [trial_ms]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t d[6], uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}

/* RFC 2544 frame sizes (L2 payload incl headers, excl FCS/IFG). */
static const int FRAME_SIZES[] = { 64, 128, 256, 512, 1024, 1280, 1518 };
#define N_SIZES ((int)(sizeof FRAME_SIZES / sizeof FRAME_SIZES[0]))
#define LINE_BPS 10000000000ull          /* 10 GbE */

/* Wire rate for a given L2 frame size at line rate: each frame occupies
 * frame + 12 (IFG) + 8 (preamble/SFD) + 4 (FCS) bytes on the wire. */
static double line_pps(int frame) { return (double)LINE_BPS / ((frame + 24) * 8.0); }

static void build_flow(struct pwfpga_flow_config *f, uint64_t rate_bps, int frame_len) {
    memset(f, 0, sizeof *f);
    f->enable = 1; f->egress_local_port = 1; f->global_flow_id = 1; f->local_flow_id = 0;
    f->logical_if_id = 1000;
    set_mac(f->dst_mac, 0x02a502000102ULL);
    set_mac(f->src_mac, 0x02a502000101ULL);
    f->ip_version = 4; f->src_ipv4 = 0xC0000201; f->dst_ipv4 = 0xC6336401;
    f->ttl = 64; f->udp_src_port = 49152; f->udp_dst_port = 50001;
    f->frame_len_min = (uint16_t)frame_len; f->frame_len_max = (uint16_t)frame_len;
    f->frame_len_step = 1;
    f->rate_bps = rate_bps;
    {
        unsigned __int128 num = (unsigned __int128)rate_bps * 65536u;
        unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
        unsigned __int128 q = den ? (num / den) : 0;
        f->tokens_per_tick_fp = (q > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)q;
    }
    /* Bucket depth = several frames. A 1-frame bucket can't absorb the
     * generator's per-frame build bubble, which throttles the offered rate
     * well below line rate (measured ~71%); 8 frames lets it reach line. */
    { int bb = frame_len * 8; f->burst_bytes = (uint16_t)(bb > 0xFFFF ? 0xFFFF : bb); }
    f->payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    f->insert_sequence = 1; f->insert_timestamp = 1;
    f->tx_enable = 1; f->rx_check_enable = 1;
}

struct trial { uint64_t tx, rx, lost; double min_ns, avg_ns, max_ns; };

/* Program {rate, frame}, re-baseline, run trial_ms, snapshot slot 0. */
static void run_trial(const struct pw_card_backend_ops *o, void *ctx,
                      uint64_t rate_bps, int frame, int trial_ms, struct trial *t) {
    struct pwfpga_flow_config f;
    build_flow(&f, rate_bps, frame);
    o->flow_write(ctx, 0, &f); o->flow_commit(ctx);
    usleep(30000);                                 /* let the new rate settle (token bucket drain) */
    if (o->write32) o->write32(ctx, PWFPGA_REG_STATS_CLEAR, 1u);  /* re-baseline */
    usleep((useconds_t)trial_ms * 1000);
    o->stats_snapshot(ctx);
    struct pw_flow_stats st = {0};
    o->flow_stats_read(ctx, 0, &st);
    const double NS = 1e9 / (double)PWFPGA_DATA_PLANE_CLOCK_HZ;   /* 6.4 ns/tick */
    t->tx = st.tx_frames; t->rx = st.rx_frames; t->lost = st.lost_packets_estimated;
    t->min_ns = st.min_latency * NS; t->max_ns = st.max_latency * NS;
    t->avg_ns = st.sample_count ? ((double)st.sum_latency / st.sample_count) * NS : 0.0;
}

/* zero-loss = no estimated SEQUENCE loss (the authoritative metric). The raw
 * tx-vs-rx count skews by the in-flight + non-atomic-snapshot delta at high
 * rate, so it is NOT a loss signal; lost_packets_estimated (sequence gaps) is. */
static int zero_loss(const struct trial *t) {
    return t->lost == 0 && t->rx > 0;
}

/* PacketWyrm test frame floor: eth(14)+IPv4(20)+UDP(8)+test header(32) = 74 B.
 * Smaller frames can't carry the sequence/timestamp signature, so loss/latency
 * are unmeasurable there (a count-based header-classified path would be needed). */
#define TEST_FRAME_MIN 74

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [trial_ms]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int trial_ms = (argc >= 3) ? atoi(argv[2]) : 100;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->flow_write || !o->stats_snapshot || !o->flow_stats_read) {
        fprintf(stderr, "backend lacks flow/stats ops\n"); return 1;
    }
    /* Clear any stale flow rows left by a prior run/config so only our single
     * test flow generates (otherwise leftover rows keep transmitting + skew the
     * loopback). */
    {
        struct pw_card_info info = {0};
        if (o->card_info) o->card_info(be.ctx, &info);
        unsigned nf = info.num_local_flows ? info.num_local_flows : 32;
        struct pwfpga_flow_config zf = {0};
        for (unsigned r = 0; r < nf; r++) o->flow_write(be.ctx, r, &zf);
        if (o->flow_commit) o->flow_commit(be.ctx);
    }
    /* Classify the test flow (flow_id 1) into checker slot 0 via the flow-id map. */
    if (o->write32) o->write32(be.ctx, PWFPGA_WIN_FLOWID_MAP + 1u * 4u,
                               PWFPGA_FLOWID_MAP_VALID | 0u);

    printf("RFC 2544 (trial %d ms/point, 10 GbE line rate, loopback/DUT on p1->p0)\n", trial_ms);
    printf("%-6s %12s %10s %8s  %8s %8s %8s\n",
           "frame", "thru(Mbps)", "thru(%)", "loss@LR", "lat_min", "lat_avg", "lat_max");

    for (int i = 0; i < N_SIZES; i++) {
        int frame = FRAME_SIZES[i];
        /* RFC 2544 frame sizes are the full L2 frame *including* the 4-byte FCS.
         * The MAC appends FCS, so the generator must emit (size - 4); otherwise a
         * "1518" frame goes out as 1522 on the wire and trips the MAC oversize
         * drop. line_pps still uses the full wire size (incl FCS + IFG/preamble). */
        int gen_len = frame - 4;
        if (gen_len < TEST_FRAME_MIN) {
            printf("%-6d %12s %10s %8s  %8s %8s %8s\n", frame,
                   "n/a", "n/a", "n/a", "<74B", "test", "floor");
            continue;
        }
        uint64_t line = (uint64_t)(line_pps(frame) * (frame + 24) * 8.0);  /* ~= LINE_BPS */
        struct trial t;

        /* Throughput: binary-search the offered rate for zero loss (Mbps). */
        uint64_t lo = 0, hi = LINE_BPS / 1000000ull;   /* Mbps */
        for (int it = 0; it < 12; it++) {
            uint64_t mid = (lo + hi + 1) / 2;
            run_trial(o, be.ctx, mid * 1000000ull, gen_len, trial_ms, &t);
            if (zero_loss(&t)) lo = mid; else hi = mid - 1;
        }
        uint64_t thru_mbps = lo;

        /* Latency at the throughput rate. */
        run_trial(o, be.ctx, thru_mbps * 1000000ull, gen_len, trial_ms, &t);
        double lat_min = t.min_ns, lat_avg = t.avg_ns, lat_max = t.max_ns;

        /* Frame loss at line rate. */
        run_trial(o, be.ctx, line, gen_len, trial_ms, &t);
        double loss_lr = t.tx ? (100.0 * (double)t.lost / (double)t.tx) : 0.0;
        double thru_pct = 100.0 * (double)thru_mbps / (double)(LINE_BPS / 1000000ull);

        printf("%-6d %12llu %9.1f%% %7.3f%%  %7.0f %7.0f %7.0f\n",
               frame, (unsigned long long)thru_mbps, thru_pct, loss_lr,
               lat_min, lat_avg, lat_max);
        fflush(stdout);
    }

    /* Stop the generator. */
    { struct pwfpga_flow_config f; build_flow(&f, 0, 64); f.tx_enable = 0; f.enable = 0;
      o->flow_write(be.ctx, 0, &f); o->flow_commit(be.ctx); }
    pw_card_backend_close(&be);
    return 0;
}
