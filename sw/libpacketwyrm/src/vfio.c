/* PacketWyrm: VFIO BAR mapping (see vfio.h). */

#include "packetwyrm/vfio.h"
#include "packetwyrm/pci.h"   /* pw_pci_normalize_bdf */

#include <errno.h>
#include <fcntl.h>
#include <linux/vfio.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* --- shared IOMMU-group registry --------------------------------------------
 * Two (or more) cards can land in ONE IOMMU group when they sit behind non-ACS
 * CPU root ports. VFIO forbids opening a group fd twice, and a group's DMA
 * container is shared by all its devices, so we open the group + container ONCE
 * per group and hand each card a device fd from it. The DMA IOVA bump allocator
 * lives here too (per container), so cards sharing a container get disjoint
 * IOVAs. Opens/closes run single-threaded at daemon startup (see vfio.h), so no
 * lock is needed. */
#define PW_VFIO_MAX_GROUPS 16
static struct vfio_group_slot {
    int      group_no;      /* iommu group number; -1 = free slot */
    int      group_fd;
    int      container_fd;
    uint64_t iova_next;     /* shared DMA IOVA bump allocator for this container */
    int      refcount;      /* device fds handed out from this group */
} g_vfio_groups[PW_VFIO_MAX_GROUPS] = {
    [0 ... PW_VFIO_MAX_GROUPS - 1] = { .group_no = -1 }
};

static int vfio_group_find(int group_no) {
    for (int i = 0; i < PW_VFIO_MAX_GROUPS; i++)
        if (g_vfio_groups[i].refcount > 0 && g_vfio_groups[i].group_no == group_no)
            return i;
    return -1;
}
static int vfio_group_free_slot(void) {
    for (int i = 0; i < PW_VFIO_MAX_GROUPS; i++)
        if (g_vfio_groups[i].refcount == 0) return i;
    return -1;
}

/* Resolve the IOMMU group number for a PCI BDF via
 * /sys/bus/pci/devices/<bdf>/iommu_group -> .../iommu_groups/<N>. */
static int iommu_group_of(const char *bdf) {
    char link[256];
    snprintf(link, sizeof(link),
             "/sys/bus/pci/devices/%s/iommu_group", bdf);
    char target[256];
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    if (n < 0) return -1;
    target[n] = '\0';
    const char *base = strrchr(target, '/');
    base = base ? base + 1 : target;
    int grp = -1;
    if (sscanf(base, "%d", &grp) != 1) return -1;
    return grp;
}

/* Prepare a (vfio-bound) device so its BARs are actually readable. Two fresh-
 * host hazards both make every BAR read return all-1s (0xffffffff) while config
 * space still reads -- i.e. they look exactly like a dead card:
 *
 *   1. The kernel's PCI runtime PM autosuspends the idle (fd-closed) device to
 *      D3hot. Pin it in D0 via power/control = "on".
 *   2. PCI_COMMAND Memory Space decoding is disabled on a fresh bind
 *      (lspci "Mem-", regions "[disabled]"). Set MEMORY|MASTER.
 *
 * Both are done via SYSFS (config space + power/control), the same path setpci
 * uses -- a write through the *vfio* config region is virtualised by vfio-pci
 * and does NOT reach the real command register, so it must be sysfs. Root only;
 * best-effort (a later BAR read surfaces any failure). Order matters: resume to
 * D0 first, then enable memory decoding. */
void pw_vfio_prep_device(const char *bdf) {
    char path[160];

    /* (1) pin in D0 */
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/power/control", bdf);
    int fd = open(path, O_WRONLY);
    if (fd >= 0) { ssize_t w = write(fd, "on", 2); (void)w; close(fd); }

    /* (2) PCI_COMMAND |= MEMORY|MASTER, read-modify-write at config offset 0x04 */
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/config", bdf);
    fd = open(path, O_RDWR);
    if (fd >= 0) {
        uint16_t cmd = 0;
        if (pread(fd, &cmd, sizeof(cmd), 0x04) == (ssize_t)sizeof(cmd)) {
            uint16_t want = cmd | 0x0006u;
            if (want != cmd) { ssize_t w = pwrite(fd, &want, sizeof(want), 0x04); (void)w; }
        }
        close(fd);
    }
}

void pw_vfio_close(struct pw_vfio_handle *h) {
    if (!h) return;
    if (h->base && h->base != MAP_FAILED) munmap(h->base, h->size);
    if (h->device_fd >= 0) close(h->device_fd);   /* per-device: always ours */
    /* The group + container fds are owned by the shared registry slot; only
     * close them when the LAST card in the group is released. grp_slot holds
     * (registry index + 1), 0 = none (see vfio.h). */
    if (h->grp_slot != 0 && h->grp_slot <= PW_VFIO_MAX_GROUPS) {
        struct vfio_group_slot *g = &g_vfio_groups[h->grp_slot - 1];
        if (g->refcount > 0 && --g->refcount == 0) {
            if (g->group_fd >= 0)     close(g->group_fd);
            if (g->container_fd >= 0) close(g->container_fd);
            g->group_no = -1; g->group_fd = -1; g->container_fd = -1;
            g->iova_next = 0;
        }
    }
    h->base = NULL;
    h->size = 0;
    h->device_fd = h->group_fd = h->container_fd = -1;
    h->grp_slot = 0;
}

/* --- bus-master DMA buffer mapping (IOMMU) ----------------------------- */

/* Base of the device-DMA IOVA space. IOVAs are bump-allocated from here rather
 * than reused from the userspace VA: VFIO TYPE1 maps any page-aligned IOVA in
 * the IOMMU aperture to the buffer VA, and a process VA is not guaranteed to be
 * a valid IOVA (it depends on the aperture / kernel config). 4 GiB sits above
 * the low reserved regions (the MSI window at 0xFEEx_xxxx etc.) and inside the
 * aperture on every VT-d / AMD-Vi host we target. */
#define PW_VFIO_IOVA_BASE  0x100000000ull

pw_status pw_vfio_map_dma(struct pw_vfio_handle *h, void *vaddr, size_t len,
                          uint64_t *out_iova) {
    if (!h || h->container_fd < 0 || !vaddr || len == 0) return PW_E_INVAL;
    /* VFIO TYPE1 requires page-aligned vaddr + size; the header documents this
     * contract. Enforce it here so a misaligned caller gets a clear PW_E_INVAL
     * rather than an opaque ioctl EINVAL flattened to PW_E_IO. */
    long ps = sysconf(_SC_PAGESIZE);
    if (ps > 0) {
        uint64_t pg = (uint64_t)ps;
        if ((uint64_t)(uintptr_t)vaddr % pg != 0 || (uint64_t)len % pg != 0)
            return PW_E_INVAL;
    }
    /* Allocate from the PER-CONTAINER bump allocator (in the shared group
     * registry), so two cards sharing one IOMMU group/container get disjoint
     * IOVAs (a per-handle allocator would hand both the same base and the second
     * MAP_DMA would EEXIST-collide). Page-aligned: the caller posix_memalign's
     * vaddr + rounds len up, so the bump pointer stays page-aligned. */
    if (h->grp_slot == 0 || h->grp_slot > PW_VFIO_MAX_GROUPS) return PW_E_INVAL;
    struct vfio_group_slot *g = &g_vfio_groups[h->grp_slot - 1];
    if (g->iova_next == 0) g->iova_next = PW_VFIO_IOVA_BASE;
    uint64_t iova = g->iova_next;
    if (iova > UINT64_MAX - (uint64_t)len) return PW_E_INVAL;   /* IOVA range wrap */
    struct vfio_iommu_type1_dma_map dm = {
        .argsz = sizeof(dm),
        .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
        .vaddr = (uint64_t)(uintptr_t)vaddr,
        .iova  = iova,
        .size  = len,
    };
    if (ioctl(h->container_fd, VFIO_IOMMU_MAP_DMA, &dm) < 0) return PW_E_IO;
    g->iova_next = iova + len;
    if (out_iova) *out_iova = iova;
    return PW_OK;
}

pw_status pw_vfio_unmap_dma(struct pw_vfio_handle *h, uint64_t iova, size_t len) {
    if (!h || h->container_fd < 0 || len == 0) return PW_E_INVAL;
    struct vfio_iommu_type1_dma_unmap du = {
        .argsz = sizeof(du),
        .iova  = iova,
        .size  = len,
    };
    if (ioctl(h->container_fd, VFIO_IOMMU_UNMAP_DMA, &du) < 0) return PW_E_IO;
    return PW_OK;
}

pw_status pw_vfio_map_region(struct pw_vfio_handle *h, int bar_index,
                             void **out_base, size_t *out_size) {
    if (!h || h->device_fd < 0 || !out_base || bar_index < 0 || bar_index > 5)
        return PW_E_INVAL;
    struct vfio_region_info ri = {
        .argsz = sizeof(ri),
        .index = (uint32_t)(VFIO_PCI_BAR0_REGION_INDEX + bar_index),
    };
    if (ioctl(h->device_fd, VFIO_DEVICE_GET_REGION_INFO, &ri) < 0) return PW_E_IO;
    if (ri.size == 0 || !(ri.flags & VFIO_REGION_INFO_FLAG_MMAP)) return PW_E_BACKEND;
    void *p = mmap(NULL, ri.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   h->device_fd, ri.offset);
    if (p == MAP_FAILED) return PW_E_IO;
    *out_base = p;
    if (out_size) *out_size = ri.size;
    return PW_OK;
}

pw_status pw_vfio_open_bar(const char *bdf_in, int bar_index,
                           struct pw_vfio_handle *h) {
    if (!bdf_in || !h || bar_index < 0 || bar_index > 5) return PW_E_INVAL;

    /* Accept short BDF forms (e.g. "07:00.0") -- canonicalize once here so both
     * the sysfs paths below and the VFIO_GROUP_GET_DEVICE_FD device name (which
     * requires the full "DDDD:BB:DD.F") resolve. */
    char cbdf[13];
    if (pw_pci_normalize_bdf(bdf_in, cbdf) != PW_OK) return PW_E_INVAL;
    const char *bdf = cbdf;

    /* Ensure the device is in D0 with memory decoding on before we mmap/read. */
    pw_vfio_prep_device(bdf);

    h->container_fd = h->group_fd = h->device_fd = -1;
    h->base = NULL;
    h->size = 0;
    h->grp_slot = 0;

    int grp = iommu_group_of(bdf);
    if (grp < 0) return PW_E_IO;

    /* Reuse an already-open group+container (another card in the same IOMMU
     * group), or open one fresh into a free registry slot. */
    int gi = vfio_group_find(grp);
    if (gi < 0) {
        gi = vfio_group_free_slot();
        if (gi < 0) return PW_E_NO_RESOURCES;   /* too many distinct groups */
        int cfd = open("/dev/vfio/vfio", O_RDWR);
        if (cfd < 0) return PW_E_IO;
        if (ioctl(cfd, VFIO_GET_API_VERSION) != VFIO_API_VERSION) {
            close(cfd); return PW_E_BACKEND;
        }
        char gpath[64];
        snprintf(gpath, sizeof(gpath), "/dev/vfio/%d", grp);
        int gfd = open(gpath, O_RDWR);
        if (gfd < 0) { close(cfd); return PW_E_IO; }  /* device not bound to vfio-pci? */
        struct vfio_group_status gs = { .argsz = sizeof(gs) };
        if (ioctl(gfd, VFIO_GROUP_GET_STATUS, &gs) < 0 ||
            !(gs.flags & VFIO_GROUP_FLAGS_VIABLE)) {
            close(gfd); close(cfd); return PW_E_IO;
        }
        if (ioctl(gfd, VFIO_GROUP_SET_CONTAINER, &cfd) < 0 ||
            ioctl(cfd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU) < 0) {
            close(gfd); close(cfd); return PW_E_IO;
        }
        g_vfio_groups[gi] = (struct vfio_group_slot){
            .group_no = grp, .group_fd = gfd, .container_fd = cfd,
            .iova_next = 0, .refcount = 0
        };
    }

    h->device_fd = ioctl(g_vfio_groups[gi].group_fd, VFIO_GROUP_GET_DEVICE_FD, bdf);
    if (h->device_fd < 0) {
        /* If we just opened this group and no card is using it, tear it back down. */
        if (g_vfio_groups[gi].refcount == 0) {
            close(g_vfio_groups[gi].group_fd);
            close(g_vfio_groups[gi].container_fd);
            g_vfio_groups[gi].group_no = -1;
        }
        return PW_E_IO;
    }
    g_vfio_groups[gi].refcount++;
    h->grp_slot     = (uint64_t)(gi + 1);              /* index + 1; 0 = none */
    h->group_fd     = g_vfio_groups[gi].group_fd;      /* copies for reference */
    h->container_fd = g_vfio_groups[gi].container_fd;

    struct vfio_region_info ri = {
        .argsz = sizeof(ri),
        .index = (uint32_t)(VFIO_PCI_BAR0_REGION_INDEX + bar_index),
    };
    if (ioctl(h->device_fd, VFIO_DEVICE_GET_REGION_INFO, &ri) < 0) {
        pw_vfio_close(h);
        return PW_E_IO;
    }
    if (ri.size == 0 || !(ri.flags & VFIO_REGION_INFO_FLAG_MMAP)) {
        pw_vfio_close(h);
        return PW_E_BACKEND;
    }

    void *p = mmap(NULL, ri.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   h->device_fd, ri.offset);
    if (p == MAP_FAILED) {
        pw_vfio_close(h);
        return PW_E_IO;
    }

    h->base = p;
    h->size = ri.size;
    return PW_OK;
}

/* --- vfio-pci binding (root) ------------------------------------------- */

static int write_str(const char *path, const char *s) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    ssize_t n = write(fd, s, strlen(s));
    close(fd);
    return (n == (ssize_t)strlen(s)) ? 0 : -1;
}

static int current_driver(const char *bdf, char *out, size_t outlen) {
    char link[256], target[256];
    snprintf(link, sizeof(link), "/sys/bus/pci/devices/%s/driver", bdf);
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    if (n < 0) return -1;  /* no driver bound */
    target[n] = '\0';
    const char *base = strrchr(target, '/');
    base = base ? base + 1 : target;
    snprintf(out, outlen, "%s", base);
    return 0;
}

pw_status pw_vfio_bind(const char *bdf) {
    if (!bdf) return PW_E_INVAL;

    char drv[256];
    if (current_driver(bdf, drv, sizeof(drv)) == 0) {
        if (strcmp(drv, "vfio-pci") == 0) return PW_OK;  /* already bound */
        char unbind[128];
        snprintf(unbind, sizeof(unbind),
                 "/sys/bus/pci/devices/%s/driver/unbind", bdf);
        if (write_str(unbind, bdf) < 0) return PW_E_IO;
    }

    char ovr[128];
    snprintf(ovr, sizeof(ovr),
             "/sys/bus/pci/devices/%s/driver_override", bdf);
    if (write_str(ovr, "vfio-pci") < 0) return PW_E_IO;

    if (write_str("/sys/bus/pci/drivers/vfio-pci/bind", bdf) < 0) {
        /* vfio-pci not loaded, or bind failed. */
        return PW_E_IO;
    }
    return PW_OK;
}
