/* PacketWyrm: PCI device discovery via sysfs.
 *
 * Reads /sys/bus/pci/devices/<bdf>/{vendor,device,subsystem_vendor,
 * subsystem_device} to enumerate matching PacketWyrm cards. No
 * libpci dependency: the only thing we actually need is to walk
 * sysfs and parse a handful of "0xXXXX\n" files. */
#ifndef PACKETWYRM_PCI_H
#define PACKETWYRM_PCI_H

#include "packetwyrm/types.h"

#define PW_DEFAULT_PCI_VENDOR  0x10EE  /* Xilinx */
#define PW_DEFAULT_PCI_DEVICE  0xA502  /* PacketWyrm on AS02MC04 */

struct pw_pci_device {
    char     bdf[PW_PCI_BDF_MAX];      /* "0000:03:00.0" */
    uint16_t vendor;
    uint16_t device;
    uint16_t subsystem_vendor;
    uint16_t subsystem_device;
};

/* Discover PCI devices matching (vendor, device).
 *
 *  vendor == 0 matches any vendor, device == 0 matches any device.
 *  out   may be NULL if you only want the count.
 *  n_out is the capacity of out[].
 *
 * Returns:
 *  >= 0 : number of devices that matched (may exceed n_out; in that
 *         case only the first n_out are written).
 *  <  0 : negative pw_status. PW_E_IO if /sys/bus/pci is unreadable. */
int pw_pci_discover(uint16_t vendor, uint16_t device,
                    struct pw_pci_device *out, size_t n_out);

/* Map BAR0 of a PCI device by BDF.
 * On success, *out_addr is the userspace pointer and *out_size is
 * the BAR size in bytes. Caller must call pw_pci_close_bar0(). */
pw_status pw_pci_open_bar0(const char *bdf, void **out_addr, size_t *out_size);

/* Map an arbitrary file (e.g. /sys/.../resource0 or a test file) as
 * BAR0. Used by pw_bar_backend_open_path() and unit tests. */
pw_status pw_pci_open_bar0_path(const char *path, void **out_addr, size_t *out_size);

void pw_pci_close_bar0(void *addr, size_t size);

#endif
