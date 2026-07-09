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
# Pick free ports: a fixed port collides with long-running dev/lab proxyds
# on shared hosts (e.g. one was parked on 18443); the old code then silently
# talked to the STALE instance and failed with "daemon unreachable".
pick_port() {  # base
    local p
    for p in $(seq "$1" "$(($1 + 20))"); do
        if ! ss -tln 2>/dev/null | grep -q ":$p "; then echo "$p"; return 0; fi
    done
    return 1
}
PLAIN_PORT=$(pick_port 18080) || { echo "no free plain port"; exit 2; }
TLS_PORT=$(pick_port 18445)   || { echo "no free TLS port"; exit 2; }

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

# Wait until a just-started proxyd actually serves GET / (cert-gen + bind +
# first accept can take a moment; a fixed sleep raced intermittently).
wait_proxyd() {  # scheme port
    for _ in $(seq 1 50); do
        local body; body=$(curl -s${3:-} "$1://127.0.0.1:$2/" 2>/dev/null)
        grep -q PacketWyrm <<<"$body" && return 0
        sleep 0.1
    done
    return 1
}

# proxyd requires this custom header on POST /api/rpc (CSRF defence); every
# RPC below must send it. Missing header / bad Host => 403 (tested below).
PWH='X-PW-Request: 1'

pass=0; fail=0
check() {
    local name=$1 expected=$2 got=$3
    # here-string, not `echo | grep -q`: grep -q exits on first match, and under
    # `set -o pipefail` echo then takes SIGPIPE (141) on a large body, failing
    # the pipeline even though it matched (intermittent, size-dependent).
    if grep -qE "$expected" <<<"$got"; then
        echo "[ ok ] $name"; pass=$((pass+1))
    else
        echo "[FAIL] $name: expected /$expected/, got: ${got:0:200}"; fail=$((fail+1))
    fi
}
check_exit() {  # name, expected_rc, actual_rc
    if [ "$2" = "$3" ]; then echo "[ ok ] $1"; pass=$((pass+1));
    else echo "[FAIL] $1: expected exit $2, got $3"; fail=$((fail+1)); fi
}

# --- gateway startup safeguards (no daemon needed for these) ---
# (rc=0; cmd || rc=$?  keeps `set -e` from aborting on the expected failure.)
# non-IPv4 --listen must be rejected (not silently bound to 0.0.0.0).
rc=0; "$PROXYD" --listen ::1:9 --socket "$SOCK" --no-tls >/dev/null 2>&1 || rc=$?
check_exit "reject IPv6 --listen" 2 "$rc"
rc=0; "$PROXYD" --listen localhost:9 --socket "$SOCK" --no-tls >/dev/null 2>&1 || rc=$?
check_exit "reject hostname --listen" 2 "$rc"
# fail-closed: non-loopback bind against an unreachable daemon must refuse.
rc=0; "$PROXYD" --listen 0.0.0.0:9 --socket /no/such.sock --no-tls >/dev/null 2>&1 || rc=$?
check_exit "fail-closed non-loopback + unreachable daemon" 1 "$rc"

# --config: a bad key must be rejected (exit 2), proving the file is parsed.
cat > "$WORK/bad.yaml" <<EOF
listen: 127.0.0.1:$PLAIN_PORT
bogus_key: 1
EOF
rc=0; "$PROXYD" --config "$WORK/bad.yaml" --socket "$SOCK" --no-tls >/dev/null 2>&1 || rc=$?
check_exit "reject unknown config key" 2 "$rc"

# --- plaintext gateway (loopback), configured entirely via a --config FILE ---
# Exercises the config-file path: listen / socket / no_tls / allowed_hosts all
# come from the file (no CLI flags). The downstream Host: pw.example.test check
# then also proves allowed_hosts was honored from the file.
cat > "$WORK/proxyd.yaml" <<EOF
# proxyd config (e2e)
listen: "127.0.0.1:$PLAIN_PORT"
socket: "$SOCK"
no_tls: true
allowed_hosts: "pw.example.test"
EOF
"$PROXYD" --config "$WORK/proxyd.yaml" > "$WORK/px_plain.log" 2>&1 &
PXP=$!
wait_proxyd http $PLAIN_PORT || { echo "plaintext proxyd not ready"; cat "$WORK/px_plain.log"; exit 1; }

check "GET / serves GUI" 'PacketWyrm' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/)"
check "404 unknown path" '404' \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PLAIN_PORT/nope)"
# Multi-file asset tree (index.html + css/ + js/*.mjs, served same-origin).
check "GET / loads the JS module" '/js/main.mjs' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/)"
check "GET /css/app.css served" '200' \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PLAIN_PORT/css/app.css)"
check "css has correct content-type" 'text/css' \
    "$(curl -s -D - -o /dev/null http://127.0.0.1:$PLAIN_PORT/css/app.css)"
check "GET /js/main.mjs served" '200' \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PLAIN_PORT/js/main.mjs)"
check "js module has js content-type" 'text/javascript' \
    "$(curl -s -D - -o /dev/null http://127.0.0.1:$PLAIN_PORT/js/main.mjs)"
check "query string stripped before lookup" '200' \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PLAIN_PORT/js/main.mjs?v=1")"
check "response carries CSP header" 'script-src' \
    "$(curl -s -D - -o /dev/null http://127.0.0.1:$PLAIN_PORT/)"
check "vendored js-yaml served" '200' \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PLAIN_PORT/vendor/js-yaml.min.js)"
check "GET / pulls in js-yaml" '/vendor/js-yaml.min.js' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/)"
check "path traversal 404 (no filesystem)" '404' \
    "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$PLAIN_PORT/../etc/passwd")"
# secret required: without it we get unauthorized, with it we get version.
check "rpc without secret -> unauthorized" 'unauthorized' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"version"}')"
check "rpc with secret -> version" '"version"' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
check "rpc cards relayed" '"backend":"fake"' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"cards","secret":"e2e-secret"}')"

# --- CSRF defences on /api/rpc ---
# missing X-PW-Request header -> 403 (a cross-origin "simple" POST from a
# web page carries no custom header; a DNS-rebound one carries a bad Host).
check "rpc without X-PW-Request -> 403" '^403$' \
    "$(curl -s -o /dev/null -w '%{http_code}' \
        http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
check "rpc without X-PW-Request error body" 'X-PW-Request' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
check "rpc with bad Host -> 403" '^403$' \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "$PWH" \
        -H 'Host: evil.example.com' \
        http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
# Host values that must be accepted: localhost (builtin, any port) and the
# --allowed-host name.
check "rpc with Host localhost ok" '"version"' \
    "$(curl -s -H "$PWH" -H 'Host: localhost:9999' \
        http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
check "rpc with --allowed-host name ok" '"version"' \
    "$(curl -s -H "$PWH" -H 'Host: pw.example.test' \
        http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"version","secret":"e2e-secret"}')"
# GET / (GUI asset) must NOT require the header (bare browser navigation).
check "GET / needs no header" 'PacketWyrm' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/)"

# config.get_raw: returns the env file text with the secret value redacted.
graw=$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc \
        -d '{"rpc":"config.get_raw","secret":"e2e-secret"}')
check "config.get_raw secret_set" '"secret_set":true' "$graw"
check "config.get_raw redacts secret" '\*\*\*' "$graw"
if grep -q 'e2e-secret' <<<"$graw"; then
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
r = urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:%s/api/rpc" % port, data=body,
    headers={"X-PW-Request": "1"}))
print(r.read().decode())
PY
)
check "config.save ok" '"ok":true' "$saved"
check "config.save no restart (unchanged)" '"restart_required":false' "$saved"

# HIGH regression: saving the *redacted* get_raw view (secret == "***") must
# NOT overwrite the real secret on disk (would lock the operator out).
redacted=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["yaml"])' <<<"$graw")
python3 - "$PLAIN_PORT" <<PY >/dev/null
import json, sys, urllib.request
body = json.dumps({"rpc":"config.save","secret":"e2e-secret",
                   "yaml":$(python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' <<<"$redacted")}).encode()
urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:%s/api/rpc" % sys.argv[1], data=body,
    headers={"X-PW-Request": "1"})).read()
PY
if grep -q 'secret: "e2e-secret"' "$CFG"; then
    echo "[ ok ] config.save preserves secret on redacted save"; pass=$((pass+1))
else
    echo "[FAIL] config.save clobbered the secret (redacted '***' written to disk)"; fail=$((fail+1))
fi

# /proxyd/version (gateway's own version endpoint)
check "proxyd version endpoint" '"version"' \
    "$(curl -s http://127.0.0.1:$PLAIN_PORT/proxyd/version)"
# ports.stats (per-port MAC counters for pps/bps + FCS + rx_unmatched)
pstats=$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"ports.stats","secret":"e2e-secret"}')
check "ports.stats per-port counters" '"rx_frames"' "$pstats"
# rx_unmatched (classifier no-match, informational -- NOT a drop; distinct field)
check "ports.stats has rx_unmatched" '"rx_unmatched"' "$pstats"

# tap.stats relay (host-plane TAP status; fake backend has no TAPs -> empty array,
# but the RPC must dispatch and return the taps envelope through the relay).
check "tap.stats relayed" '"taps"' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"tap.stats","secret":"e2e-secret"}')"

# flow.preview: build the generated frame for an inline (edited-but-unloaded)
# flow -- the GUI's frame-preview path. Returns hex + a decoded summary.
prev=$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"flow.preview","secret":"e2e-secret","seq":5,"yaml":"flows:\n  - id: 7\n    name: prev\n    tx_global_port: 0\n    rx_global_port: 1\n    l2: { src_mac: \"02:00:00:00:00:01\", dst_mac: \"02:00:00:00:00:02\", vlan: 100 }\n    ipv4: { src: \"10.0.0.1\", dst: \"10.0.0.2\", ttl: 64 }\n    udp: { src_port: 1000, dst_port: 2000 }\n    traffic: { frame_len: 128, rate_bps: 1000000000, insert_sequence: true, insert_timestamp: true }"}')
check "flow.preview returns hex" '"hex":"[0-9a-f]' "$prev"
check "flow.preview magic A5027E57 present" 'a5027e57' "$prev"
check "flow.preview decode l3 ipv4" '"l3":"ipv4"' "$prev"

# config.load with a GUI-shaped test config (mirrors the Flows-editor YAML
# emitter: v4/udp + v6/tcp, vlan, measurements). Guards emitter/parser drift.
gui_yaml=$(cat <<'YML'
flows:
  - id: 1
    tx_global_port: 0
    rx_global_port: 1
    l2:
      src_mac: "02:a5:02:00:00:01"
      dst_mac: "02:a5:02:00:00:02"
      vlan: 100
    ipv4:
      src: "192.0.2.1"
      dst: "192.0.2.2"
      ttl: 64
    udp:
      src_port: 49152
      dst_port: 50001
    traffic:
      frame_len: 512
      rate_bps: 1000000000
      payload: "increment"
      insert_sequence: true
      insert_timestamp: true
    measurements:
      loss: true
      latency: true
      jitter: true
  - id: 2
    name: "v6tcp"
    tx_global_port: 0
    rx_global_port: 1
    l2:
      src_mac: "02:a5:02:00:00:03"
      dst_mac: "02:a5:02:00:00:04"
    ipv6:
      src: "2001:db8::1"
      dst: "2001:db8::2"
      hop_limit: 64
    tcp:
      src_port: 40000
      dst_port: 80
      flags: 0x02
    traffic:
      frame_len: 512
      rate_bps: 1000000000
      payload: "increment"
      insert_sequence: true
      insert_timestamp: true
    measurements:
      loss: true
      latency: true
      jitter: true
  - id: 3
    name: "advanced"
    tx_global_port: 0
    rx_global_port: 1
    l2:
      src_mac: "02:a5:02:00:00:05"
      dst_mac: "02:a5:02:00:00:06"
    ipv4:
      src: "192.0.2.5"
      dst: "192.0.2.6"
      ttl: 64
    udp:
      src_port: 49152
      dst_port: 50003
    traffic:
      frame_len: 512
      rate_bps: 1000000000
      payload: "increment"
      insert_sequence: true
      insert_timestamp: true
    measurements:
      loss: true
      latency: true
      jitter: true
    match:
      udp_dst: 0xff00
      ipv4_dst: 0xffffff00
    modifiers:
      src_ipv4: { mode: "increment", mask: 0x0000ffff }
      udp_src: { mode: "random", mask: 0x00ff }
      src_ipv6: { mode: "increment", mask: "ffff::" }
    encap:
      type: "ipip"
      outer:
        ipv4: { src: "10.0.0.1", dst: "10.0.0.2", ttl: 32, dscp: 0 }
    rx_expect: "tunneled"
YML
)
loaded=$(python3 - "$PLAIN_PORT" <<PY
import json, sys, urllib.request
body = json.dumps({"rpc":"config.load","secret":"e2e-secret",
                   "yaml":$(python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' <<<"$gui_yaml")}).encode()
r = urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:%s/api/rpc" % sys.argv[1], data=body,
    headers={"X-PW-Request": "1"}))
print(r.read().decode())
PY
)
check "config.load GUI YAML (v4/udp + v6/tcp + advanced encap/mod/match)" '"n_flows":3' "$loaded"
# config.get_test returns the just-loaded test config so the GUI can edit it.
gettest=$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc \
    -d '{"rpc":"config.get_test","secret":"e2e-secret"}')
check "config.get_test loaded" '"loaded":true' "$gettest"
check "config.get_test has the loaded flow" 'v6tcp' "$gettest"
# Structured flows for form population (Load current -> form): the advanced
# flow (id 3) must round-trip its modifiers (key "mods", not "modifiers"),
# match, and encap.
check "config.get_test structured flows"  '"flows":\[' "$gettest"
check "config.get_test mods key (not modifiers)" '"mods":' "$gettest"
check "config.get_test modifier increment"  '"increment"' "$gettest"
check "config.get_test encap type"  '"type":"ipip"' "$gettest"
# per-flow enable state (for the GUI Started/Stopped indicator + toggle)
check "flows enabled field" '"enabled"' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"flows","secret":"e2e-secret"}')"

# rate_pps must round-trip as rate_mode/rate (not collapse to rate_bps:0, which
# would make Load current -> Apply emit invalid YAML).
curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"config.load","secret":"e2e-secret","yaml":"flows:\n  - id: 5\n    tx_global_port: 0\n    rx_global_port: 1\n    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n    udp: { src_port: 1, dst_port: 2 }\n    traffic: { frame_len: 128, rate_pps: 148809 }\n    measurements: { loss: true }\n"}' >/dev/null
check "config.get_test rate_pps round-trip" '"rate_mode":"pps"' \
    "$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"config.get_test","secret":"e2e-secret"}')"

# Raw frame template (eth/L2RAW) round-trips: config.get_test reports the
# frame_template + ethertype so the GUI form re-populates them.
curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"config.load","secret":"e2e-secret","yaml":"flows:\n  - id: 6\n    classify: header\n    tx_global_port: 0\n    rx_global_port: 1\n    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\", ethertype: 0x88b5 }\n    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n    udp: { src_port: 1, dst_port: 2 }\n    traffic: { frame_len: 64, rate_bps: 1000000000, frame_template: eth }\n"}' >/dev/null
gtmpl=$(curl -s -H "$PWH" http://127.0.0.1:$PLAIN_PORT/api/rpc -d '{"rpc":"config.get_test","secret":"e2e-secret"}')
check "config.get_test frame_template round-trip" '"frame_template":"eth"' "$gtmpl"
check "config.get_test ethertype round-trip" '"ethertype":"0x88b5"' "$gtmpl"
kill "$PXP" 2>/dev/null || true; PXP=""

# --- TLS gateway (loopback, self-signed) ---
"$PROXYD" --listen 127.0.0.1:$TLS_PORT --socket "$SOCK" \
    > "$WORK/px_tls.log" 2>&1 &
PXT=$!
wait_proxyd https $TLS_PORT k || { echo "TLS proxyd not ready"; cat "$WORK/px_tls.log"; exit 1; }

check "TLS self-signed startup" 'self-signed certificate' "$(cat "$WORK/px_tls.log")"
check "TLS GET /" 'PacketWyrm' "$(curl -sk https://127.0.0.1:$TLS_PORT/)"
check "TLS rpc version" '"version"' \
    "$(curl -sk -H "$PWH" https://127.0.0.1:$TLS_PORT/api/rpc \
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
