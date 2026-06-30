/* PacketWyrm Phase 3 HW soak: run a config continuously and self-check at a
 * fixed wall-clock interval, flagging any problem.
 *
 * Owns the vfio device for the whole run (it cannot be shared), so the periodic
 * health sampling lives HERE -- it programs the config (e.g. max-scale 32-flow
 * deepest-encap), keeps the generator running, and every <interval> seconds
 * snapshots port + per-flow stats and prints a timestamped health line. It
 * flags a PROBLEM on: TX not advancing (wedge), RX not advancing while TX is,
 * any growth in lost_est / ooo / dup, any new FCS error, a link-down or
 * block-lock-loss, or an implausible latency. Deltas are measured between
 * samples, so a one-time startup transient never trips it. Runs for <hours>
 * then disables the flows and prints a summary. SIGTERM/SIGINT -> clean stop.
 *
 *   sudo pw_soak <bdf> <config.yaml> [hours] [interval_sec]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>

#include "packetwyrm/config.h"
#include "packetwyrm/flow_compiler.h"
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

#define MAXF 64

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static const char *now_str(void) {
    static char b[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(b, sizeof b, "%Y-%m-%d %H:%M:%S", &tm);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <bdf> <config.yaml> [hours] [interval_sec]\n", argv[0]);
        return 2;
    }
    const char *bdf  = argv[1];
    const char *yaml = argv[2];
    double hours     = (argc >= 4) ? atof(argv[3]) : 8.0;
    long   interval  = (argc >= 5) ? atol(argv[4]) : 1800;
    long   total_s   = (long)(hours * 3600.0 + 0.5);
    int    loops     = (interval > 0) ? (int)(total_s / interval) : 0;

    struct pw_diag diag = {0};
    struct pw_config *cfg = pw_config_new();
    if (!cfg) { fprintf(stderr, "config alloc failed\n"); return 1; }
    if (pw_config_parse_file(yaml, cfg, &diag) != PW_OK) {
        fprintf(stderr, "parse failed: %s (%s)\n", diag.message, diag.path); return 1; }
    if (pw_config_validate(cfg, &diag) != PW_OK) {
        fprintf(stderr, "validate failed: %s (%s)\n", diag.message, diag.path); return 1; }

    struct pw_program *prog = pw_program_new();
    if (pw_flow_compile(cfg, prog, &diag) != PW_OK) {
        fprintf(stderr, "compile failed: %s (%s)\n", diag.message, diag.path); return 1; }
    if (prog->n_cards == 0) { fprintf(stderr, "no cards compiled\n"); return 1; }

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "backend open failed for %s\n", bdf); return 1; }
    const struct pw_card_backend_ops *o = be.ops;

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);

    const struct pw_card_program *cp = &prog->per_card[0];
    if (pw_program_card_tables(o, be.ctx, cp) != PW_OK) {
        fprintf(stderr, "FATAL: card programming failed\n"); return 1; }

    /* collect the per-flow checker slots */
    uint32_t lf[MAXF]; uint32_t gf[MAXF]; size_t nf = 0;
    for (size_t m = 0; m < prog->n_flow_meta && nf < MAXF; m++) {
        lf[nf] = prog->flow_meta[m].rx_local_flow_id;
        gf[nf] = prog->flow_meta[m].global_flow_id;
        nf++;
    }

    signal(SIGTERM, on_sig);
    signal(SIGINT,  on_sig);

    printf("=== pw_soak START %s ===\n", now_str());
    printf("card build=0x%08x  config=%s  flows=%zu  run=%.2fh  interval=%lds  checks=%d\n",
           info.build_id, yaml, nf, hours, interval, loops);
    fflush(stdout);

    /* baseline */
    struct pw_port_stats P0 = {0}, P1 = {0};
    uint64_t plost[MAXF] = {0}, pooo[MAXF] = {0}, pdup[MAXF] = {0};
    uint64_t pp0tx = 0, pp1rx = 0, pp0fcs = 0, pp1fcs = 0;
    uint32_t pp0ld = 0, pp1ld = 0, pp0bl = 0, pp1bl = 0;
    if (o->stats_snapshot) o->stats_snapshot(be.ctx);
    if (o->port_stats_read) { o->port_stats_read(be.ctx, 0, &P0); o->port_stats_read(be.ctx, 1, &P1); }
    pp0tx = P0.tx_frames; pp1rx = P1.rx_frames; pp0fcs = P0.rx_fcs_error; pp1fcs = P1.rx_fcs_error;
    pp0ld = P0.link_down_count; pp1ld = P1.link_down_count; pp0bl = P0.block_lock_loss; pp1bl = P1.block_lock_loss;
    for (size_t i = 0; i < nf; i++) {
        struct pw_flow_stats rs = {0};
        if (o->flow_stats_read) o->flow_stats_read(be.ctx, lf[i], &rs);
        plost[i] = rs.lost_packets_estimated; pooo[i] = rs.out_of_order_count; pdup[i] = rs.duplicate_count;
    }

    time_t t0 = time(NULL);
    int problems = 0, checks = 0;

    for (int c = 0; c < loops && !g_stop; c++) {
        long slept = 0;
        while (slept < interval && !g_stop) { sleep(5); slept += 5; }
        if (g_stop) break;

        if (o->stats_snapshot) o->stats_snapshot(be.ctx);
        struct pw_port_stats p0 = {0}, p1 = {0};
        if (o->port_stats_read) { o->port_stats_read(be.ctx, 0, &p0); o->port_stats_read(be.ctx, 1, &p1); }

        uint64_t d_tx0 = p0.tx_frames - pp0tx;
        uint64_t d_rx1 = p1.rx_frames - pp1rx;
        uint64_t d_fcs = (p0.rx_fcs_error - pp0fcs) + (p1.rx_fcs_error - pp1fcs);
        uint32_t d_ld  = (p0.link_down_count - pp0ld) + (p1.link_down_count - pp1ld);
        uint32_t d_bl  = (p0.block_lock_loss - pp0bl) + (p1.block_lock_loss - pp1bl);

        uint64_t tot_dlost = 0, tot_dooo = 0, tot_ddup = 0;
        uint32_t worst_lat = 0; int badflows = 0; int first_bad = -1;
        for (size_t i = 0; i < nf; i++) {
            struct pw_flow_stats rs = {0};
            if (o->flow_stats_read) o->flow_stats_read(be.ctx, lf[i], &rs);
            uint64_t dl = rs.lost_packets_estimated - plost[i];
            uint64_t doo = rs.out_of_order_count - pooo[i];
            uint64_t dd = rs.duplicate_count - pdup[i];
            tot_dlost += dl; tot_dooo += doo; tot_ddup += dd;
            if (rs.max_latency > worst_lat) worst_lat = rs.max_latency;
            if (dl || doo || dd) { badflows++; if (first_bad < 0) first_bad = (int)gf[i]; }
            plost[i] = rs.lost_packets_estimated; pooo[i] = rs.out_of_order_count; pdup[i] = rs.duplicate_count;
        }

        int prob = 0;
        char why[256]; why[0] = 0;
        if (d_tx0 == 0)                 { prob = 1; strcat(why, "TX-WEDGE "); }
        if (d_tx0 > 0 && d_rx1 == 0)    { prob = 1; strcat(why, "RX-WEDGE "); }
        if (tot_dlost > 0)              { prob = 1; strcat(why, "LOSS "); }
        if (tot_dooo > 0)               { prob = 1; strcat(why, "OOO "); }
        if (tot_ddup > 0)               { prob = 1; strcat(why, "DUP "); }
        if (d_fcs > 0)                  { prob = 1; strcat(why, "FCS "); }
        if (d_ld > 0)                   { prob = 1; strcat(why, "LINK-DOWN "); }
        if (d_bl > 0)                   { prob = 1; strcat(why, "BLK-LOCK-LOSS "); }
        if (worst_lat > 1000)           { prob = 1; strcat(why, "LATENCY "); }

        long elapsed_m = (long)((time(NULL) - t0) / 60);
        checks++;
        printf("[+%4ldm %s] check %d/%d: dTX0=%llu dRX1=%llu maxlat=%u fcs+=%llu linkdn+=%u blkloss+=%u "
               "| flows: dlost=%llu dooo=%llu ddup=%llu bad=%d%s%d : %s\n",
               elapsed_m, now_str(), checks, loops,
               (unsigned long long)d_tx0, (unsigned long long)d_rx1, worst_lat,
               (unsigned long long)d_fcs, d_ld, d_bl,
               (unsigned long long)tot_dlost, (unsigned long long)tot_dooo,
               (unsigned long long)tot_ddup, badflows,
               first_bad >= 0 ? " firstbadflow=" : "", first_bad >= 0 ? first_bad : 0,
               prob ? "PROBLEM " : "OK");
        if (prob) printf("    >>> PROBLEM at %s: %s\n", now_str(), why);
        fflush(stdout);
        if (prob) problems++;

        pp0tx = p0.tx_frames; pp1rx = p1.rx_frames; pp0fcs = p0.rx_fcs_error; pp1fcs = p1.rx_fcs_error;
        pp0ld = p0.link_down_count; pp1ld = p1.link_down_count; pp0bl = p0.block_lock_loss; pp1bl = p1.block_lock_loss;
    }

    /* disable all flows on the way out */
    for (size_t m = 0; m < cp->n_flow_rows; m++) {
        struct pwfpga_flow_config zf = {0};
        if (o->flow_write) o->flow_write(be.ctx, (uint32_t)m, &zf);
    }
    if (o->flow_commit) o->flow_commit(be.ctx);

    printf("=== pw_soak DONE %s : %d checks, %d problem-interval(s) %s===\n",
           now_str(), checks, problems, g_stop ? "(stopped early) " : "");
    printf("RESULT: %s\n", problems == 0 ? "PASS (no problems across the soak)" : "FAIL (problems detected)");
    fflush(stdout);

    pw_card_backend_close(&be);
    pw_program_free(prog);
    pw_config_free(cfg);
    return problems == 0 ? 0 : 1;
}
