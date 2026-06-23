/* PacketWyrm Phase 3 hardware loopback test (one-shot).
 *
 * Programs a compiled config into the card (classifier + flow windows),
 * which starts the TEST_RX flow generator; the SFP+ DAC loops it back
 * into the RX checker. Then it polls the per-flow stats snapshot and
 * prints rx / lost / dup / ooo / latency, confirming loss==0 at line
 * rate -- the Phase 3 equivalent of pw_sfp_test.
 *
 * One-shot on purpose: this environment SIGTERMs long-running device
 * processes (the packetwyrmd daemon), but short-lived vfio tools run
 * fine. Busy-polls via CSR reads (no sleep) to let frames accumulate.
 *
 *   sudo pw_phase3_loopback <bdf> <config.yaml> [iters] [burn]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include "packetwyrm/config.h"
#include "packetwyrm/flow_compiler.h"
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <bdf> <config.yaml> [iters] [burn]\n", argv[0]);
        return 2;
    }
    const char *bdf  = argv[1];
    const char *yaml = argv[2];
    int  iters = (argc >= 4) ? atoi(argv[3]) : 8;
    long burn  = (argc >= 5) ? atol(argv[4]) : 200000;

    struct pw_diag diag = {0};

    /* 1. parse + validate the YAML config */
    struct pw_config *cfg = pw_config_new();
    if (!cfg) { fprintf(stderr, "config alloc failed\n"); return 1; }
    if (pw_config_parse_file(yaml, cfg, &diag) != PW_OK) {
        fprintf(stderr, "parse failed: %s (%s)\n", diag.message, diag.path); return 1;
    }
    if (pw_config_validate(cfg, &diag) != PW_OK) {
        fprintf(stderr, "validate failed: %s (%s)\n", diag.message, diag.path); return 1;
    }

    /* 2. compile global flows -> per-card classifier + flow rows */
    struct pw_program *prog = pw_program_new();
    if (pw_flow_compile(cfg, prog, &diag) != PW_OK) {
        fprintf(stderr, "compile failed: %s (%s)\n", diag.message, diag.path); return 1;
    }
    if (prog->n_cards == 0) { fprintf(stderr, "no cards compiled\n"); return 1; }

    /* 3. open the card over VFIO */
    pw_vfio_bind(bdf);  /* best-effort */
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "backend open failed for %s\n", bdf); return 1;
    }
    const struct pw_card_backend_ops *o = be.ops;

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x version=0x%08x ports=%u flows=%u classifier=%u\n",
           bdf, info.device_id, info.version,
           info.num_local_ports, info.num_local_flows, info.num_classifier_entries);

    /* 4. program card 0: flow rows + commit, flow-id map, field+UDF classifier,
     *    hash table -- via the shared library path (same code the daemon uses),
     *    so every CSR write is error-checked in one place. */
    const struct pw_card_program *cp = &prog->per_card[0];
    if (pw_program_card_tables(o, be.ctx, cp) != PW_OK) {
        fprintf(stderr, "FATAL: card programming failed (BAR write error / card drop?)\n");
        return 1;
    }
    printf("programmed %zu flow rows, %zu flow-id map entries, "
           "%zu cmp/%zu udf/%zu rules, %zu hash entries (seed %08x); generator running\n",
           cp->n_flow_rows, cp->n_map_entries,
           cp->n_fc_cmps, cp->n_fc_udfs, cp->n_fc_rules,
           cp->n_hash_entries, cp->hash_seed);

    /* --- debug: write-path self-test on GLOBAL_CONTROL (0x100, RW) --- */
    if (o->write32 && o->read32) {
        uint32_t rb1 = 0, rb2 = 0, rb3 = 0;
        o->write32(be.ctx, 0x0100, 0xCAFEF00D); o->read32(be.ctx, 0x0100, &rb1);
        o->write32(be.ctx, 0x0100, 0x00000000); o->read32(be.ctx, 0x0100, &rb2);
        o->write32(be.ctx, 0x0100, 0x12345678); o->read32(be.ctx, 0x0100, &rb3);
        printf("write-path test 0x100: wrote CAFEF00D->%08x, 0->%08x, 12345678->%08x  (%s)\n",
               rb1, rb2, rb3,
               (rb1 == 0xCAFEF00D && rb2 == 0 && rb3 == 0x12345678) ? "WRITES OK" : "WRITES BROKEN");
        o->write32(be.ctx, 0x0100, 0x0);
    }

    /* --- debug: confirm programming landed + read status --- */
    {
        uint32_t gs = 0, es = 0;
        if (o->read32) { o->read32(be.ctx, 0x0104, &gs); o->read32(be.ctx, 0x0110, &es); }
        printf("GLOBAL_STATUS=0x%08x ERROR_STATUS=0x%08x\n", gs, es);
        /* Note: the classifier/flow windows are write-only over the BAR
         * (pw_csr_window has no read port), so they do not read back. */
    }

    uint32_t rx_lf = (prog->n_flow_meta > 0) ? prog->flow_meta[0].rx_local_flow_id : 0;
    uint32_t tx_lf = (prog->n_flow_meta > 0) ? prog->flow_meta[0].tx_local_flow_id : 0;
    printf("flow rx_local_flow_id=%u tx_local_flow_id=%u latency_valid=%d\n",
           rx_lf, tx_lf, prog->n_flow_meta ? prog->flow_meta[0].latency_valid : 0);

    /* 5. let traffic loop; snapshot + read per-flow stats each iteration.
     *    Busy-burn with CSR reads (each is a PCIe round-trip) -- no sleep. */
    for (int it = 0; it < iters; it++) {
        volatile uint32_t junk = 0;
        for (long k = 0; k < burn; k++) { uint32_t v; o->read32(be.ctx, 0x0, &v); junk += v; }

        if (o->stats_snapshot) o->stats_snapshot(be.ctx);
        struct pw_port_stats p0 = {0}, p1 = {0};
        if (o->port_stats_read) { o->port_stats_read(be.ctx, 0, &p0); o->port_stats_read(be.ctx, 1, &p1); }
        printf("[%d] port_drops: p0=%llu p1=%llu\n", it,
               (unsigned long long)p0.rx_bad_frame, (unsigned long long)p1.rx_bad_frame);
        printf("    p0 rx=%llu/%lluB tx=%llu/%lluB | p1 rx=%llu/%lluB tx=%llu/%lluB\n",
               (unsigned long long)p0.rx_frames, (unsigned long long)p0.rx_bytes,
               (unsigned long long)p0.tx_frames, (unsigned long long)p0.tx_bytes,
               (unsigned long long)p1.rx_frames, (unsigned long long)p1.rx_bytes,
               (unsigned long long)p1.tx_frames, (unsigned long long)p1.tx_bytes);
        printf("    p0 fcs_err=%llu link_up=%u down=%u blk_lock_loss=%u | "
               "p1 fcs_err=%llu link_up=%u down=%u blk_lock_loss=%u\n",
               (unsigned long long)p0.rx_fcs_error, p0.link_up_count,
               p0.link_down_count, p0.block_lock_loss,
               (unsigned long long)p1.rx_fcs_error, p1.link_up_count,
               p1.link_down_count, p1.block_lock_loss);
        for (size_t m = 0; m < prog->n_flow_meta; m++) {
            uint32_t lf = prog->flow_meta[m].rx_local_flow_id;
            struct pw_flow_stats rs = {0};
            if (o->flow_stats_read) o->flow_stats_read(be.ctx, lf, &rs);
            unsigned long long txf = (unsigned long long)rs.tx_frames;
            unsigned long long rxf = (unsigned long long)rs.rx_frames;
            long long trueloss = (long long)txf - (long long)rxf;
            unsigned long long jsamp = (rs.sample_count > 1) ? (rs.sample_count - 1) : 0;
            unsigned long long javg  = jsamp ? (unsigned long long)(rs.jitter_sum / jsamp) : 0;
            printf("    flow %u (lf=%u): tx=%llu rx=%llu loss(tx-rx)=%lld "
                   "lost_est=%llu dup=%llu ooo=%llu min_lat=%u max_lat=%u samples=%llu "
                   "jit_min=%u jit_max=%u jit_avg=%llu\n",
                   prog->flow_meta[m].global_flow_id, lf, txf, rxf, trueloss,
                   (unsigned long long)rs.lost_packets_estimated,
                   (unsigned long long)rs.duplicate_count,
                   (unsigned long long)rs.out_of_order_count,
                   rs.min_latency, rs.max_latency,
                   (unsigned long long)rs.sample_count,
                   rs.jitter_min, rs.jitter_max, javg);
        }
    }

    /* 6. latency histogram */
    if (o->flow_hist_read) {
        uint64_t buckets[64]; size_t nb = 0;
        if (o->stats_snapshot) o->stats_snapshot(be.ctx);
        if (o->flow_hist_read(be.ctx, rx_lf, buckets, 64, &nb) == PW_OK) {
            printf("latency histogram (%zu buckets):", nb);
            for (size_t i = 0; i < nb; i++) printf(" %llu", (unsigned long long)buckets[i]);
            printf("\n");
        }
    }

    pw_card_backend_close(&be);
    pw_program_free(prog);
    pw_config_free(cfg);
    return 0;
}
