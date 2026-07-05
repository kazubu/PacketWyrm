/* In-system SPI flash access over the pw_spi_flash CSR engine.
 *
 * Drives the board config flash (MT25QU256) through the FPGA's STARTUPE3
 * primitive while the bitstream keeps running -- no JTAG, no FPGA
 * reconfiguration, PCIe stays up. Shared by the standalone pw_flash tool
 * and the packetwyrmd `flash.write` RPC.
 *
 * CONCURRENCY: these calls are NOT internally synchronized. Each is a multi-
 * transaction sequence (WREN / erase / program / read-back) on one shared SPI
 * CSR engine; two overlapping calls on the same card would interleave commands
 * and corrupt the flash. The caller must serialize SPI-flash access per card.
 * The daemon does: all flash.* RPCs run on its single-threaded control loop and
 * the card worker thread never touches the SPI engine. (Cross-PROCESS use -- the
 * pw_flash tool while the daemon runs -- is an operator hazard no in-process
 * lock can prevent; the daemon is meant to be the sole controller.) */
#ifndef PACKETWYRM_SPI_FLASH_H
#define PACKETWYRM_SPI_FLASH_H

#include <stdint.h>
#include <stddef.h>
#include "packetwyrm/backend.h"

/* Read the 3-byte JEDEC ID (Micron MT25QU256 = 0x20 0xBB 0x19). Issues a
 * warm-up transaction first to absorb the STARTUPE3 post-config masking
 * of the first SPI clock edges. */
pw_status pw_flash_read_id(const struct pw_card_backend_ops *o, void *ctx,
                           uint8_t id[3]);

/* Erase the 64 KB sectors covering [offset, offset+len), page-program
 * `data`, then read back and compare. On success returns PW_OK and (if
 * non-NULL) *mismatch_out = number of mismatched bytes (0 == verified).
 * Addresses are 3-byte (must stay within 16 MB). */
pw_status pw_flash_program(const struct pw_card_backend_ops *o, void *ctx,
                           uint32_t offset, const uint8_t *data, size_t len,
                           uint64_t *mismatch_out);

#endif
