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
#include "packetwyrm/backend.h"

/* Configure a card's pw_gpio_sync role (best-effort; needs a real BAR backend
 * with the gpio_sync CSR). period_log2 is clamped to >=5 in hardware. */
void pw_gpio_sync_master(const struct pw_card_backend *be, int out_pin, int period_log2);
void pw_gpio_sync_slave (const struct pw_card_backend *be, int in_pin);
void pw_gpio_sync_disable(const struct pw_card_backend *be);

/* Read the counter latched at the most recent shared edge (low-then-high read
 * for a coherent 64-bit value). Returns 0 if the backend can't read. */
uint64_t pw_gpio_sync_ts(const struct pw_card_backend *be);

/* Inter-card counter offset = tx_card_counter - rx_card_counter at the shared
 * edge, read back-to-back. Add to a raw cross-card latency
 * (rx_wire_ts_rx - tx_ts_tx) to recover the true one-way latency. */
int64_t pw_gpio_sync_offset(const struct pw_card_backend *tx,
                            const struct pw_card_backend *rx);

#endif /* PACKETWYRM_GPIO_SYNC_H */
