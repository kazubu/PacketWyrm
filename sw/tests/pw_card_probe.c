/* pw_card_probe: open a real PacketWyrm card and print its identity.
 *
 * Exercises the production backend selection (sysfs mmap, with VFIO
 * fallback under lockdown). Used to confirm on-hardware bring-up:
 *
 *   sudo build/pw_card_probe 0000:07:00.0 --bind
 *
 * --bind first binds the device to vfio-pci (needed on Secure Boot /
 * lockdown hosts). Exits 0 iff device_id == 0xA502BEEF and the value is
 * stable across repeated reads.
 */
#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <pci-bdf> [--bind]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];

    if (argc >= 3 && strcmp(argv[2], "--bind") == 0) {
        pw_status b = pw_vfio_bind(bdf);
        if (b != PW_OK) {
            fprintf(stderr, "vfio bind of %s failed (%d) -- is vfio-pci loaded?\n",
                    bdf, (int)b);
            return 1;
        }
    }

    struct pw_card_backend be;
    pw_status r = pw_bar_backend_open(bdf, &be);
    if (r != PW_OK) {
        fprintf(stderr, "backend open failed (%d)\n", (int)r);
        return 1;
    }

    struct pw_card_info ci;
    r = be.ops->card_info(be.ctx, &ci);
    if (r != PW_OK) {
        fprintf(stderr, "card_info failed (%d)\n", (int)r);
        pw_card_backend_close(&be);
        return 1;
    }

    printf("device_id=0x%08x version=0x%08x build=0x%08x git=0x%08x\n",
           ci.device_id, ci.version, ci.build_id, ci.git_hash);
    printf("caps=0x%08x ports=%u flows=%u ifs=%u classifier=%u\n",
           ci.capabilities, ci.num_local_ports, ci.num_local_flows,
           ci.num_logical_interfaces, ci.num_classifier_entries);

    /* Read register 0 repeatedly to confirm the AXI-Lite read path is
     * stable (the bug fixed in pw_csr_min). */
    uint32_t v0 = 0;
    int stable = 1;
    for (int i = 0; i < 16; i++) {
        uint32_t v;
        if (be.ops->read32(be.ctx, 0, &v) != PW_OK) { stable = 0; break; }
        if (i == 0) v0 = v; else if (v != v0) stable = 0;
    }
    printf("device_id stable over 16 reads: %s (0x%08x)\n",
           stable ? "yes" : "NO", v0);

    pw_card_backend_close(&be);
    int ok = (ci.device_id == 0xA502BEEF) && stable;
    printf("%s\n", ok ? "OK: card identity verified" : "FAIL");
    return ok ? 0 : 1;
}
