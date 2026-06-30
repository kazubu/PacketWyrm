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

uint32_t pw_gpio_sync_seq(const struct pw_card_backend *be) {
    if (!be || !be->ops || !be->ops->read32) return 0;
    uint32_t s = 0;
    be->ops->read32(be->ctx, PWFPGA_REG_GPIO_SYNC_SEQ, &s);
    return s;
}

int64_t pw_gpio_sync_offset(const struct pw_card_backend *tx,
                            const struct pw_card_backend *rx) {
    return (int64_t)(pw_gpio_sync_ts(tx) - pw_gpio_sync_ts(rx));
}

bool pw_gpio_sync_offset_coherent(const struct pw_card_backend *tx,
                                  const struct pw_card_backend *rx,
                                  int64_t *offset) {
    if (!offset) return false;
    if (!tx || !tx->ops || !tx->ops->read32) return false;
    if (!rx || !rx->ops || !rx->ops->read32) return false;
    /* Per-card 64-bit ts read is atomic (reading TS_LOW latches TS_HIGH), so the
     * only cross-card hazard is a sync edge landing between the tx and rx ts
     * reads. Bracket the whole sample with both cards' seq and retry if either
     * advanced -- a stable window means both ts come from the same latest edge. */
    for (int tries = 0; tries < 8; tries++) {
        uint32_t s_tx_a = 0, s_rx_a = 0, s_tx_b = 0, s_rx_b = 0;
        tx->ops->read32(tx->ctx, PWFPGA_REG_GPIO_SYNC_SEQ, &s_tx_a);
        rx->ops->read32(rx->ctx, PWFPGA_REG_GPIO_SYNC_SEQ, &s_rx_a);
        uint64_t ts_tx = pw_gpio_sync_ts(tx);
        uint64_t ts_rx = pw_gpio_sync_ts(rx);
        tx->ops->read32(tx->ctx, PWFPGA_REG_GPIO_SYNC_SEQ, &s_tx_b);
        rx->ops->read32(rx->ctx, PWFPGA_REG_GPIO_SYNC_SEQ, &s_rx_b);
        /* require a real edge seen (seq != 0) AND no edge during the window */
        if (s_tx_a != 0 && s_rx_a != 0 && s_tx_a == s_tx_b && s_rx_a == s_rx_b) {
            *offset = (int64_t)(ts_tx - ts_rx);
            return true;
        }
    }
    return false;
}

void pw_gpio_sync_write_correction(const struct pw_card_backend *be,
                                   unsigned slot, int64_t corr) {
    uint64_t u = (uint64_t)corr;
    uint32_t base = (uint32_t)PWFPGA_REG_LAT_CORRECTION_BASE + slot * 8u;
    wr(be, base + 0u, (uint32_t)u);          /* LO stages the shadow      */
    wr(be, base + 4u, (uint32_t)(u >> 32));  /* HI commits {HI,shadow}    */
}
