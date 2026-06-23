/* PacketWyrm Phase 3 hardware PUNT / slow-path test (one-shot).
 *
 * Validates the FPGA -> host slow-path on silicon. A generator on egress 0
 * emits test frames out TX0; over the DAC they arrive on RX1, where a
 * classifier PUNT_TO_HOST rule (logical_if_id = LIF) sends them through the
 * SAF + punt arbiter into pw_punt_rx_window. The host drains them via
 * bar_slow_path_rx and checks the byte count + returned logical_if_id.
 *
 *   gen[0] -> TX0 -> DAC -> RX1 -[classifier: PUNT, lif=LIF]-> punt window
 *          -> bar_slow_path_rx (this program)
 *
 * Generates at a modest rate so the single-frame punt window is not
 * perpetually overwhelmed (slow-path does not keep line rate; some loss at
 * the SAF is expected and fine -- the point is that punted frames reach the
 * host intact with the right metadata).
 *
 *   sudo pw_phase3_punt <bdf> [frames] [lif]
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

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [frames] [lif]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int      want   = (argc >= 3) ? atoi(argv[2]) : 16;
    uint32_t lif    = (argc >= 4) ? (uint32_t)strtoul(argv[3], NULL, 0) : 0x00000077u;

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->slow_path_rx) { fprintf(stderr, "backend has no slow_path_rx\n"); return 1; }

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x version=0x%08x ports=%u flows=%u classifier=%u\n",
           bdf, info.device_id, info.version, info.num_local_ports,
           info.num_local_flows, info.num_classifier_entries);

    /* --- generator flow on egress 0 (emits test flow_id 2), low rate --- */
    struct pwfpga_flow_config f = {0};
    f.enable            = 1;
    f.egress_local_port = 0;
    f.global_flow_id    = 2;
    f.local_flow_id     = 0;
    f.logical_if_id     = 1001;
    set_mac(f.dst_mac, 0x02a502000004ULL);
    set_mac(f.src_mac, 0x02a502000003ULL);
    f.ip_version   = 4;
    f.src_ipv4     = 0xC6336401;
    f.dst_ipv4     = 0xC6336402;
    f.ttl          = 64;
    f.udp_src_port = 49152;
    f.udp_dst_port = 50001;
    f.frame_len_min = 256; f.frame_len_max = 256; f.frame_len_step = 1;
    f.rate_bps     = 10000000ULL;   /* 10 Mbps -- slow enough to drain by poll */
    f.burst_size   = 1;
    {
        unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
        unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
        f.tokens_per_tick_fp = (uint32_t)(num / den);
    }
    f.burst_bytes      = 256;
    f.payload_mode     = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence  = 1;
    f.insert_timestamp = 1;
    f.tx_enable        = 1;
    f.rx_check_enable  = 0;

    /* Clear stale flow rows first (tables persist across runs). */
    {
        struct pwfpga_flow_config zf = {0};
        unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
        for (unsigned r = 0; r < nf; r++) if (o->flow_write) o->flow_write(be.ctx, r, &zf);
    }

    /* --- field-classifier rule 0: PUNT frames (ingress 1, udp_dst 50001) --- */
    pw_tool_fc_ing_udp(o, be.ctx, /*cmp0*/0, /*rule*/0, /*ingress*/1, /*udp_dst*/50001,
                       PWFPGA_ACT_PUNT_TO_HOST, /*egress*/0, /*lfid*/0, lif);

    if (o->flow_write) o->flow_write(be.ctx, 0, &f);
    if (o->flow_commit) o->flow_commit(be.ctx);

    printf("programmed: gen on egress 0 (flow_id 2), PUNT(ingress1, lif=0x%x)\n", lif);
    printf("path: gen[0] -> RX1 -[PUNT]-> punt window -> slow_path_rx\n");

    /* Drain punted frames. */
    int    got = 0, lif_ok = 0, len_ok = 0;
    size_t min_len = (size_t)-1, max_len = 0;
    uint8_t buf[PWFPGA_PUNT_MAX_FRAME];
    uint64_t prev_ts = 0; int ts_mono = 1;
    for (long spins = 0; got < want && spins < 50000000L; spins++) {
        uint32_t got_lif = 0; uint64_t rx_ts = 0;
        int n = o->slow_path_rx(be.ctx, buf, sizeof(buf), &got_lif, &rx_ts);
        if (n > 0) {
            got++;
            if (got_lif == lif) lif_ok++;
            if (n >= 60)        len_ok++;     /* a full test frame is well over 60 B */
            if ((size_t)n < min_len) min_len = (size_t)n;
            if ((size_t)n > max_len) max_len = (size_t)n;
            if (got > 1 && rx_ts < prev_ts) ts_mono = 0;   /* RX timestamps must advance */
            prev_ts = rx_ts;
            if (got <= 4)
                printf("  frame %d: %d bytes, lif=0x%x, rx_ts=%llu, first=%02x%02x%02x%02x\n",
                       got, n, got_lif, (unsigned long long)rx_ts, buf[0], buf[1], buf[2], buf[3]);
        }
    }

    printf("RESULT: punted=%d/%d  lif_ok=%d  len>=60=%d  len[min..max]=%zu..%zu  rx_ts_monotonic=%d\n",
           got, want, lif_ok, len_ok, (got ? min_len : 0), max_len, ts_mono);

    /* Stop the generator so it does not keep flooding after we exit. */
    f.tx_enable = 0; f.enable = 0;
    if (o->flow_write) o->flow_write(be.ctx, 0, &f);
    if (o->flow_commit) o->flow_commit(be.ctx);

    pw_card_backend_close(&be);
    return (got >= want && lif_ok == got && ts_mono) ? 0 : 1;
}
