#!/usr/bin/env bash
# AS02MC04 host-side bring-up check via VFIO -- for hosts with kernel
# lockdown / Secure Boot, where setpci and sysfs resource mmap are
# blocked but VFIO is permitted.
#
# Binds the card to vfio-pci, then reads the PacketWyrm identity
# registers through an IOMMU-mediated BAR mmap (scripts/vfio_read_csr.py).
#
#   sudo fpga/as02mc04/scripts/bringup-check-vfio.sh
#
# Override the target with PW_VENDOR_ID / PW_DEVICE_ID.
set -euo pipefail

VENDOR=${PW_VENDOR_ID:-10ee}
DEVICE=${PW_DEVICE_ID:-a502}
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (VFIO bind + device fd)"

here=$(cd "$(dirname "$0")" && pwd)

say "1. locating ${VENDOR}:${DEVICE} ..."
BDF=$(lspci -nd "${VENDOR}:${DEVICE}" | awk '{print $1}' | head -n1)
[ -n "$BDF" ] || die "card not found via lspci"
DEV=$(ls -d /sys/bus/pci/devices/*"${BDF}" | head -n1)
DEV=$(basename "$DEV")
say "   $DEV"

GROUP=$(basename "$(readlink -f /sys/bus/pci/devices/$DEV/iommu_group)")
say "   IOMMU group $GROUP"

say "2. binding $DEV to vfio-pci ..."
modprobe vfio-pci
# The driver symlink only exists when a driver is actually bound.
if [ -L "/sys/bus/pci/devices/$DEV/driver" ]; then
    cur=$(basename "$(readlink -f /sys/bus/pci/devices/$DEV/driver)")
else
    cur=none
fi
if [ "$cur" = "vfio-pci" ]; then
    say "   already bound to vfio-pci"
else
    [ "$cur" = "none" ] || echo "$DEV" > "/sys/bus/pci/devices/$DEV/driver/unbind"
    echo vfio-pci > "/sys/bus/pci/devices/$DEV/driver_override"
    echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/bind
    say "   bound (was: $cur)"
fi

[ -e "/dev/vfio/$GROUP" ] || die "/dev/vfio/$GROUP missing after bind"

say "3. reading identity registers via VFIO ..."
python3 "$here/vfio_read_csr.py" "$DEV" "$GROUP"
