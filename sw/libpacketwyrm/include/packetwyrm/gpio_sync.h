/* PacketWyrm J5 cross-card GPIO time-sync helpers (pw_gpio_sync block).
 *
 * Shared by the daemon (cross-card latency correction) and the standalone
 * tools. A master card drives a periodic pulse out a J5 pin; every card latches
 * its own free-running counter at the shared edge. The difference of two cards'
 * latched counters is the inter-card counter offset at that instant, used to
 * correct a cross-card latency (rx_wire_ts on one card vs tx_ts on another).
 */
#ifndef PACKETWYRM_GPIO_SYNC_H
#define PACKETWYRM_GPIO_SYNC_H

#include <stdint.h>
#include <stdbool.h>
#include "packetwyrm/backend.h"

/* Configure a card's pw_gpio_sync role (best-effort; needs a real BAR backend
 * with the gpio_sync CSR). period_log2 is clamped to >=5 in hardware. */
void pw_gpio_sync_master(const struct pw_card_backend *be, int out_pin, int period_log2);
void pw_gpio_sync_slave (const struct pw_card_backend *be, int in_pin);
void pw_gpio_sync_disable(const struct pw_card_backend *be);

/* Read the counter latched at the most recent shared edge (low-then-high read
 * for a coherent 64-bit value). Returns 0 if the backend can't read. */
uint64_t pw_gpio_sync_ts(const struct pw_card_backend *be);

/* Read the edge sequence counter (REG_GPIO_SYNC_SEQ). Non-zero means the card
 * has latched at least one shared sync edge, so its pw_gpio_sync_ts (and an
 * offset computed from it) is meaningful rather than the post-reset 0. Returns
 * 0 if the backend can't read. */
uint32_t pw_gpio_sync_seq(const struct pw_card_backend *be);

/* Inter-card counter offset = tx_card_counter - rx_card_counter at the shared
 * edge, read back-to-back. Add to a raw cross-card latency
 * (rx_wire_ts_rx - tx_ts_tx) to recover the true one-way latency. */
int64_t pw_gpio_sync_offset(const struct pw_card_backend *tx,
                            const struct pw_card_backend *rx);

/* Edge-coherent inter-card offset. pw_gpio_sync_offset() reads the two cards'
 * latched timestamps without checking they came from the SAME shared edge -- if
 * a sync edge lands between the two reads, the rx card latches the next edge and
 * the offset is wrong by one pulse period (~210us @period_log2=15). This variant
 * brackets the whole two-card read with seq re-reads and rejects/retries any
 * sample where an edge landed mid-read, so the returned offset is always a
 * same-edge pair. On success writes *offset = tx_cnt - rx_cnt and returns true;
 * returns false if no clean sample after a few tries (edges too fast, or the
 * sync isn't running). The daemon servo uses this; a stale/incoherent read must
 * NOT be written to lat_correction (it would corrupt latency for ~one tick). */
bool pw_gpio_sync_offset_coherent(const struct pw_card_backend *tx,
                                  const struct pw_card_backend *rx,
                                  int64_t *offset);

/* Write the signed 64-bit cross-card latency correction to a card's
 * lat_correction CSR (lo then hi words). The RX checker computes
 * lat = (rx_wire_ts + correction) - tx_ts, so writing the inter-card offset
 * (= pw_gpio_sync_offset(tx, rx)) makes it accumulate the TRUE one-way latency
 * per sample. The daemon servo re-writes this ~10x/s; 0 = same-card (no
 * correction). Best-effort (needs a real BAR backend with write32). */
void pw_gpio_sync_write_correction(const struct pw_card_backend *be, int64_t corr);

#endif /* PACKETWYRM_GPIO_SYNC_H */
