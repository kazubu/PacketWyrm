/* PacketWyrm: VFIO BAR mapping.
 *
 * Maps an FPGA BAR through the kernel VFIO framework instead of the
 * sysfs resourceN file. This is the access path that works on hosts
 * with Secure Boot / kernel lockdown enabled, where setpci and direct
 * sysfs resource mmap are blocked but IOMMU-mediated VFIO is permitted.
 *
 * The device must be bound to vfio-pci and be the only device in its
 * IOMMU group (pw_vfio_bind() handles the bind; a udev driver_override
 * rule or systemd unit can do it at boot instead). */
#ifndef PACKETWYRM_VFIO_H
#define PACKETWYRM_VFIO_H

#include "packetwyrm/types.h"
#include <stddef.h>

struct pw_vfio_handle {
    int    container_fd;
    int    group_fd;
    int    device_fd;
    void  *base;   /* mmap of the requested BAR, or NULL */
    size_t size;   /* BAR size in bytes */
};

/* Map BAR `bar_index` (0..5) of the vfio-pci-bound device `bdf`
 * (e.g. "0000:07:00.0"). On success fills *h and returns PW_OK; the
 * caller must pw_vfio_close(h). Returns PW_E_IO if /dev/vfio is
 * unavailable or the device is not bound to vfio-pci, PW_E_BACKEND
 * if the BAR is not mmappable. */
pw_status pw_vfio_open_bar(const char *bdf, int bar_index,
                           struct pw_vfio_handle *h);

void pw_vfio_close(struct pw_vfio_handle *h);

/* Map a userspace buffer for device (bus-master) DMA via VFIO_IOMMU_MAP_DMA,
 * so the FPGA can read/write it over PCIe. Uses identity IOVA (iova = vaddr);
 * *out_iova returns the device-visible address to program into XDMA
 * descriptors. `vaddr` and `len` must be page-aligned (posix_memalign to the
 * page size + round len up). Requires a mapped device (container_fd valid).
 * Returns PW_E_INVAL on bad args, PW_E_IO if the ioctl fails. */
pw_status pw_vfio_map_dma(struct pw_vfio_handle *h, void *vaddr, size_t len,
                          uint64_t *out_iova);

/* Tear down a mapping established by pw_vfio_map_dma. */
pw_status pw_vfio_unmap_dma(struct pw_vfio_handle *h, uint64_t iova, size_t len);

/* Bind `bdf` to vfio-pci (root): unbind any current driver, set
 * driver_override to vfio-pci, bind. Returns PW_OK if already bound or
 * on success. Requires the vfio-pci module to be loaded/registered. */
pw_status pw_vfio_bind(const char *bdf);

/* Prepare a device for BAR access: pin it in D0 (defeat PCI runtime-PM
 * autosuspend to D3, which makes BARs read all-1s) and enable PCI_COMMAND
 * memory + bus-master decoding, both via sysfs. Idempotent, best-effort, root.
 * Called automatically by pw_bar_backend_open before either mmap path. */
void pw_vfio_prep_device(const char *bdf);

#endif
