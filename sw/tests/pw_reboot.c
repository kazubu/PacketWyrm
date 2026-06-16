/* pw_reboot -- in-band FPGA reconfiguration (ICAP IPROG) over PCIe.
 *
 * Writes the REBOOT magic to the CSR, which makes the FPGA reload its
 * bitstream from flash (WBSTAR=0) via ICAP -- no JTAG, no power cycle.
 * Reconfiguration drops the PCIe endpoint, so this tool then does the
 * PCIe remove + rescan and re-reads the identity registers to confirm
 * the device came back (and which image it booted). Run as root.
 *
 *   sudo pw_reboot <bdf>        e.g. sudo pw_reboot 0000:07:00.0
 *
 * If the reloaded flash image is bad the device will not re-enumerate;
 * recover with JTAG.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static int sysfs_write1(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return -1; }
    fputs("1\n", f);
    return fclose(f);
}

static void show_identity(const char *bdf, const char *when) {
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        printf("  [%s] backend open failed\n", when);
        return;
    }
    struct pw_card_info info = {0};
    if (be.ops->card_info) be.ops->card_info(be.ctx, &info);
    printf("  [%s] device_id=0x%08x version=0x%08x build_id=0x%08x num_flows=%u\n",
           when, info.device_id, info.version, info.build_id, info.num_local_flows);
    if (be.ops->close) be.ops->close(be.ctx);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf>  (e.g. 0000:07:00.0)\n", argv[0]); return 2; }
    const char *bdf = argv[1];

    char rm[256], rescan[] = "/sys/bus/pci/rescan";
    snprintf(rm, sizeof rm, "/sys/bus/pci/devices/%s/remove", bdf);

    pw_vfio_bind(bdf);
    printf("identity before reboot:\n");
    show_identity(bdf, "before");

    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    printf("triggering ICAP IPROG (PCIe link will drop, FPGA reloads from flash)...\n");
    /* Best-effort: the FPGA starts reconfiguring right after this write, so
     * the completion may not return -- ignore the status. */
    be.ops->write32(be.ctx, PWFPGA_REG_REBOOT, PWFPGA_REBOOT_MAGIC);
    if (be.ops->close) be.ops->close(be.ctx);

    printf("PCIe remove + rescan...\n");
    sysfs_write1(rm);
    sleep(1);
    sysfs_write1(rescan);
    sleep(3);

    pw_vfio_bind(bdf);
    printf("identity after reboot (reloaded from flash):\n");
    show_identity(bdf, "after");
    printf("done. (compare build_id / num_flows above to confirm the flash image booted)\n");
    return 0;
}
