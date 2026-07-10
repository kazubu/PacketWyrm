# PacketWyrm PCI IDs

The PCI configuration-space identifiers PacketWyrm advertises to the
host. The numbers below are baked into the bitstream by
`fpga/as02mc04/ip/pcie_gen3.tcl` and matched by the host
`pw_pci_discover()` / `pw_bar_backend_open()` paths.

## Current values

| Field                | Value     | Meaning                                |
|----------------------|-----------|----------------------------------------|
| Vendor ID            | `0x10EE`  | Xilinx (the FPGA itself)               |
| Device ID            | `0xA502`  | AS02MC04 mnemonic                      |
| Subsystem Vendor ID  | `0x10EE`  | Xilinx                                 |
| Subsystem Device ID  | `0x7E57`  | "TEST" - PacketWyrm                    |
| Class Code           | `0x028000`| Network Controller / Other             |
| Revision             | `0x01`    |                                        |

`lspci` output expected after bring-up:

```
03:00.0 Network controller [0280]: Xilinx Corporation Device a502 (rev 01)
        Subsystem: Xilinx Corporation Device 7e57
```

## Why these values

We want IDs that:

1. **Do not collide with any well-known driver auto-load rule.**
   `0x1AF4` (Red Hat) is the obvious bad choice &mdash; that vendor
   ID is used by the `virtio-*` family of drivers and a misbehaving
   PacketWyrm bitstream could trigger one of those drivers to try to
   probe BAR0, with predictable results.
2. **Are honest.** Using Xilinx's vendor ID is truthful: the chip
   physically is a Xilinx KU3P. Linux does not load a generic
   "Xilinx" driver for arbitrary vendor-matched devices, so there is
   no driver-attach surprise.
3. **Are distinctive.** Device `0xA502` plus subsystem `0x7E57`
   look very obviously like a custom design when read by anyone
   familiar with the PCI database.
4. **Use Class `0x028000` (Network Controller / Other)** rather
   than `0x020000` (Ethernet controller) so the Linux Ethernet
   stack does not try to attach an interface to our raw BAR. The
   stack only sees a generic network device that requires an
   explicit driver bind.

## What we are *not* doing yet

PacketWyrm does **not** hold a PCI-SIG vendor ID. PCI-SIG charges
membership fees that are not justifiable for a development project,
and the alternatives (OSHWA-allocated shared blocks, etc.) are
either unavailable or unsuited.

When PacketWyrm moves toward production deployment, the right
sequence is:

1. Pick the deployment model:
   - **OEM shipping the tester** &rarr; that OEM applies for / uses
     their own PCI vendor ID.
   - **Open Source community project** &rarr; investigate the
     **Linux Foundation** / **OSHWA** shared-vendor proposals that
     exist for hobby and FOSS hardware; none are universally
     accepted at the time of writing.
2. Update `fpga/as02mc04/ip/pcie_gen3.tcl` with the allocated IDs.
3. Update `fpga/as02mc04/scripts/bringup-check.sh` defaults.
4. Update the host discovery paths
   (`sw/libpacketwyrm/src/pci.c::pw_pci_discover()` &mdash; takes
   vendor/device as arguments so no code change beyond the call
   site).
5. Bump `PW_VERSION` and document the change in this file.

The current `0x10EE:0xA502` values are intentionally easy to
search-and-replace later.

## Environment-variable override

For ad-hoc testing with a different bitstream, the **bring-up shell
scripts** respect environment variables:

| Variable                | Default     | Used by                                     |
|-------------------------|-------------|---------------------------------------------|
| `PW_VENDOR_ID`          | `10ee`      | `bringup-check.sh`, `bringup-check-vfio.sh` |
| `PW_DEVICE_ID`          | `a502`      | `bringup-check.sh`, `bringup-check-vfio.sh` |
| `PW_EXPECTED_DEVICE_REG`| `0xA502BEEF`| `bringup-check.sh`                          |

Missing values fall through to the defaults above.

The C tools do **not** read these variables. `packetwyrmd` opens each
card by its explicit BDF from the env config (each `cards[]` entry's
`pci:` field), so it never discovers by vendor/device at all. `pktwyrm`
(the discovery paths — `pktwyrm cards`, `pktwyrm gen-config`) matches
against the compile-time constants `PW_DEFAULT_PCI_VENDOR` /
`PW_DEFAULT_PCI_DEVICE` in
`sw/libpacketwyrm/include/packetwyrm/pci.h`, which is where a permanent
ID change is made in code.
