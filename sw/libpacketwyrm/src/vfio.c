/* PacketWyrm: VFIO BAR mapping (see vfio.h). */

#include "packetwyrm/vfio.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/vfio.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

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

void pw_vfio_close(struct pw_vfio_handle *h) {
    if (!h) return;
    if (h->base && h->base != MAP_FAILED) munmap(h->base, h->size);
    if (h->device_fd >= 0)    close(h->device_fd);
    if (h->group_fd >= 0)     close(h->group_fd);
    if (h->container_fd >= 0) close(h->container_fd);
    h->base = NULL;
    h->size = 0;
    h->device_fd = h->group_fd = h->container_fd = -1;
}

pw_status pw_vfio_open_bar(const char *bdf, int bar_index,
                           struct pw_vfio_handle *h) {
    if (!bdf || !h || bar_index < 0 || bar_index > 5) return PW_E_INVAL;

    h->container_fd = h->group_fd = h->device_fd = -1;
    h->base = NULL;
    h->size = 0;

    int grp = iommu_group_of(bdf);
    if (grp < 0) return PW_E_IO;

    h->container_fd = open("/dev/vfio/vfio", O_RDWR);
    if (h->container_fd < 0) return PW_E_IO;

    if (ioctl(h->container_fd, VFIO_GET_API_VERSION) != VFIO_API_VERSION) {
        pw_vfio_close(h);
        return PW_E_BACKEND;
    }

    char gpath[64];
    snprintf(gpath, sizeof(gpath), "/dev/vfio/%d", grp);
    h->group_fd = open(gpath, O_RDWR);
    if (h->group_fd < 0) {
        /* Most common cause: device not bound to vfio-pci. */
        pw_vfio_close(h);
        return PW_E_IO;
    }

    struct vfio_group_status gs = { .argsz = sizeof(gs) };
    if (ioctl(h->group_fd, VFIO_GROUP_GET_STATUS, &gs) < 0 ||
        !(gs.flags & VFIO_GROUP_FLAGS_VIABLE)) {
        pw_vfio_close(h);
        return PW_E_IO;
    }

    if (ioctl(h->group_fd, VFIO_GROUP_SET_CONTAINER, &h->container_fd) < 0 ||
        ioctl(h->container_fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU) < 0) {
        pw_vfio_close(h);
        return PW_E_IO;
    }

    h->device_fd = ioctl(h->group_fd, VFIO_GROUP_GET_DEVICE_FD, bdf);
    if (h->device_fd < 0) {
        pw_vfio_close(h);
        return PW_E_IO;
    }

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
