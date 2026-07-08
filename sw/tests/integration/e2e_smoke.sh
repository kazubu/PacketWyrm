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

# -F: allow the no-op fake backend (no real card on the CI/dev host; BAR open
# fails and the daemon now errors out by default without this).
# PW_FAKE_FAIL_FLAG (rising-edge, one-shot: fails only the reload STAGING commit
# so the rollback re-program succeeds) and PW_FAKE_FAIL_FLAG_STICKY (fails every
# commit while present: both staging AND rollback fail) drive the two config.load
# rollback tests below. Both absent at launch, so startup programs cleanly.
export PW_FAKE_FAIL_FLAG="$WORK/failflag"
export PW_FAKE_FAIL_FLAG_STICKY="$WORK/failflag_sticky"
"$DAEMON" -s 0 -F -c "$CFG" > "$WORK/daemon.log" 2>&1 &
DPID=$!
# Best-effort safety net for early failures only; the happy path ends with an
# explicit SIGINT + wait + exit-status assertion (see the end of this script).
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
    # Here-string, not `echo | grep -q`: grep -q exits on the first match and
    # under pipefail the echo's SIGPIPE would flake the whole check.
    if ! grep -qE "$expected" <<<"$out"; then
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

# Explicit-start default: the daemon was launched WITHOUT -a/--autostart, so a
# freshly programmed flow must be IDLE (enabled:false) -- nothing on the wire
# until an explicit test.start. Regression guard for the auto-start removal.
idle=$("$CLI" rpc flows --socket "$SOCK" 2>&1)
if grep -qE '"enabled":[[:space:]]*true' <<<"$idle"; then
    echo "[FAIL explicit-start] a flow was enabled at startup without --autostart:"
    echo "$idle"; exit 1
fi
echo "[ ok ] flows idle at startup (explicit-start default)"
# The fake backend models traffic only while a flow's generator gate is on, so
# tx_frames must be 0 before start (config.load never transmits).
txf() { "$CLI" flow stats --flow 1 --json --socket "$SOCK" 2>&1 | \
        python3 -c 'import json,sys;print(json.load(sys.stdin)["flows"][0]["tx_frames"])'; }
"$CLI" test arm --socket "$SOCK" >/dev/null 2>&1   # clears counters
[ "$(txf)" = "0" ] || { echo "[FAIL explicit-start] tx_frames nonzero before start"; exit 1; }
echo "[ ok ] no traffic before test start (tx_frames=0)"
# test start enables generation; counters must now advance.
"$CLI" test start --socket "$SOCK" >/dev/null 2>&1
check "test start enables" '"enabled":[[:space:]]*true'  "$CLI" rpc flows --socket "$SOCK"
a=$(txf); b=$(txf)
[ "$b" -gt "$a" ] 2>/dev/null || { echo "[FAIL explicit-start] tx_frames not advancing after start ($a -> $b)"; exit 1; }
echo "[ ok ] traffic flows after test start (tx_frames advancing)"
# test stop freezes: enabled false and counters stop advancing.
"$CLI" test stop --socket "$SOCK" >/dev/null 2>&1
if grep -qE '"enabled":[[:space:]]*true' <<<"$("$CLI" rpc flows --socket "$SOCK" 2>&1)"; then
    echo "[FAIL explicit-start] test stop left a flow enabled"; exit 1
fi
c=$(txf); d=$(txf)
[ "$c" = "$d" ] || { echo "[FAIL explicit-start] tx_frames still advancing after stop ($c -> $d)"; exit 1; }
echo "[ ok ] test start/stop toggles the generator run-state"
# `test run` orchestrates arm+start+wait+stop and returns PASS (exit 0) when the
# loopback flow saw rx with no loss/dup/ooo.
if "$CLI" test run --duration 300ms --socket "$SOCK" >/dev/null 2>&1; then
    echo "[ ok ] test run reports PASS on a clean loopback"
else
    echo "[FAIL] test run did not PASS on the fake loopback"; exit 1
fi

check "flow start 1"  '"status":"ok"'  "$CLI" flow start 1 --socket "$SOCK"
check "flow stop  1"  '"status":"ok"'  "$CLI" flow stop  1 --socket "$SOCK"
check "flow start 99" '"invalid'       "$CLI" flow start 99 --socket "$SOCK"

check "test arm"      '"action":"test.arm"'   "$CLI" test arm   --socket "$SOCK"
check "test start"    '"changed":1'           "$CLI" test start --socket "$SOCK"
check "test stop"     '"changed":1'           "$CLI" test stop  --socket "$SOCK"

check "stats table"   '^card[[:space:]]+open' "$CLI" stats --socket "$SOCK"
# Header gained a `path (tx->rx)` column between id and tx_frames.
check "flow stats tbl" '^id[[:space:]]+path.*tx_frames'   "$CLI" flow stats --socket "$SOCK"

# Live config reload: ship the same YAML over the socket and verify
# the daemon accepts it and re-publishes the program.
check "config.load same"   'Deployed to .* flows' "$CLI" load "$CFG" --socket "$SOCK"
check "rpc flows after"    '"flows"'              "$CLI" rpc flows --socket "$SOCK"

# A topology-different config (different card count) must be refused.
CFG2=$WORK/pw2.yaml
sed -e '/^system:/a\  control_socket: "'"$SOCK"'"' \
    "$ROOT/configs/examples/multi-card.yaml" > "$CFG2"
out2=$("$CLI" load "$CFG2" --socket "$SOCK" 2>&1 || true)
if grep -q 'topology change' <<<"$out2"; then
    echo "[ ok ] config.load topology rejected"
else
    echo "[FAIL config.load topology rejected] expected 'topology change' in:"
    echo "$out2"
    exit 1
fi

# config.load rollback preserves the prior flow-enable state (regression for the
# quiesce that used to disable the daemon's authoritative rows). Enable flow 1,
# arm a staging fault (touch the flag), reload: the stage must fail and roll back
# WITHOUT leaving flow 1 disabled.
"$CLI" flow start 1 --socket "$SOCK" >/dev/null 2>&1
before=$("$CLI" rpc flows --socket "$SOCK" 2>&1)
if ! grep -qE '"enabled":[[:space:]]*true' <<<"$before"; then
    echo "[FAIL rollback setup] flow 1 not enabled before reload:"; echo "$before"; exit 1
fi
touch "$WORK/failflag"
rb=$("$CLI" load "$CFG" --socket "$SOCK" 2>&1 || true)
if grep -q 'previous config still running' <<<"$rb"; then
    echo "[ ok ] config.load stage-fail rolled back"
else
    echo "[FAIL rollback msg] expected 'previous config still running', got:"; echo "$rb"; exit 1
fi
after=$("$CLI" rpc flows --socket "$SOCK" 2>&1)
if grep -qE '"enabled":[[:space:]]*true' <<<"$after"; then
    echo "[ ok ] config.load rollback kept the flow enabled"
else
    echo "[FAIL rollback] flow disabled after a failed reload (rollback regressed):"
    echo "$after"; exit 1
fi
rm -f "$WORK/failflag"

# When BOTH the staging AND the rollback re-program fail (real hard fault), the
# daemon must NOT claim "previous config still running" -- it reports the device
# may be out of sync. The flow view stays enabled (the quiesce never mutated it).
"$CLI" flow start 1 --socket "$SOCK" >/dev/null 2>&1
touch "$WORK/failflag_sticky"
rb2=$("$CLI" load "$CFG" --socket "$SOCK" 2>&1 || true)
if grep -qiE 'out of sync|rollback failed' <<<"$rb2"; then
    echo "[ ok ] config.load double-fault reports out-of-sync (not false success)"
else
    echo "[FAIL rollback-fail msg] expected an out-of-sync error, got:"; echo "$rb2"; exit 1
fi
after2=$("$CLI" rpc flows --socket "$SOCK" 2>&1)
if grep -qE '"enabled":[[:space:]]*true' <<<"$after2"; then
    echo "[ ok ] config.load double-fault kept the flow view enabled"
else
    echo "[FAIL rollback-fail view] flow disabled after a double-fault reload (quiesce mutated the view):"
    echo "$after2"; exit 1
fi
rm -f "$WORK/failflag_sticky"

# IPC read timeout: a client that announces a body length then stalls must not
# wedge the single-threaded daemon -- after the read timeout the daemon closes
# it and the next RPC still works. (Skipped without python3.)
if command -v python3 >/dev/null 2>&1; then
    python3 - "$SOCK" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b'\x00\x00\x00\x10')   # announce a 16-byte body, then never send it
time.sleep(12)                   # hold past the daemon's 5 s read timeout
PY
    stall_pid=$!
    sleep 0.5
    if timeout 20 "$CLI" rpc version --socket "$SOCK" 2>&1 | grep -q '"version"'; then
        echo "[ ok ] IPC read timeout: daemon recovers from a stalled client"
    else
        echo "[FAIL IPC timeout] daemon did not service a normal RPC after a stalled client"
        kill "$stall_pid" 2>/dev/null || true; exit 1
    fi
    kill "$stall_pid" 2>/dev/null || true
else
    echo "(skipping IPC-timeout test: no python3)"
fi

# A control socket that can't be created is fatal (not a silent warning): the
# daemon would be unmanageable. Point control_socket under a regular FILE so the
# bind fails (ENOTDIR), and expect a nonzero exit with a diagnostic. `timeout`
# guards against a regression that would leave the daemon running.
touch "$WORK/afile"
BADCFG="$WORK/badsock.yaml"
sed -e '/^system:/a\  control_socket: "'"$WORK/afile/pw.sock"'"' \
    "$ROOT/configs/examples/single-card.yaml" > "$BADCFG"
if timeout 10 "$DAEMON" -s 0 -F -c "$BADCFG" >"$WORK/badsock.log" 2>&1; then
    echo "[FAIL socket-fatal] daemon exited 0 despite an unusable control socket"; exit 1
else
    if grep -q 'control socket' "$WORK/badsock.log"; then
        echo "[ ok ] unusable control socket is a fatal startup failure"
    else
        echo "[FAIL socket-fatal] nonzero exit but no control-socket diagnostic:"
        cat "$WORK/badsock.log"; exit 1
    fi
fi

# Packaging consistency: packetwyrm-proxyd.service runs as User=packetwyrm and
# connects to the daemon's 0660 root:packetwyrm control socket, so the sysusers
# file must actually create that USER (a bare group would fail the unit with
# "User packetwyrm not found" and leave the gateway unable to reach the socket).
SYSU="$ROOT/packaging/packetwyrm.sysusers"
PROXU=$(grep -E '^User=' "$ROOT/packaging/packetwyrm-proxyd.service" | head -1 | cut -d= -f2)
if [ -n "$PROXU" ] && ! grep -qE "^u[[:space:]]+$PROXU([[:space:]]|\$)" "$SYSU"; then
    echo "[FAIL packaging] proxyd User=$PROXU is not created as a user in $SYSU"; exit 1
fi
echo "[ ok ] packaging: proxyd User is created by sysusers"

# Clean-shutdown check (the header advertises it): SIGINT the daemon, reap it,
# and assert it exited 0 (packetwyrmd's on_signal sets g_stop and main returns
# 0). A daemon that segfaults or errors out on shutdown must fail the test, so
# don't route this through the best-effort cleanup().
kill -INT "$DPID"
dstatus=0
wait "$DPID" || dstatus=$?
if [ "$dstatus" -ne 0 ]; then
    echo "[FAIL shutdown] daemon exit status $dstatus after SIGINT (want 0); daemon log:"
    cat "$WORK/daemon.log"
    exit 1
fi
echo "[ ok ] daemon clean SIGINT shutdown (exit 0)"
trap 'rm -rf "$WORK"' EXIT

echo "all e2e checks passed"
