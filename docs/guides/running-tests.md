# Running a test

PacketWyrm uses an **explicit-start** model: programming a config does not put
traffic on the wire. The lifecycle is:

```
load  →  test start  →  (measure)  →  test stop
```

## 1. Load a config

`pktwyrm load` deploys a config to the running daemon (see
[configuration.md](configuration.md) for the file):

```sh
pktwyrm load flows.yaml
```

`load` deploys by default. To only validate a file offline (no daemon, no
deploy), use `pktwyrm load flows.yaml --check`. After a load the flows are
programmed but **idle** — `pktwyrm rpc flows` shows `enabled: false` and no
traffic flows.

## 2. Start traffic

```sh
pktwyrm test start      # enable every flow's generator + clear counters
```

`test start` also re-baselines the measurement counters (and re-primes the
cross-card latency correction), so a run begins from a clean zero. To run a
single flow, use `pktwyrm flow start <id>`.

`test stop` freezes generation (counters stay readable). `test arm` re-pushes
the program and clears counters **without** changing the run state — use it to
re-baseline mid-run.

## 3. Read the results

```sh
pktwyrm flow stats               # per-flow tx/rx, loss, dup, reorder, latency
pktwyrm flow stats --watch 1000  # refresh every second (top-like)
pktwyrm latency                  # per-flow one-way latency min/avg/max
pktwyrm hist latency --flow 1    # latency histogram for a flow
pktwyrm stats                    # per-card host-plane / port counters
```

A clean run shows `lost=0 dup=0 reord=0` with `rx_frames` tracking `tx_frames`.
Latency and jitter columns read `-` until packets have actually been received
(no traffic ⇒ no measurement). Add `--json` to any of these for scripting — the
JSON is the stable, machine-readable contract; the pretty tables are for humans
and may change.

## One-shot: `test run`

For CI or a quick check, `test run` does the whole loop and returns a verdict:

```sh
pktwyrm test run --duration 10s
```

It arms, starts, waits, stops, and prints a per-flow PASS/FAIL table. It exits
**0** if every measured flow received traffic with no loss/dup/reorder, **1** on
FAIL, **2** on error — so it drops straight into a pipeline. Durations accept
`s` / `ms` / `m` suffixes.

## Preview the generated packets

Before (or without) sending anything, decode and hex-dump the exact frame a
flow's generator emits:

```sh
pktwyrm flow preview flows.yaml --flow 1
pktwyrm flow preview flows.yaml --flow 1 --seq 5   # packet #5 (shows modifiers)
```

Per-packet field **modifiers** (incrementing/random IPs, ports, MACs, …) are
applied for the given `--seq`, so stepping `--seq` shows the same variation the
hardware puts on the wire. The Web GUI has the same preview with a live seq box
(see [web-gui.md](web-gui.md)).

## Cross-card tests

For a two-card setup (traffic leaves one card and is measured on another), the
daemon runs a J5-GPIO time-sync servo so one-way latency is correct. Arm/start
report `servo_converged`; if it is false the servo has not yet locked and
cross-card latency would read a wrong timebase — wait a moment and re-arm.
`packetwyrmd -S <ms>` tunes the servo period and `-C <ticks>` applies a per-rig
calibration (see the daemon `--help`).
