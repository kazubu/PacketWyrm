/* pw_flash -- in-system SPI flash write/verify over the PCIe/CSR path.
 *
 * Drives the pw_spi_flash CSR engine (no JTAG, no FPGA reconfiguration:
 * the running bitstream and PCIe endpoint stay up) to erase, program and
 * read-back-verify the board's config flash. The flash protocol lives in
 * libpacketwyrm (packetwyrm/spi_flash.h), shared with the packetwyrmd
 * `flash.write` RPC.
 *
 *   sudo pw_flash <bdf> <file> [offset_hex]
 *
 * Default offset 0x00E00000 (14 MB) -- past the ~12 MB boot image but
 * inside 3-byte (16 MB) addressing -- so dev writes never touch the
 * bootable image. Use offset 0 to (re)write the boot image.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/spi_flash.h"

#define DEF_OFFSET 0x00E00000u

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <bdf> <file> [offset_hex]\n", argv[0]); return 2; }
    const char *bdf = argv[1], *path = argv[2];
    uint32_t off = (argc >= 4) ? (uint32_t)strtoul(argv[3], NULL, 0) : DEF_OFFSET;

    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return 1; }
    fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
    /* 16 MB cap: the boot image is ~12 MB (was <8 MB when this guard was added)
     * and the MT25QU256 is 32 MB, so a full boot image at offset 0 must fit. */
    if (fsz <= 0 || fsz > (16 << 20)) { fprintf(stderr, "bad file size %ld\n", fsz); fclose(f); return 1; }
    /* The in-design SPI master uses 3-byte addressing -> the addressable window is
     * the low 16 MB; an address past 0xFFFFFF WRAPS to the low sectors. So a write
     * whose END exceeds 16 MB would silently clobber the boot image at offset 0.
     * The full ~12 MB image only fits at offset 0; the 14 MB dev DEF_OFFSET is for
     * small scratch writes. Reject offset+len > 16 MB rather than corrupt the boot
     * region. */
    if ((uint64_t)off + (uint64_t)fsz > 0x01000000u) {
        fprintf(stderr, "offset 0x%x + %ld bytes exceeds the 16 MB (3-byte) range "
                "and would wrap onto the boot image; pass offset 0x0 for a full image\n",
                off, fsz);
        fclose(f); return 1;
    }
    uint8_t *img = malloc((size_t)fsz);
    if (fread(img, 1, (size_t)fsz, f) != (size_t)fsz) { perror("fread"); fclose(f); free(img); return 1; }
    fclose(f);

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); free(img); return 1; }

    struct pw_card_info info = {0};
    if (be.ops->card_info) be.ops->card_info(be.ctx, &info);
    printf("card %s: device_id=0x%08x version=0x%08x\n", bdf, info.device_id, info.version);

    uint8_t id[3] = {0};
    pw_flash_read_id(be.ops, be.ctx, id);
    printf("flash JEDEC ID: %02x %02x %02x  (Micron MT25Q = 20 BB 19)\n", id[0], id[1], id[2]);

    printf("programming %ld bytes @ 0x%06x (live, PCIe stays up)...\n", fsz, off);
    uint64_t mism = 0;
    pw_status s = pw_flash_program(be.ops, be.ctx, off, img, (size_t)fsz, &mism);
    free(img);
    if (s != PW_OK) { fprintf(stderr, "flash program failed (%d)\n", s); return 1; }
    if (mism == 0) { printf("VERIFY OK: %ld bytes match (live SPI write succeeded)\n", fsz); return 0; }
    printf("VERIFY FAILED: %llu mismatched bytes\n", (unsigned long long)mism);
    return 1;
}
