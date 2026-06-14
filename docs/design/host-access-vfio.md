# Host CSR access: sysfs mmap vs VFIO

`libpacketwyrm`'s real card backend (`pw_bar_backend_open`) drives the
FPGA CSR window by mmapping a PCIe BAR from userspace. There are two
ways to get that mapping, and which one works depends on the host's
security posture.

## Default: sysfs resource mmap

`pw_pci_open_bar0` opens `/sys/bus/pci/devices/<bdf>/resource0` and
mmaps it. Simple, no driver needed, works on most hosts. The
`99-packetwyrm.rules` udev rule grants the `packetwyrm` group access so
the daemon need not run as root.

## Under Secure Boot / kernel lockdown: VFIO

When Secure Boot is enabled the kernel runs in **lockdown=integrity**
mode, which blocks raw PCI config writes (`setpci`) and direct sysfs
BAR mmap — `mmap` of `resource0` returns `EPERM` even as root. Check:

```sh
cat /sys/kernel/security/lockdown      # "[integrity]" or "[confidentiality]" => locked
mokutil --sb-state                     # SecureBoot enabled
```

The sanctioned path then is **VFIO**, which mediates BAR access through
the IOMMU. `pw_vfio_open_bar` opens `/dev/vfio/vfio` + the device's
group, gets a device fd, and mmaps the BAR region. `pw_bar_backend_open`
tries sysfs first and **falls back to VFIO automatically** when the
sysfs mmap is refused, so the daemon needs no special configuration —
the card just has to be bound to `vfio-pci`.

### Binding to vfio-pci

The card must be bound to `vfio-pci` and sit alone in its IOMMU group
(it does on the AS02MC04). Options:

- One-shot (debug): `sudo build/pw_card_probe <bdf> --bind`, or
  `sudo fpga/as02mc04/scripts/bringup-check-vfio.sh`.
- Library call: `pw_vfio_bind(bdf)` (root).
- At boot: install `scripts/98-packetwyrm-vfio.rules` (driver_override).

### Selection knobs

- `PW_BACKEND=vfio|sysfs` — force a path instead of auto-selecting.
- `PW_CSR_BAR=<n>` — CSR BAR index (default 0; the xdma DMA-mode build
  puts the AXI-Lite-master CSR window on BAR0, the XDMA control BAR on
  BAR1).

## Hazard: do not FLR the function from userspace

`VFIO_DEVICE_RESET` / function-level reset on the AS02MC04 cascades to
the PCIe link and reboots the host. Never reset the function to "clear"
a stuck access; fix the root cause instead. The FPGA keeps its
configuration across a warm reboot; only a cold power-off (or an SPI
flash boot image) changes what is loaded.

## Verified

`pw_card_probe` reads `device_id=0xa502beef`, `version=0x00010000`,
`ports=2` over VFIO on the bring-up host (Secure Boot on, lockdown
integrity), stable across repeated reads.
