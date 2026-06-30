/* PacketWyrm Phase 3: DP_RESET (data-plane soft-reset) recovery test.
 *
 * Confirms the data plane does NOT permanently wedge: programs a generator
 * flow on egress 0, verifies TX is advancing, then repeatedly pulses
 * DP_RESET (which resets the wedge-prone gen / SAF / arbiter state machines
 * and flushes the MAC-TX CDC + pw_ts_insert) and verifies TX RESUMES
 * advancing after each. A stuck data plane would show TX frozen after a
 * reset.
 *
 *   sudo pw_dp_reset_recover <bdf> [rounds]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t *d, uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}

static uint64_t tx_sum(const struct pw_card_backend_ops *o, void *ctx) {
    if (o->stats_snapshot) o->stats_snapshot(ctx);
    struct pw_port_stats p0 = {0}, p1 = {0};
    if (o->port_stats_read) { o->port_stats_read(ctx, 0, &p0); o->port_stats_read(ctx, 1, &p1); }
    return (uint64_t)p0.tx_frames + (uint64_t)p1.tx_frames;
}
static int links_up(const struct pw_card_backend_ops *o, void *ctx) {
    struct pw_port_stats p0 = {0}, p1 = {0};
    if (o->port_stats_read) { o->port_stats_read(ctx, 0, &p0); o->port_stats_read(ctx, 1, &p1); }
    return (p0.link_up_count > 0) && (p1.link_up_count > 0)
        && (p0.link_down_count == p0.link_up_count - 1 || p0.link_down_count <= p0.link_up_count)
        && (p1.link_down_count <= p1.link_up_count);
}
/* Burn CSR reads to let traffic flow between samples (each read is a PCIe RTT). */
static void burn(const struct pw_card_backend_ops *o, void *ctx, long n) {
    volatile uint32_t junk = 0;
    for (long k = 0; k < n; k++) { uint32_t v; o->read32(ctx, 0x0, &v); junk += v; }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [rounds]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int rounds = (argc > 2) ? atoi(argv[2]) : 3;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: build=0x%08x\n", bdf, info.build_id);

    /* Program a generator flow on egress 0 (mirrors pw_phase3_modgen's setup). */
    struct pwfpga_flow_config f = {0};
    f.enable = 1; f.egress_local_port = 0; f.global_flow_id = 2; f.local_flow_id = 0;
    set_mac(f.dst_mac, 0x02a502000004ULL); set_mac(f.src_mac, 0x02a502000003ULL);
    f.ip_version = 4; f.src_ipv4 = 0xC6336401; f.dst_ipv4 = 0xC6336400;
    f.ttl = 64; f.udp_src_port = 49152; f.udp_dst_port = 50001;
    f.frame_len_min = 256; f.frame_len_max = 256; f.frame_len_step = 1;
    f.rate_bps = 9000000000ULL;   /* high rate to keep the TX FIFO busy */
    { unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
      unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
      f.tokens_per_tick_fp = (uint32_t)(num / den); }
    f.burst_bytes = 256; f.payload_mode = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence = 1; f.insert_timestamp = 1; f.tx_enable = 1;
    { struct pwfpga_flow_config zf = {0};
      unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
      for (unsigned r = 0; r < nf; r++) o->flow_write(be.ctx, r, &zf); }
    if (o->flow_write(be.ctx, 0, &f) != PW_OK || o->flow_commit(be.ctx) != PW_OK) {
        fprintf(stderr, "FATAL: flow_write/commit failed\n"); return 1;
    }

    /* Pre-check: the generator must be advancing TX before we test recovery. */
    uint64_t a = tx_sum(o, be.ctx); burn(o, be.ctx, 400000); uint64_t b = tx_sum(o, be.ctx);
    printf("baseline: tx %llu -> %llu (delta %llu), links_up=%d\n",
           (unsigned long long)a, (unsigned long long)b,
           (unsigned long long)(b - a), links_up(o, be.ctx));
    if (b <= a) {
        fprintf(stderr, "ERROR: generator did not start (no TX activity)\n");
        return 1;
    }

    int fails = 0;
    for (int r = 0; r < rounds; r++) {
        /* Pulse the data-plane soft reset. */
        if (!o->write32) { fprintf(stderr, "backend lacks write32\n"); return 1; }
        o->write32(be.ctx, PWFPGA_REG_DP_RESET, 1);
        /* Give the stretched pulse + TX-CDC flush time to complete, then sample. */
        burn(o, be.ctx, 200000);
        uint64_t c = tx_sum(o, be.ctx);
        burn(o, be.ctx, 600000);
        uint64_t d = tx_sum(o, be.ctx);
        int up = links_up(o, be.ctx);
        uint64_t delta = d - c;
        int ok = (delta > 0) && up;
        printf("round %d: DP_RESET -> tx %llu -> %llu (delta %llu) links_up=%d : %s\n",
               r, (unsigned long long)c, (unsigned long long)d,
               (unsigned long long)delta, up, ok ? "RECOVERED" : "STUCK");
        if (!ok) fails++;
    }

    /* Disable the flow on the way out. */
    f.tx_enable = 0; f.enable = 0;
    o->flow_write(be.ctx, 0, &f); o->flow_commit(be.ctx);

    if (fails == 0) { printf("RESULT: PASS (TX recovered after every DP_RESET, no wedge)\n"); return 0; }
    printf("RESULT: FAIL (%d/%d DP_RESET rounds left TX stuck)\n", fails, rounds);
    return 1;
}
