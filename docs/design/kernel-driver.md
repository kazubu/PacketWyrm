# Phase 11: optional kernel netdev driver

PacketWyrm's userspace TAP daemon (`packetwyrmd` + `pw_host_plane`)
is the supported deployment today. A kernel driver is **not**
required for any current goal. This document scopes the conditions
under which one becomes desirable and sketches the design.

## When a kernel driver becomes useful

The userspace TAP plane is intentionally simple and works for the
test workloads we have in mind (ARP, BGP/179, OSPF, ICMP, ping).
Move work into a kernel driver when one or more of:

1. **Control-plane packet rate exceeds ~1 Mpps.** Each punt frame
   crosses two `write()` / `read()` boundaries and a kernel TAP
   buffer; userspace overhead starts to dominate.
2. **You want a real `ethN`-like netdev** that the OS can manage
   with the standard tools (`ip`, `ethtool`, `bridge`, `tc`)
   without going through TAP-into-netns gymnastics.
3. **DMA replaces BAR-only access.** Once the FPGA grows the
   Phase 2 slow-path RX/TX DMA rings, mmap'ing them from userspace
   becomes less attractive than letting the kernel page allocator
   own the descriptor memory and dispatch via NAPI.
4. **Multi-queue + ethtool + devlink + per-queue interrupts**
   become deployment requirements.

If you don't need any of those, the userspace plane is faster to
iterate on (no kernel rebuild, fewer privileges) and keeps the
host attack surface smaller.

## Architectural outline

```
PCIe BAR / DMA descriptors
   |
   v
+--------------------------------------------------------------+
| packetwyrm.ko  (Phase 11)                                    |
|   pci_driver probe/remove                                    |
|   pcim_iomap_region(BAR0) -> CSR access                      |
|   DMA descriptor allocation (dma_alloc_coherent)             |
|   per-card NAPI instance                                     |
|   one struct net_device per logical_interface                |
|       ndo_open / ndo_stop, ndo_start_xmit (slow-path TX)     |
|       NAPI poll: pull punted frames into skbs                |
|   ethtool ops: link, stats, eeprom (SFP), pause              |
|   netlink: per-flow stats, classifier rules                  |
+--------------------------------------------------------------+
   |
   v
Linux network stack -- regular ethN devices
```

A user-space helper (or `packetwyrmd` itself) still owns YAML
parsing, flow compilation, and stats aggregation; it talks to the
driver via netlink rather than a Unix-socket JSON RPC.

## Files in this tree

  - `kernel/packetwyrm.c` &mdash; Phase 11 *skeleton* PCI driver:
    probe / remove / BAR mapping. No netdev, no DMA, no NAPI yet.
    Builds against modern kernels (>= 6.x) with the in-tree
    `pci_driver` API.
  - `kernel/Kbuild` &mdash; module build fragment.
  - `kernel/Makefile` &mdash; out-of-tree build convenience
    wrapper. Run `make -C kernel` against your running kernel's
    headers (`apt install linux-headers-$(uname -r)`).

## Build (out of tree)

```sh
sudo apt install linux-headers-$(uname -r) build-essential
cd kernel
make
sudo insmod packetwyrm.ko
sudo dmesg | tail
sudo rmmod packetwyrm
```

The skeleton matches PCI vendor / device `10ee:a502` (see
`docs/design/pci-ids.md`). A `module_param` `force_match` allows
loading against any PCI ID for development.

## What the skeleton does today

- Registers a `pci_driver` keyed on `10ee:a502`.
- On `probe()`:
  1. enables the device,
  2. requests BAR0,
  3. ioremaps it,
  4. reads the identity registers (`device_id`, `version`,
     `build_id`, `git_hash`, `capabilities`) via the same CSR
     map the userspace BAR backend uses, and logs them via
     `pci_info()`.
- On `remove()`: unmaps and disables.

This is the minimum that proves the kernel can see the same
silicon the userspace daemon sees. The rest (netdev registration,
ndo ops, NAPI, ethtool, devlink) is incremental work on top.

## Coexistence with the userspace daemon

Only one of `packetwyrm.ko` and `packetwyrmd`'s BAR backend can
own a card at a time. The skeleton's `probe()` claims BAR0 with
`pci_request_regions`; once loaded, the userspace BAR backend
refuses to open the same BDF with `PW_E_IO`. Switch back by
`rmmod`-ing the kernel module.

For mixed deployments (some cards via the kernel driver, some via
userspace), tag the device-tree / config so each card's intended
owner is clear.

## Risks

- Kernel API churn: NAPI, ethtool, devlink, page_pool, XDP all
  evolve. Targeting LTS kernels (6.6, 6.12, ...) is the sane move.
- MSI-X allocation and per-CPU IRQ affinity needs care for
  predictable latency at line rate.
- Userspace mmap of BAR0 alongside a kernel driver is allowed but
  pollutes the model; we will document the supported mode is "one
  owner at a time".
