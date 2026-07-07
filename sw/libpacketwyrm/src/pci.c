/* PacketWyrm: PCI discovery + BAR mmap via sysfs. */

#include "packetwyrm/pci.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PW_SYSFS_PCI "/sys/bus/pci/devices"

static int read_hex_file(const char *path, uint32_t *out) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    unsigned v = 0;
    int n = fscanf(f, "%x", &v);
    fclose(f);
    if (n != 1) return -1;
    *out = v;
    return 0;
}

static int read_pci_device(const char *bdf, struct pw_pci_device *d) {
    /* A canonical PCI BDF is "DDDD:BB:DD.F" = 12 chars. readdir can
     * hand us names up to NAME_MAX; refuse anything that doesn't fit
     * into a BDF before composing sysfs paths. */
    size_t n = strnlen(bdf, PW_PCI_BDF_MAX);
    if (n == 0 || n >= PW_PCI_BDF_MAX) return -1;
    memcpy(d->bdf, bdf, n);
    d->bdf[n] = '\0';

    char path[64];
    uint32_t v;

    snprintf(path, sizeof(path), PW_SYSFS_PCI "/%s/vendor", d->bdf);
    if (read_hex_file(path, &v) < 0) return -1;
    d->vendor = (uint16_t)v;

    snprintf(path, sizeof(path), PW_SYSFS_PCI "/%s/device", d->bdf);
    if (read_hex_file(path, &v) < 0) return -1;
    d->device = (uint16_t)v;

    snprintf(path, sizeof(path), PW_SYSFS_PCI "/%s/subsystem_vendor", d->bdf);
    if (read_hex_file(path, &v) == 0) d->subsystem_vendor = (uint16_t)v;

    snprintf(path, sizeof(path), PW_SYSFS_PCI "/%s/subsystem_device", d->bdf);
    if (read_hex_file(path, &v) == 0) d->subsystem_device = (uint16_t)v;

    return 0;
}

int pw_pci_discover(uint16_t vendor, uint16_t device,
                    struct pw_pci_device *out, size_t n_out) {
    DIR *dir = opendir(PW_SYSFS_PCI);
    if (!dir) {
        if (errno == ENOENT) return 0;  /* no PCI bus on this host */
        return PW_E_IO;
    }

    int matched = 0;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (de->d_name[0] == '.') continue;
        struct pw_pci_device d = {0};
        if (read_pci_device(de->d_name, &d) < 0) continue;
        if (vendor && d.vendor != vendor) continue;
        if (device && d.device != device) continue;
        if (out && (size_t)matched < n_out) out[matched] = d;
        matched++;
    }
    closedir(dir);

    /* Sort by BDF for deterministic card_id assignment. */
    if (out && matched > 1) {
        size_t n = (size_t)matched < n_out ? (size_t)matched : n_out;
        for (size_t i = 0; i + 1 < n; i++) {
            for (size_t j = i + 1; j < n; j++) {
                if (strcmp(out[i].bdf, out[j].bdf) > 0) {
                    struct pw_pci_device t = out[i]; out[i] = out[j]; out[j] = t;
                }
            }
        }
    }
    return matched;
}

pw_status pw_pci_open_bar0_path(const char *path, void **out_addr, size_t *out_size) {
    if (!path || !out_addr || !out_size) return PW_E_INVAL;

    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) return PW_E_IO;

    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return PW_E_IO; }
    size_t sz = (size_t)st.st_size;
    if (sz == 0) {
        /* sysfs resource files / device nodes may report st_size 0 while the
         * PCIe BAR behind them is real -- default the map length for those.
         * A REGULAR file though genuinely is empty: mmap'ing 64 K of it would
         * succeed and then SIGBUS on the first register access, so fail it
         * with a clear error instead. (A short-but-nonempty regular file maps
         * at its true size; the backend range-checks accesses against that.) */
        if (S_ISREG(st.st_mode)) {
            fprintf(stderr, "packetwyrm: BAR image %s is empty -- cannot map "
                    "a zero-length regular file as a BAR\n", path);
            close(fd);
            return PW_E_OUT_OF_RANGE;
        }
        sz = 65536;
    }

    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return PW_E_IO;

    *out_addr = p;
    *out_size = sz;
    return PW_OK;
}

pw_status pw_pci_open_bar0(const char *bdf, void **out_addr, size_t *out_size) {
    if (!bdf) return PW_E_INVAL;
    size_t n = strnlen(bdf, PW_PCI_BDF_MAX);
    if (n == 0 || n >= PW_PCI_BDF_MAX) return PW_E_INVAL;
    char path[64];
    snprintf(path, sizeof(path), PW_SYSFS_PCI "/%.*s/resource0", (int)n, bdf);
    return pw_pci_open_bar0_path(path, out_addr, out_size);
}

void pw_pci_close_bar0(void *addr, size_t size) {
    if (addr) munmap(addr, size);
}
