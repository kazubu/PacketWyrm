/* PacketWyrm Phase 3: J5 cross-card GPIO time-sync control / readout.
 *
 * Drives the pw_gpio_sync block via the CSR (REG_GPIO_SYNC_*): configure a card
 * as master (originate the pulse), slave (listen + latch), or repeater, and read
 * back the latched timestamp + edge sequence + raw pad inputs. Use one card as
 * master and the other(s) as slave, then `read` both: matching seq numbers across
 * cards give the inter-card counter offset at that shared edge.
 *
 *   sudo pw_gpio_sync <bdf> master  [period_log2=15] [out_pin=1]
 *   sudo pw_gpio_sync <bdf> slave   [in_pin=0]
 *   sudo pw_gpio_sync <bdf> repeater [in_pin=0] [out_pin=1]
 *   sudo pw_gpio_sync <bdf> read    [count=10] [interval_ms=200]
 *   sudo pw_gpio_sync <bdf> off
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static uint32_t mkctrl(int en, int master, int rep, int in_sel, int out_sel, int per_log2) {
    return (uint32_t)((en & 1) | ((master & 1) << 1) | ((rep & 1) << 2)
                    | ((in_sel & 7) << 4) | ((out_sel & 7) << 8)
                    | ((per_log2 & 0xf) << 16));
}

static void read_state(const struct pw_card_backend_ops *o, void *ctx,
                       uint32_t *seq, uint64_t *ts, uint32_t *gin, uint32_t *ctrl) {
    uint32_t lo = 0, hi = 0;
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_CTRL, ctrl);
    /* TS is latched low-then-high: read LOW first (snapshots HIGH) for a coherent 64-bit value. */
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_LOW,  &lo);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_TS_HIGH, &hi);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_SEQ,     seq);
    o->read32(ctx, PWFPGA_REG_GPIO_SYNC_STATUS,  gin);
    *ts = ((uint64_t)hi << 32) | lo;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
            "usage: %s <bdf> <master|slave|repeater|read|off> [args]\n"
            "  master  [period_log2=15] [out_pin=1]  (period_log2 range 0..15; <5 clamps to 5)\n"
            "  slave   [in_pin=0]\n"
            "  repeater [in_pin=0] [out_pin=1]\n"
            "  read    [count=10] [interval_ms=200]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    const char *cmd = argv[2];

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed for %s\n", bdf); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->read32 || !o->write32) { fprintf(stderr, "backend lacks read32/write32\n"); return 1; }

    struct pw_card_info info = {0};
    if (o->card_info) o->card_info(be.ctx, &info);
    printf("card %s: build=0x%08x\n", bdf, info.build_id);

    int rc = 0;
    if (!strcmp(cmd, "master")) {
        /* The RTL period field is 4 bits (ctrl[19:16]); default to the widest
         * period that actually fits. 16 would silently wrap to 0. */
        int per = (argc > 3) ? atoi(argv[3]) : 15;
        int out = (argc > 4) ? atoi(argv[4]) : 1;
        if (per < 0 || per > 15) {
            fprintf(stderr, "usage: period_log2 must be 0..15 (got %d); the RTL field is 4 bits\n", per);
            pw_card_backend_close(&be);
            return 2;
        }
        /* The RTL floor-clamps per_log2 to 5 (pw_gpio_sync.sv: per_eff); report
         * the EFFECTIVE period so the message matches the hardware. */
        int per_eff = (per < 5) ? 5 : per;
        uint32_t c = mkctrl(1, 1, 0, 0, out, per);
        o->write32(be.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, c);
        printf("MASTER: ctrl=0x%08x (en master out_sel=%d period_log2=%d effective=%d -> pulse every %d cyc)\n",
               c, out, per, per_eff, 1 << per_eff);
    } else if (!strcmp(cmd, "slave")) {
        int in = (argc > 3) ? atoi(argv[3]) : 0;
        uint32_t c = mkctrl(1, 0, 0, in, 1, 0);
        o->write32(be.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, c);
        printf("SLAVE: ctrl=0x%08x (en in_sel=%d, listen-only hi-Z)\n", c, in);
    } else if (!strcmp(cmd, "repeater")) {
        int in  = (argc > 3) ? atoi(argv[3]) : 0;
        int out = (argc > 4) ? atoi(argv[4]) : 1;
        uint32_t c = mkctrl(1, 0, 1, in, out, 0);
        o->write32(be.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, c);
        printf("REPEATER: ctrl=0x%08x (en repeat in_sel=%d out_sel=%d)\n", c, in, out);
    } else if (!strcmp(cmd, "off")) {
        o->write32(be.ctx, PWFPGA_REG_GPIO_SYNC_CTRL, 0);
        printf("OFF: ctrl=0\n");
    } else if (!strcmp(cmd, "read")) {
        int n  = (argc > 3) ? atoi(argv[3]) : 10;
        int ms = (argc > 4) ? atoi(argv[4]) : 200;
        struct timespec ts_req = { ms / 1000, (long)(ms % 1000) * 1000000L };
        uint32_t prev_seq = 0; int first = 1;
        for (int i = 0; i < n; i++) {
            uint32_t seq = 0, gin = 0, ctrl = 0; uint64_t ts = 0;
            read_state(o, be.ctx, &seq, &ts, &gin, &ctrl);
            long dseq = first ? 0 : (long)(seq - prev_seq);
            printf("[%2d] seq=%-10u (+%ld) ts=%llu gpio_in=0x%02x ctrl=0x%08x\n",
                   i, seq, dseq, (unsigned long long)ts, gin & 0x3f, ctrl);
            prev_seq = seq; first = 0;
            if (i < n - 1) nanosleep(&ts_req, NULL);
        }
    } else {
        fprintf(stderr, "unknown command '%s'\n", cmd); rc = 2;
    }

    pw_card_backend_close(&be);
    return rc;
}
