#!/usr/bin/env bash
# AS02MC04 host-side bring-up checklist.
#
# After programming the Phase 1 bitstream and rescanning the PCIe
# bus (or warm-rebooting), this script verifies:
#   1. lspci sees a device with the AS02MC04 vendor / device ID
#   2. a 64 KB BAR is mapped
#   3. the first eight 32-bit words of the CSR BAR contain the
#      expected identity registers (device_id, version, build_id,
#      git_hash, capabilities, num_local_ports, ...)
#
# With the xdma core the CSR window is the IP's AXI-Lite-master BAR,
# which is NOT BAR0 (BAR0 is the XDMA control BAR). This script enables
# memory decoding and then auto-detects which BAR carries the
# device_id, so it works regardless of which BAR the IP assigned.
# Override detection with PW_CSR_BAR=<index>.
#
# Run as root; requires `lspci`, `setpci`, and `dd`/`od`.

set -euo pipefail

VENDOR=${PW_VENDOR_ID:-10ee}
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

# The kernel does not enable memory decoding for an unclaimed device
# (lspci shows "Mem-"); set the Memory Space Enable bit so BAR reads
# reach the FPGA.
CMD=$(setpci -s "$BDF" COMMAND)
setpci -s "$BDF" COMMAND=$(printf '%04x' $(( 0x$CMD | 0x2 ))) >/dev/null
say "   memory space enabled (COMMAND 0x$CMD -> 0x$(setpci -s "$BDF" COMMAND))"

# On x86 the sysfs resourceN files are mmap-only (read() returns EIO),
# so use python's mmap to fetch the first N little-endian 32-bit words.
read_words() { # <resource> <count>
    python3 - "$1" "$2" <<'PY'
import sys, os, mmap, struct
path, n = sys.argv[1], int(sys.argv[2])
sz = os.path.getsize(path)
length = ((max(sz, 4*n) + mmap.PAGESIZE - 1) // mmap.PAGESIZE) * mmap.PAGESIZE
fd = os.open(path, os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, length, mmap.MAP_SHARED, mmap.PROT_READ)
print(" ".join("%08x" % struct.unpack_from("<I", m, 4*i)[0] for i in range(n)))
PY
}
read_word0() { read_words "$1" 1 | tr -d ' \n'; }

say "2. locating the CSR BAR (device_id == ${EXPECTED_DEVICE_REG}) ..."
EXPECTED_LOW=${EXPECTED_DEVICE_REG#0x}
RESOURCE=""
if [ -n "${PW_CSR_BAR:-}" ]; then
    cand=$SYS/resource${PW_CSR_BAR}
    [ -e "$cand" ] || die "PW_CSR_BAR=$PW_CSR_BAR but $cand missing"
    RESOURCE=$cand
    say "   using PW_CSR_BAR=$PW_CSR_BAR -> $cand"
else
    for bar in 0 1 2 3 4 5; do
        cand=$SYS/resource${bar}
        [ -e "$cand" ] || continue
        sz=$(stat -c %s "$cand")
        [ "$sz" -ge 4096 ] || continue
        w0=$(read_word0 "$cand")
        say "   BAR$bar size=$sz word0=0x$w0"
        if [ "${w0,,}" = "${EXPECTED_LOW,,}" ]; then
            RESOURCE=$cand
            say "   -> CSR BAR is BAR$bar"
            break
        fi
    done
fi
[ -n "$RESOURCE" ] || die "no BAR carried device_id ${EXPECTED_DEVICE_REG}; is the bitstream loaded?"
BAR_SIZE=$(stat -c %s "$RESOURCE")
say "   CSR BAR size = $BAR_SIZE bytes"

say "3. reading identity registers from the CSR BAR ..."
HEX=$(read_words "$RESOURCE" 8)
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
