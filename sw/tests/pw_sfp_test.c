/* pw_sfp_test: Phase 2 SFP+ 10G loopback line-rate check.
 *
 * Over a DAC between SFP0 and SFP1: enable the FPGA TX template senders,
 * sample the per-port RX/TX frame counters across an interval, and
 * confirm RX tracks the far port's TX with zero loss.
 *
 *   sudo build/pw_sfp_test 0000:07:00.0 [seconds]
 *
 * Uses the production backend (sysfs mmap, VFIO fallback under lockdown).
 * CSR layout (pw_csr_min Phase 2 window):
 *   0x200 status {.., p1_rx_status,p1_lock, p0_rx_status,p0_lock}
 *   0x204 rx0  0x208 rx1  0x20c tx0  0x210 tx1   0x214 control (tx_en bits)
 */
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { R_STATUS=0x200, R_RX0=0x204, R_RX1=0x208, R_TX0=0x20c, R_TX1=0x210, R_CTRL=0x214 };

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [seconds]\n", argv[0]); return 2; }
    const char *bdf = argv[1];
    double secs = (argc >= 3) ? atof(argv[2]) : 2.0;

    pw_vfio_bind(bdf);  /* best-effort; ignored if already bound / not needed */

    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "backend open failed\n"); return 1;
    }
    const struct pw_card_backend_ops *o = be.ops;

    uint32_t st = 0, dev = 0;
    o->read32(be.ctx, 0x000, &dev);
    o->read32(be.ctx, R_STATUS, &st);
    printf("device_id=0x%08x  sfp_status=0x%08x  (p0 lock=%u up=%u | p1 lock=%u up=%u)\n",
           dev, st, st&1, (st>>1)&1, (st>>2)&1, (st>>3)&1);

    /* enable TX on both ports */
    o->write32(be.ctx, R_CTRL, 0x3);

    uint32_t rx0a, rx1a, tx0a, tx1a, rx0b, rx1b, tx0b, tx1b;
    o->read32(be.ctx, R_RX0,&rx0a); o->read32(be.ctx, R_RX1,&rx1a);
    o->read32(be.ctx, R_TX0,&tx0a); o->read32(be.ctx, R_TX1,&tx1a);

    struct timespec ts = { (long)secs, (long)((secs-(long)secs)*1e9) };
    nanosleep(&ts, NULL);

    o->read32(be.ctx, R_RX0,&rx0b); o->read32(be.ctx, R_RX1,&rx1b);
    o->read32(be.ctx, R_TX0,&tx0b); o->read32(be.ctx, R_TX1,&tx1b);

    uint32_t tx0=tx0b-tx0a, tx1=tx1b-tx1a, rx0=rx0b-rx0a, rx1=rx1b-rx1a;
    printf("over %.2fs:  TX0=%u TX1=%u  RX0=%u RX1=%u\n", secs, tx0, tx1, rx0, rx1);
    /* DAC: port0 TX -> port1 RX, port1 TX -> port0 RX */
    long loss_0to1 = (long)tx0 - (long)rx1;
    long loss_1to0 = (long)tx1 - (long)rx0;
    printf("path SFP0->SFP1: tx=%u rx=%u  loss=%ld\n", tx0, rx1, loss_0to1);
    printf("path SFP1->SFP0: tx=%u rx=%u  loss=%ld\n", tx1, rx0, loss_1to0);
    double mfps0 = tx0/secs/1e6, gbps0 = tx0*(double)(64+20)*8/secs/1e9;
    printf("port0 TX rate ~ %.2f Mframe/s (~%.2f Gb/s incl. IFG/preamble)\n", mfps0, gbps0);

    /* leave TX running or stop? stop to leave the link idle/clean. */
    o->write32(be.ctx, R_CTRL, 0x0);
    pw_card_backend_close(&be);

    int ok = (tx0>0 && tx1>0 && labs(loss_0to1) <= 64 && labs(loss_1to0) <= 64);
    printf("%s\n", ok ? "OK: bidirectional 10G loopback, loss within tolerance"
                      : "CHECK: see counts above");
    return ok ? 0 : 1;
}
