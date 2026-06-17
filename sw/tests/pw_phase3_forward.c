/* PacketWyrm Phase 3 hardware FORWARD test (one-shot).
 *
 * Validates the store-and-forward (SAF) path on silicon. The classifier
 * window hardwires the FORWARD egress port to 0 ("not in wire struct yet"),
 * so the test routes a generated frame through the SAF on egress 0:
 *
 *   gen[1] -> TX1 -> DAC -> RX0 -[classifier: FORWARD]-> SAF -> TX0
 *          -> DAC -> RX1 -[classifier: TEST_RX]-> checker
 *
 * The generator runs on egress port 1 (emitting test flow_id 2). A
 * classifier rule on ingress 0 FORWARDs those frames (egress 0 = TX0); a
 * second rule on ingress 1 counts the re-emitted copies as TEST_RX. If the
 * SAF forwards reliably, the checker sees loss=0 -- frames that crossed the
 * DAC twice and were store-and-forwarded in between.
 *
 * The flow compiler has no forward-rule construct, so the flow row and the
 * two classifier rows are built and programmed directly via the backend.
 *
 *   sudo pw_phase3_forward <bdf> [iters] [burn]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t d[6], uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [iters] [burn] [fwd_egress]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    int  iters = (argc >= 3) ? atoi(argv[2]) : 6;
    long burn  = (argc >= 4) ? atol(argv[3]) : 300000;
    /* FORWARD egress port to validate (default 1 -- exercises the now
     * wire-carried egress field; pass 0 for the legacy egress-0 path).
     * Topology is mirrored around it so frames cross the DAC twice:
     *   gen[1-fe] -> RX[fe] -[FORWARD egress=fe]-> SAF -> TX[fe]
     *             -> RX[1-fe] -[TEST_RX]-> checker
     */
    int  fe        = (argc >= 5) ? atoi(argv[4]) : 1;
    if (fe < 0 || fe > 1) { fprintf(stderr, "fwd_egress must be 0 or 1\n"); return 2; }
    int  gen_egr   = 1 - fe;   /* generator emits out the opposite port   */
    int  fwd_ingr  = fe;       /* forwarded frames are matched here        */
    int  chk_ingr  = 1 - fe;   /* re-emitted copies are TEST_RX'd here     */

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x version=0x%08x ports=%u flows=%u classifier=%u\n",
           bdf, info.device_id, info.version, info.num_local_ports,
           info.num_local_flows, info.num_classifier_entries);

    /* --- generator flow row on egress port (1-fe) (emits test flow_id 2) --- */
    struct pwfpga_flow_config f = {0};
    f.enable            = 1;
    f.egress_local_port = (uint8_t)gen_egr;
    f.global_flow_id    = 2;
    f.local_flow_id     = 0;
    f.logical_if_id     = 1001;
    set_mac(f.dst_mac, 0x02a502000004ULL);
    set_mac(f.src_mac, 0x02a502000003ULL);
    f.ip_version   = 4;
    f.src_ipv4     = 0xC6336401;   /* 198.51.100.1 */
    f.dst_ipv4     = 0xC6336402;   /* 198.51.100.2 */
    f.ttl          = 64;
    f.udp_src_port = 49152;
    f.udp_dst_port = 50001;
    f.frame_len_min = 512; f.frame_len_max = 512; f.frame_len_step = 1;
    f.rate_bps     = 1000000000ULL;
    f.burst_size   = 4;
    {   /* tokens_per_tick_fp = rate_Bps * 65536 / clock_hz (Q16.16) */
        unsigned __int128 num = (unsigned __int128)f.rate_bps * 65536u;
        unsigned __int128 den = (unsigned __int128)PWFPGA_DATA_PLANE_CLOCK_HZ * 8u;
        f.tokens_per_tick_fp = (uint32_t)(num / den);
    }
    f.burst_bytes      = 512;      /* >= one frame so the bucket can fill */
    f.payload_mode     = PWFPGA_PAYLOAD_INCREMENT;
    f.insert_sequence  = 1;
    f.insert_timestamp = 1;
    f.tx_enable        = 1;
    f.rx_check_enable  = 0;

    /* Clear all classifier + flow rows first -- the live tables persist
     * across runs (no data-plane reset between tool invocations), so stale
     * rules from a previous test would also match and corrupt the result. */
    {
        struct pwfpga_classifier_entry zc = {0};
        struct pwfpga_flow_config      zf = {0};
        unsigned nc = info.num_classifier_entries ? info.num_classifier_entries : 8;
        unsigned nf = info.num_local_flows ? info.num_local_flows : 8;
        for (unsigned r = 0; r < nc; r++) if (o->classifier_write) o->classifier_write(be.ctx, r, &zc);
        for (unsigned r = 0; r < nf; r++) if (o->flow_write) o->flow_write(be.ctx, r, &zf);
    }

    /* NOTE: the RX checker's per-flow sequence state is NOT reset between
     * tool invocations. Run each egress case from a freshly reconfigured
     * data plane; a back-to-back invocation reusing local_flow_id 0 will
     * report out_of_order against the previous run's stale expected_seq
     * (the forwarding itself is unaffected -- lost stays ~0). */

    /* --- classifier rule 0: FORWARD frames arriving on ingress fwd_ingr --- */
    struct pwfpga_classifier_entry fwd = {0};
    fwd.key.ingress_local_port = (uint8_t)fwd_ingr; fwd.mask.ingress_local_port = 0xFF;
    fwd.key.udp_dst_port       = 50001;   fwd.mask.udp_dst_port       = 0xFFFF;
    fwd.key.test_magic         = 0xA5027E57; fwd.mask.test_magic      = 0xFFFFFFFF;
    fwd.key.global_flow_id     = 2;       fwd.mask.global_flow_id     = 0xFFFFFFFF;
    fwd.action            = PWFPGA_ACT_FORWARD_PORT;
    fwd.egress_local_port = (uint8_t)fe;  /* now wire-carried into the classifier */
    fwd.priority = 5;
    fwd.flags    = PWFPGA_CLS_FLAG_ENABLE;
    if (o->classifier_write) o->classifier_write(be.ctx, 0, &fwd);

    /* --- classifier rule 1: TEST_RX the re-emitted copies on ingress chk_ingr --- */
    struct pwfpga_classifier_entry chk = {0};
    chk.key.ingress_local_port = (uint8_t)chk_ingr; chk.mask.ingress_local_port = 0xFF;
    chk.key.udp_dst_port       = 50001;   chk.mask.udp_dst_port       = 0xFFFF;
    chk.key.test_magic         = 0xA5027E57; chk.mask.test_magic      = 0xFFFFFFFF;
    chk.key.global_flow_id     = 2;       chk.mask.global_flow_id     = 0xFFFFFFFF;
    chk.action        = PWFPGA_ACT_TEST_RX;
    chk.local_flow_id = 0;
    chk.priority      = 5;
    chk.flags         = PWFPGA_CLS_FLAG_ENABLE;
    if (o->classifier_write) o->classifier_write(be.ctx, 1, &chk);
    if (o->classifier_commit) o->classifier_commit(be.ctx);

    /* Start the generator only after the classifier is committed, so no
     * frames arrive before the FORWARD rule exists (else they'd DROP). */
    if (o->flow_write) o->flow_write(be.ctx, 0, &f);
    if (o->flow_commit) o->flow_commit(be.ctx);

    printf("programmed: gen on egress %d (flow_id 2), FORWARD(ingress%d->egress%d) + "
           "TEST_RX(ingress%d, lf=0)\n", gen_egr, fwd_ingr, fe, chk_ingr);
    printf("path: gen[%d] -> RX%d -[FWD]-> SAF -> TX%d -> RX%d -[TEST_RX]-> checker\n",
           gen_egr, fwd_ingr, fe, chk_ingr);

    for (int it = 0; it < iters; it++) {
        volatile uint32_t junk = 0;
        for (long k = 0; k < burn; k++) { uint32_t v; o->read32(be.ctx, 0x0, &v); junk += v; }
        if (o->stats_snapshot) o->stats_snapshot(be.ctx);
        struct pw_port_stats p0 = {0}, p1 = {0};
        if (o->port_stats_read) { o->port_stats_read(be.ctx, 0, &p0); o->port_stats_read(be.ctx, 1, &p1); }
        struct pw_flow_stats rs = {0};
        if (o->flow_stats_read) o->flow_stats_read(be.ctx, 0, &rs);
        printf("[%d] drops p0=%llu p1=%llu | forwarded+checked rx=%llu lost=%llu dup=%llu "
               "ooo=%llu min_lat=%u max_lat=%u\n", it,
               (unsigned long long)p0.rx_bad_frame, (unsigned long long)p1.rx_bad_frame,
               (unsigned long long)rs.rx_frames,
               (unsigned long long)rs.lost_packets_estimated,
               (unsigned long long)rs.duplicate_count,
               (unsigned long long)rs.out_of_order_count,
               rs.min_latency, rs.max_latency);
    }

    pw_card_backend_close(&be);
    return 0;
}
