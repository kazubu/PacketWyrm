#!/usr/bin/env bash
# Move a PacketWyrm TAP into a fresh netns, bring it up, address it,
# and launch a minimal FRR. Idempotent: existing netns is reused.
#
# Usage: sudo start-r1.sh [TAP_NAME] [NETNS]
# Defaults: tap-pw-p0-v100, r1.

set -euo pipefail

TAP=${1:-tap-pw-p0-v100}
NS=${2:-r1}
ADDR=${PW_R1_ADDR:-192.0.2.1/30}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

if ! ip link show "$TAP" >/dev/null 2>&1; then
    echo "TAP $TAP not present. Is packetwyrmd running?"
    exit 1
fi

ip netns add "$NS" 2>/dev/null || true
ip link set "$TAP" netns "$NS"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$TAP" up
ip netns exec "$NS" ip addr add "$ADDR" dev "$TAP"

# Start FRR if available. Override with PW_FRR_BIN=/path/to/frr.
FRR=${PW_FRR_BIN:-frr}
CONF="$(dirname "$0")/frr-r1.conf"
if command -v "$FRR" >/dev/null 2>&1; then
    ip netns exec "$NS" "$FRR" -d -f "$CONF" || \
        echo "FRR did not start in netns $NS (config: $CONF). The"  \
             "namespace is still set up; you can launch your routing"\
             "daemon manually."
else
    echo "frr not on PATH; namespace $NS is ready, attach your own"
    echo "daemon (e.g. bird) to $TAP at $ADDR."
fi

echo "OK: $TAP attached to netns $NS at $ADDR"
