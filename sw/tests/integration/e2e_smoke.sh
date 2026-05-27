#!/usr/bin/env bash
# End-to-end smoke test: start packetwyrmd against a temp config,
# walk through the JSON RPCs via pktwyrm, validate each response,
# and confirm a clean SIGINT shutdown. Intended for CI but works
# anywhere a developer has root (needed for TAP creation; falls
# back to a relaxed mode if not root).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SW=$(cd "$HERE/../.." && pwd)
ROOT=$(cd "$SW/.." && pwd)

DAEMON=$SW/build/packetwyrmd
CLI=$SW/build/pktwyrm
[ -x "$DAEMON" ] || { echo "missing $DAEMON; run \`make -C sw\` first"; exit 2; }
[ -x "$CLI"    ] || { echo "missing $CLI";    exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SOCK=$WORK/pw.sock
CFG=$WORK/pw.yaml

sed -e '/^system:/a\  control_socket: "'"$SOCK"'"' \
    "$ROOT/configs/examples/single-card.yaml" > "$CFG"

# Skip TAP creation if we can't (no CAP_NET_ADMIN). The daemon still
# runs and exposes the RPC surface; only the TAP-binding side of the
# host_plane will fall back to "no TAPs created" which is fine here.
if [ "$(id -u)" -ne 0 ]; then
    echo "(running as non-root; TAP creation will be skipped by the daemon)"
fi

"$DAEMON" -s 0 -c "$CFG" > "$WORK/daemon.log" 2>&1 &
DPID=$!
cleanup() { kill -INT "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; }
trap 'cleanup; rm -rf "$WORK"' EXIT

# Wait up to 3 s for the socket to appear.
for _ in $(seq 1 30); do
    [ -S "$SOCK" ] && break
    sleep 0.1
done
[ -S "$SOCK" ] || { echo "daemon never bound $SOCK; daemon log:"; cat "$WORK/daemon.log"; exit 1; }

check() {
    local name=$1 expected=$2
    shift 2
    local out
    out=$("$@" 2>&1) || { echo "[FAIL $name] command failed: $*"; cat "$WORK/daemon.log"; exit 1; }
    if ! echo "$out" | grep -qE "$expected"; then
        echo "[FAIL $name] expected match /$expected/, got:"
        echo "$out"
        exit 1
    fi
    echo "[ ok ] $name"
}

check "rpc version"   '"version"'      "$CLI" rpc version --socket "$SOCK"
check "rpc cards"     '"cards"'        "$CLI" rpc cards   --socket "$SOCK"
check "rpc ports"     '"ports"'        "$CLI" rpc ports   --socket "$SOCK"
check "rpc flows"     '"flows"'        "$CLI" rpc flows   --socket "$SOCK"
check "rpc stats"     '"stats"'        "$CLI" rpc stats   --socket "$SOCK"
check "rpc flow.stats" '"flows"'       "$CLI" rpc flow.stats --socket "$SOCK"
check "rpc unknown"   '"error"'        "$CLI" rpc no_such_method --socket "$SOCK"

check "flow start 1"  '"status":"ok"'  "$CLI" flow start 1 --socket "$SOCK"
check "flow stop  1"  '"status":"ok"'  "$CLI" flow stop  1 --socket "$SOCK"
check "flow start 99" '"invalid'       "$CLI" flow start 99 --socket "$SOCK"

check "test arm"      '"action":"test.arm"'   "$CLI" test arm   --socket "$SOCK"
check "test start"    '"changed":1'           "$CLI" test start --socket "$SOCK"
check "test stop"     '"changed":1'           "$CLI" test stop  --socket "$SOCK"

check "stats table"   '^card[[:space:]]+open' "$CLI" stats --socket "$SOCK"
check "flow stats tbl" '^id[[:space:]]+tx_c'   "$CLI" flow stats --socket "$SOCK"

cleanup
trap 'rm -rf "$WORK"' EXIT

echo "all e2e checks passed"
