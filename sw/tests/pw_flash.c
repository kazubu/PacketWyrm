/* pw_flash -- in-system SPI flash write/verify over the PCIe/CSR path.
 *
 * Drives the pw_spi_flash CSR engine (no JTAG, no FPGA reconfiguration:
 * the running bitstream and the PCIe endpoint stay up) to erase, program
 * and read-back-verify the board's config flash. Deliberately minimal --
 * a raw x1 SPI byte engine with the flash command protocol here in
 * software, and verify-by-read-back. A bad write is simply re-run; JTAG
 * is the last-resort recovery.
 *
 *   sudo pw_flash <bdf> <file> [offset_hex]
 *
 * Default offset is 0x00E00000 (14 MB) -- past the ~12 MB boot image but
 * still inside 3-byte (16 MB) addressing -- so development writes never
 * touch the bootable image. Use offset 0 to (re)write the boot image.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

#define SECTOR        0x10000u          /* 64 KB sector erase (0xD8) */
#define PAGE          256u
#define DEF_OFFSET    0x00E00000u

static const struct pw_card_backend_ops *O;
static void *CTX;

/* One SPI transaction: shift `n` TX bytes, capture `n` RX bytes. */
static int spi_txn(const uint8_t *tx, int n, uint8_t *rx, int cs_hold) {
    if (n > (int)PWFPGA_SPI_BUF_BYTES) return -1;
    for (int i = 0; i < n; i += 4) {
        uint32_t d = 0;
        for (int k = 0; k < 4 && i + k < n; k++) d |= (uint32_t)tx[i + k] << (k * 8);
        if (O->write32(CTX, PWFPGA_SPI_TXBUF + (uint32_t)i, d) != PW_OK) return -1;
    }
    O->write32(CTX, PWFPGA_REG_SPI_LEN, (uint32_t)n);
    O->write32(CTX, PWFPGA_REG_SPI_CTRL,
               PWFPGA_SPI_CTRL_GO | (cs_hold ? PWFPGA_SPI_CTRL_CS_HOLD : 0));
    /* poll busy */
    for (int spin = 0; spin < 1000000; spin++) {
        uint32_t st = 0;
        O->read32(CTX, PWFPGA_REG_SPI_CTRL, &st);
        if (!(st & PWFPGA_SPI_STATUS_BUSY)) goto done;
    }
    return -2;  /* timeout */
done:
    if (rx) {
        for (int i = 0; i < n; i += 4) {
            uint32_t d = 0;
            O->read32(CTX, PWFPGA_SPI_RXBUF + (uint32_t)i, &d);
            for (int k = 0; k < 4 && i + k < n; k++) rx[i + k] = (d >> (k * 8)) & 0xFF;
        }
    }
    return 0;
}

static void wren(void)  { uint8_t t = 0x06; spi_txn(&t, 1, NULL, 0); }

static int wip(void) {
    uint8_t t[2] = {0x05, 0x00}, r[2];
    if (spi_txn(t, 2, r, 0)) return -1;
    return r[1] & 1;
}
static int wait_idle(void) {
    for (int i = 0; i < 2000000; i++) { int w = wip(); if (w == 0) return 0; if (w < 0) return -1; }
    return -2;
}

static void addr3(uint8_t *b, uint32_t a) { b[0]=(a>>16)&0xFF; b[1]=(a>>8)&0xFF; b[2]=a&0xFF; }

static int sector_erase(uint32_t a) {
    uint8_t t[4] = {0xD8}; addr3(&t[1], a);
    wren(); if (spi_txn(t, 4, NULL, 0)) return -1; return wait_idle();
}
static int page_program(uint32_t a, const uint8_t *data, int len) {
    uint8_t t[4 + PAGE]; t[0]=0x02; addr3(&t[1], a); memcpy(&t[4], data, len);
    wren(); if (spi_txn(t, 4 + len, NULL, 0)) return -1; return wait_idle();
}
static int flash_read(uint32_t a, uint8_t *buf, int len) {
    uint8_t t[4 + 256] = {0}; t[0]=0x03; addr3(&t[1], a);
    uint8_t r[4 + 256];
    if (spi_txn(t, 4 + len, r, 0)) return -1;
    memcpy(buf, &r[4], len);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <bdf> <file> [offset_hex]\n", argv[0]); return 2; }
    const char *bdf = argv[1], *path = argv[2];
    uint32_t off = (argc >= 4) ? (uint32_t)strtoul(argv[3], NULL, 0) : DEF_OFFSET;

    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return 1; }
    fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
    if (fsz <= 0 || fsz > (8 << 20)) { fprintf(stderr, "bad file size %ld\n", fsz); fclose(f); return 1; }
    uint8_t *img = malloc((size_t)fsz);
    if (fread(img, 1, (size_t)fsz, f) != (size_t)fsz) { perror("fread"); fclose(f); free(img); return 1; }
    fclose(f);

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); free(img); return 1; }
    O = be.ops; CTX = be.ctx;

    struct pw_card_info info = {0};
    if (O->card_info) O->card_info(CTX, &info);
    printf("card %s: device_id=0x%08x version=0x%08x\n", bdf, info.device_id, info.version);

    /* Warm-up: UltraScale+ STARTUPE3 masks the first few USRCCLK edges
     * after configuration, so the very first SPI transaction loses bits.
     * Issue a throwaway RDSR so the real commands below are all clean. */
    { uint8_t w[2] = {0x05, 0x00}; spi_txn(w, 2, NULL, 0); }

    uint8_t id[4] = {0x9F, 0, 0, 0}, rid[4];
    spi_txn(id, 4, rid, 0);
    printf("flash JEDEC ID: %02x %02x %02x  (Micron MT25Q = 20 BB 19)\n", rid[1], rid[2], rid[3]);

    printf("programming %ld bytes @ 0x%06x (live, PCIe stays up)...\n", fsz, off);
    for (uint32_t a = off & ~(SECTOR - 1); a < off + (uint32_t)fsz; a += SECTOR) {
        if (sector_erase(a)) { fprintf(stderr, "erase @0x%06x failed\n", a); return 1; }
    }
    for (long p = 0; p < fsz; p += PAGE) {
        int len = (fsz - p < PAGE) ? (int)(fsz - p) : (int)PAGE;
        if (page_program(off + (uint32_t)p, &img[p], len)) { fprintf(stderr, "program @0x%06lx failed\n", off + p); return 1; }
    }

    printf("verifying...\n");
    long mism = 0;
    for (long p = 0; p < fsz; p += 256) {
        int len = (fsz - p < 256) ? (int)(fsz - p) : 256;
        uint8_t rb[256];
        if (flash_read(off + (uint32_t)p, rb, len)) { fprintf(stderr, "read @0x%06lx failed\n", off + p); return 1; }
        if (memcmp(rb, &img[p], len) != 0) {
            for (int i = 0; i < len; i++) if (rb[i] != img[p + i]) { mism++; if (mism <= 4) fprintf(stderr, "  mismatch @0x%06lx: got %02x exp %02x\n", off + p + i, rb[i], img[p + i]); }
        }
    }
    free(img);
    if (mism == 0) { printf("VERIFY OK: %ld bytes match (live SPI write succeeded)\n", fsz); return 0; }
    printf("VERIFY FAILED: %ld mismatched bytes\n", mism);
    return 1;
}
