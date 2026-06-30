/* PacketWyrm J5 cross-card GPIO time-sync helpers (see gpio_sync.h). */

#include "packetwyrm/gpio_sync.h"
#include "packetwyrm/csr.h"

/* ctrl: [0]en [1]master [2]repeat [6:4]in_sel [10:8]out_sel [19:16]period_log2 */
static uint32_t mkctrl(int en, int master, int rep, int in_sel, int out_sel, int per) {
    return (uint32_t)((en & 1) | ((master & 1) << 1) | ((rep & 1) << 2)
                    | ((in_sel & 7) << 4) | ((out_sel & 7) << 8)
                    | ((per & 0xf) << 16));
}

static void wr(const struct pw_card_backend *be, uint32_t off, uint32_t v) {
    if (be && be->ops && be->ops->write32) be->ops->write32(be->ctx, off, v);
}

void pw_gpio_sync_master(const struct pw_card_backend *be, int out_pin, int period_log2) {
    wr(be, PWFPGA_REG_GPIO_SYNC_CTRL, mkctrl(1, 1, 0, 0, out_pin, period_log2));
}
void pw_gpio_sync_slave(const struct pw_card_backend *be, int in_pin) {
    wr(be, PWFPGA_REG_GPIO_SYNC_CTRL, mkctrl(1, 0, 0, in_pin, 1, 0));
}
void pw_gpio_sync_disable(const struct pw_card_backend *be) {
    wr(be, PWFPGA_REG_GPIO_SYNC_CTRL, 0);
}

uint64_t pw_gpio_sync_ts(const struct pw_card_backend *be) {
    if (!be || !be->ops || !be->ops->read32) return 0;
    uint32_t lo = 0, hi = 0;
    be->ops->read32(be->ctx, PWFPGA_REG_GPIO_SYNC_TS_LOW,  &lo);  /* low first latches high */
    be->ops->read32(be->ctx, PWFPGA_REG_GPIO_SYNC_TS_HIGH, &hi);
    return ((uint64_t)hi << 32) | lo;
}

int64_t pw_gpio_sync_offset(const struct pw_card_backend *tx,
                            const struct pw_card_backend *rx) {
    return (int64_t)(pw_gpio_sync_ts(tx) - pw_gpio_sync_ts(rx));
}

void pw_gpio_sync_write_correction(const struct pw_card_backend *be, int64_t corr) {
    uint64_t u = (uint64_t)corr;
    wr(be, PWFPGA_REG_LAT_CORRECTION_LO, (uint32_t)u);          /* low word  */
    wr(be, PWFPGA_REG_LAT_CORRECTION_HI, (uint32_t)(u >> 32));  /* high word */
}
