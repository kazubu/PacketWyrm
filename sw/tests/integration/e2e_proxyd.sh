#!/usr/bin/env bash
# End-to-end test for packetwyrm-proxyd: start a fake-backend daemon,
# start the gateway against its socket, and exercise the HTTPS -> /api/rpc
# -> daemon relay plus static asset serving. Works without root or real
# hardware (fake backend).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SW=$(cd "$HERE/../.." && pwd)
ROOT=$(cd "$SW/.." && pwd)

DAEMON=$SW/build/packetwyrmd
PROXYD=$SW/build/packetwyrm-proxyd
CLI=$SW/build/pktwyrm
for b in "$DAEMON" "$PROXYD"; do
    [ -x "$b" ] || { echo "missing $b; run \`make -C sw\` first"; exit 2; }
done
command -v curl >/dev/null || { echo "curl required"; exit 2; }

WORK=$(mktemp -d)
SOCK=$WORK/pw.sock
CFG=$WORK/pw.yaml
PLAIN_PORT=18080
TLS_PORT=18443

# Inject a control_socket + a secret into the env config so we exercise
# the secret-forwarding path too.
sed -e '/^system:/a\  control_socket: "'"$SOCK"'"\n  secret: "e2e-secret"' \
    "$ROOT/configs/examples/single-card.yaml" > "$CFG"

"$DAEMON" -s 0 -F -c "$CFG" > "$WORK/daemon.log" 2>&1 &
DPID=$!
PXP="" ; PXT=""
cleanup() {
    [ -n "$PXP" ] && kill "$PXP" 2>/dev/null || true
    [ -n "$PXT" ] && kill "$PXT" 2>/dev/null || true
    kill "$DPID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "daemon never bound $SOCK"; cat "$WORK/daemon.log"; exit 1; }

pass=0; fail=0
check() {
    local name=$1 expected=$2 got=$3
    if echo "$got" | grep -qE "$expected"; then
        echo "[ ok ] $name"; pass=$((pass+1))
    else
        echo "[FAIL] $name: expected /$expected/, got: $got"; fail=$((fail+1))
    fi
}

# --- plaintext gateway (loopback) ---
"$PROXYD" --listen 127.0.0.1:$PLAIN_PORT --socket "$SOCK" --no-tls \
    > "$WORK/px_plain.log" 2>&1 &
PXP=$!
sleep 0.4

check "GET / serves GUI" 'PacketWyrm' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/)"
check "404 unknown path" '404' \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PLAIN_PORT/nope)"
# secret required: without it we get unauthorized, with it we get version.
check "rpc without secret -> unauthorized" 'unauthorized' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"version"}')"
check "rpc with secret -> version" '"version"' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
check "rpc cards relayed" '"backend":"fake"' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"cards","secret":"e2e-secret"}')"

# config.get_raw: returns the env file text with the secret value redacted.
graw=$(curl -s http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"config.get_raw","secret":"e2e-secret"}')
check "config.get_raw secret_set" '"secret_set":true' "$graw"
check "config.get_raw redacts secret" '\*\*\*' "$graw"
if echo "$graw" | grep -q 'e2e-secret'; then
    echo "[FAIL] config.get_raw leaked the secret value"; fail=$((fail+1))
else
    echo "[ ok ] config.get_raw does not leak secret"; pass=$((pass+1))
fi

# config.save: re-save the current (unchanged) env file -> ok, no restart.
# (Uses the real $CFG text, not the redacted get_raw output.)
saved=$(python3 - "$PLAIN_PORT" "$CFG" <<'PY'
import json, sys, urllib.request
port, cfg = sys.argv[1], sys.argv[2]
body = json.dumps({"rpc": "config.save", "secret": "e2e-secret",
                   "yaml": open(cfg).read()}).encode()
r = urllib.request.urlopen("http://127.0.0.1:%s/api/rpc" % port, data=body)
print(r.read().decode())
PY
)
check "config.save ok" '"ok":true' "$saved"
check "config.save no restart (unchanged)" '"restart_required":false' "$saved"
kill "$PXP" 2>/dev/null || true; PXP=""

# --- TLS gateway (loopback, self-signed) ---
"$PROXYD" --listen 127.0.0.1:$TLS_PORT --socket "$SOCK" \
    > "$WORK/px_tls.log" 2>&1 &
PXT=$!
sleep 0.5

check "TLS self-signed startup" 'self-signed certificate' "$(cat "$WORK/px_tls.log")"
check "TLS GET /" 'PacketWyrm' "$(curl -sk https://127.0.0.1:$TLS_PORT/)"
check "TLS rpc version" '"version"' \
    "$(curl -sk https://127.0.0.1:$TLS_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"

# pktwyrm --host over HTTPS (remote CLI). 2>/dev/null drops the one-time
# "without certificate verification" notice on stderr.
if [ -x "$CLI" ]; then
    check "pktwyrm --host rpc version" '"version"' \
        "$(PACKETWYRM_SECRET=e2e-secret "$CLI" --host 127.0.0.1:$TLS_PORT \
            rpc version 2>/dev/null)"
    check "pktwyrm --host rpc cards" '"backend":"fake"' \
        "$("$CLI" --host 127.0.0.1:$TLS_PORT --secret e2e-secret \
            rpc cards 2>/dev/null)"
    check "pktwyrm --host without secret -> unauthorized" 'unauthorized' \
        "$("$CLI" --host 127.0.0.1:$TLS_PORT rpc version 2>/dev/null)"
fi
kill "$PXT" 2>/dev/null || true; PXT=""

echo "proxyd e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
