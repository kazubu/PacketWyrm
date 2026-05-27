#!/usr/bin/env bash
# AS02MC04 host-side bring-up checklist.
#
# After programming the Phase 1 bitstream and rescanning the PCIe
# bus, this script verifies:
#   1. lspci sees a device with the AS02MC04 vendor / device ID
#   2. BAR0 is mapped, non-zero size
#   3. The first eight 32-bit words of BAR0 contain the expected
#      identity registers (device_id, version, build_id, git_hash,
#      capabilities, num_local_ports, ...)
#
# Run as root; requires `lspci`, `setpci`, `pcimem` (or falls back to
# /sys/bus/pci/devices/<bdf>/resource0 + a tiny dd).

set -euo pipefail

VENDOR=${PW_VENDOR_ID:-1af4}
DEVICE=${PW_DEVICE_ID:-a502}
EXPECTED_DEVICE_REG=${PW_EXPECTED_DEVICE_REG:-0xA502BEEF}

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (raw PCIe access required)"

say "1. searching for ${VENDOR}:${DEVICE} via lspci ..."
BDF=$(lspci -nd "${VENDOR}:${DEVICE}" | awk '{print $1}' | head -n1)
[ -n "$BDF" ] || die "no AS02MC04 / PacketWyrm card found via lspci"
say "   found at $BDF"

# Normalise to 0000:bb:dd.f
BDF_FULL=$(ls /sys/bus/pci/devices/ | grep -E "${BDF//\./\\.}\$" | head -n1)
[ -n "$BDF_FULL" ] || die "could not resolve sysfs path for $BDF"
SYS=/sys/bus/pci/devices/$BDF_FULL

say "2. checking BAR0 ..."
RESOURCE=$SYS/resource0
[ -e "$RESOURCE" ] || die "$RESOURCE missing — BAR0 not allocated by the kernel"
BAR_SIZE=$(stat -c %s "$RESOURCE")
say "   BAR0 size = $BAR_SIZE bytes"
[ "$BAR_SIZE" -ge 4096 ] || die "BAR0 unexpectedly small"

say "3. reading identity registers from BAR0 ..."
HEX=$(dd if="$RESOURCE" bs=4 count=8 status=none | od -An -tx4)
# od outputs space-separated little-endian 32-bit words in host order
read -r DEV VER BUILD GIT CAPS NPORTS NFLOWS NIFS <<EOF
$HEX
EOF
printf '   device_id=0x%s version=0x%s build=0x%s git=0x%s\n' \
    "$DEV" "$VER" "$BUILD" "$GIT"
printf '   caps=0x%s nports=0x%s nflows=0x%s nifs=0x%s\n' \
    "$CAPS" "$NPORTS" "$NFLOWS" "$NIFS"

EXPECTED_LOW=${EXPECTED_DEVICE_REG#0x}
if [ "${DEV,,}" != "${EXPECTED_LOW,,}" ]; then
    die "device_id mismatch: got 0x$DEV, expected $EXPECTED_DEVICE_REG"
fi

say "OK: AS02MC04 Phase 1 bring-up checks passed."
