/* In-system SPI flash protocol over the pw_spi_flash CSR byte engine.
 * See packetwyrm/spi_flash.h. Raw x1 SPI mode-0; the flash command
 * sequences (WREN/erase/program/read/RDSR) are composed here and
 * verified by read-back. */
#include "packetwyrm/spi_flash.h"
#include "packetwyrm/csr.h"
#include <string.h>

#define SECTOR   0x10000u   /* 64 KB sector erase (0xD8) */
#define PAGE     256u
#define FLASH_SZ 0x1000000u /* 16 MB: the 3-byte (24-bit) address space */

/* One SPI transaction: shift `n` TX bytes, capture `n` RX bytes. */
static pw_status spi_txn(const struct pw_card_backend_ops *o, void *ctx,
                         const uint8_t *tx, int n, uint8_t *rx, int cs_hold) {
    if (n > (int)PWFPGA_SPI_BUF_BYTES) return PW_E_INVAL;
    for (int i = 0; i < n; i += 4) {
        uint32_t d = 0;
        for (int k = 0; k < 4 && i + k < n; k++) d |= (uint32_t)tx[i + k] << (k * 8);
        pw_status s = o->write32(ctx, PWFPGA_SPI_TXBUF + (uint32_t)i, d);
        if (s != PW_OK) return s;
    }
    pw_status s = o->write32(ctx, PWFPGA_REG_SPI_LEN, (uint32_t)n);
    if (s != PW_OK) return s;
    s = o->write32(ctx, PWFPGA_REG_SPI_CTRL,
                   PWFPGA_SPI_CTRL_GO | (cs_hold ? PWFPGA_SPI_CTRL_CS_HOLD : 0));
    if (s != PW_OK) return s;
    for (int spin = 0; spin < 2000000; spin++) {
        uint32_t st = 0;
        s = o->read32(ctx, PWFPGA_REG_SPI_CTRL, &st);
        if (s != PW_OK) return s;       /* a failed status read != "not busy" */
        if (!(st & PWFPGA_SPI_STATUS_BUSY)) {
            if (rx) {
                for (int i = 0; i < n; i += 4) {
                    uint32_t d = 0;
                    s = o->read32(ctx, PWFPGA_SPI_RXBUF + (uint32_t)i, &d);
                    if (s != PW_OK) return s;
                    for (int k = 0; k < 4 && i + k < n; k++) rx[i + k] = (d >> (k * 8)) & 0xFF;
                }
            }
            return PW_OK;
        }
    }
    return PW_E_IO;
}

/* STARTUPE3 masks the first few USRCCLK edges after configuration, so the
 * very first SPI transaction loses bits; burn a throwaway RDSR. */
static pw_status warmup(const struct pw_card_backend_ops *o, void *ctx) {
    uint8_t t[2] = {0x05, 0x00};   /* throwaway RDSR; data is junk by design, but
                                      a CSR-op failure here is a real fault. */
    return spi_txn(o, ctx, t, 2, NULL, 0);
}

static pw_status wren(const struct pw_card_backend_ops *o, void *ctx) {
    uint8_t t = 0x06; return spi_txn(o, ctx, &t, 1, NULL, 0);
}
static int wip(const struct pw_card_backend_ops *o, void *ctx) {
    uint8_t t[2] = {0x05, 0x00}, r[2];
    if (spi_txn(o, ctx, t, 2, r, 0) != PW_OK) return -1;
    return r[1] & 1;
}
static pw_status wait_idle(const struct pw_card_backend_ops *o, void *ctx) {
    for (int i = 0; i < 4000000; i++) {
        int w = wip(o, ctx);
        if (w == 0) return PW_OK;
        if (w < 0)  return PW_E_IO;
    }
    return PW_E_IO;
}
static void addr3(uint8_t *b, uint32_t a) { b[0]=(a>>16)&0xFF; b[1]=(a>>8)&0xFF; b[2]=a&0xFF; }

static pw_status sector_erase(const struct pw_card_backend_ops *o, void *ctx, uint32_t a) {
    uint8_t t[4] = {0xD8}; addr3(&t[1], a);
    pw_status s = wren(o, ctx);
    if (s != PW_OK) return s;
    s = spi_txn(o, ctx, t, 4, NULL, 0);
    if (s != PW_OK) return s;
    return wait_idle(o, ctx);
}
static pw_status page_program(const struct pw_card_backend_ops *o, void *ctx,
                              uint32_t a, const uint8_t *data, int len) {
    uint8_t t[4 + PAGE]; t[0] = 0x02; addr3(&t[1], a); memcpy(&t[4], data, (size_t)len);
    pw_status s = wren(o, ctx);
    if (s != PW_OK) return s;
    s = spi_txn(o, ctx, t, 4 + len, NULL, 0);
    if (s != PW_OK) return s;
    return wait_idle(o, ctx);
}
static pw_status flash_read(const struct pw_card_backend_ops *o, void *ctx,
                            uint32_t a, uint8_t *buf, int len) {
    uint8_t t[4 + 256] = {0}, r[4 + 256];
    t[0] = 0x03; addr3(&t[1], a);
    pw_status s = spi_txn(o, ctx, t, 4 + len, r, 0);
    if (s != PW_OK) return s;
    memcpy(buf, &r[4], (size_t)len);
    return PW_OK;
}

pw_status pw_flash_read_id(const struct pw_card_backend_ops *o, void *ctx, uint8_t id[3]) {
    if (!o || !o->write32 || !o->read32 || !id) return PW_E_INVAL;
    pw_status s = warmup(o, ctx);
    if (s != PW_OK) return s;
    uint8_t t[4] = {0x9F, 0, 0, 0}, r[4];
    s = spi_txn(o, ctx, t, 4, r, 0);
    if (s != PW_OK) return s;
    id[0] = r[1]; id[1] = r[2]; id[2] = r[3];
    return PW_OK;
}

pw_status pw_flash_program(const struct pw_card_backend_ops *o, void *ctx,
                           uint32_t offset, const uint8_t *data, size_t len,
                           uint64_t *mismatch_out) {
    if (!o || !o->write32 || !o->read32 || !data || len == 0) return PW_E_INVAL;
    /* The flash uses 3-byte (24-bit) addressing: everything must stay within the
     * 16 MB space or addr3() would silently drop high bits and erase/program the
     * WRONG region. Validate in 64-bit so offset+len can't wrap. */
    if (offset >= FLASH_SZ || len > FLASH_SZ ||
        (uint64_t)offset + (uint64_t)len > FLASH_SZ)
        return PW_E_OUT_OF_RANGE;
    uint32_t end = offset + (uint32_t)len;   /* <= FLASH_SZ, no wrap (validated) */
    pw_status ws = warmup(o, ctx);
    if (ws != PW_OK) return ws;
    for (uint32_t a = offset & ~(SECTOR - 1); a < end; a += SECTOR) {
        pw_status s = sector_erase(o, ctx, a);
        if (s != PW_OK) return s;
    }
    /* Program in chunks that never cross a physical page boundary: a page-program
     * command that overruns the 256-B page wraps to the page START on most SPI
     * NOR, corrupting the beginning of the page. When offset is not page-aligned
     * the first chunk is only the bytes left in that page. */
    for (size_t p = 0; p < len; ) {
        uint32_t a = offset + (uint32_t)p;
        size_t page_left = PAGE - (a & (PAGE - 1));   /* bytes to end of this page */
        size_t n = len - p;
        if (n > page_left) n = page_left;
        pw_status s = page_program(o, ctx, a, &data[p], (int)n);
        if (s != PW_OK) return s;
        p += n;
    }
    uint64_t mism = 0;
    for (size_t p = 0; p < len; p += 256) {
        int n = (len - p < 256) ? (int)(len - p) : 256;
        uint8_t rb[256];
        pw_status s = flash_read(o, ctx, offset + (uint32_t)p, rb, n);
        if (s != PW_OK) return s;
        for (int i = 0; i < n; i++) if (rb[i] != data[p + i]) mism++;
    }
    if (mismatch_out) *mismatch_out = mism;
    return PW_OK;
}
