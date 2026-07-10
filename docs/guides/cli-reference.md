# pktwyrm CLI reference

`pktwyrm` is the PacketWyrm command-line client. Its verbs split in two:
**offline** verbs operate on a YAML config file and need no daemon, while
**online** verbs talk to a running `packetwyrmd` over its Unix control socket
(or to a remote `packetwyrm-proxyd` with `--host`). See
[running-tests.md](running-tests.md), [configuration.md](configuration.md),
[web-gui.md](web-gui.md), and [firmware-update.md](firmware-update.md) for the
surrounding workflows, and [../design/rpc-protocol.md](../design/rpc-protocol.md)
for the raw RPC layer these verbs sit on top of.

## Offline verbs (operate on a YAML file)

These read or validate a config; none of them need a running daemon (except
`load`, which deploys by default — see below).

| Verb | Purpose |
|------|---------|
| `pktwyrm init [--out FILE]` | Discover the PacketWyrm PCI cards on the host and emit a ready-to-edit environment-config skeleton with their BDFs filled in. |
| `pktwyrm cards [<config.yaml>]` | Discover real PacketWyrm cards on the host; with a file, list the cards it configures. |
| `pktwyrm ports <config.yaml>` | List the configured ports. |
| `pktwyrm map <config.yaml>` | Show the port → logical-interface map. |
| `pktwyrm load <config.yaml>` | Compile and **deploy** a config to the running daemon. |
| `pktwyrm flow show <config.yaml>` | List the flows in a file. |
| `pktwyrm flow preview <config.yaml>` | Decode + hex-dump the exact on-wire frame for a flow. |
| `pktwyrm version` | Print the client version. |

### `pktwyrm init [--out FILE]`

Writes the skeleton to stdout, or to `FILE` with `--out`.

```sh
pktwyrm init --out /etc/packetwyrm/packetwyrm.yaml
```

### `pktwyrm cards [<config.yaml>]`

With no argument it probes the host for real cards. Pass a config file to list
the cards it declares instead.

```sh
pktwyrm cards                    # what is in the machine
pktwyrm cards my-test.yaml       # what the file expects
```

### `pktwyrm load <config.yaml> [--socket PATH] [--check]`

**Loads a config by deploying it to the running daemon by default** (default
socket `/run/packetwyrm/packetwyrmd.sock`, or the remote target from `--host`).

- `--check` (alias `-n`) validates and compiles the file offline and exits
  **without** deploying.
- `--socket PATH` overrides the deploy target.

If the daemon is unreachable, the error names the reason.

```sh
pktwyrm load my-test.yaml --check    # validate only, no deploy
pktwyrm load my-test.yaml            # compile + deploy to the daemon
```

### `pktwyrm flow preview <config.yaml> [--flow ID] [--seq N] [--json]`

Decodes and hex-dumps the exact on-wire frame the generator emits for a flow,
offline: Ethernet `[+VLAN]` / `[IPIP|GRE|EtherIP outer]` / IPv4|IPv6 /
UDP|TCP / 32-byte test header.

- `--flow ID` picks a flow by id (else the first flow).
- `--seq N` picks the packet number; per-packet field modifiers are applied for
  that seq, so stepping `--seq` shows the varying fields.
- `--json` emits the raw hex.

The departure timestamp shows `0` (hardware stamps it at egress); IPv4/L4
checksums are computed so the hex is a valid, decodable packet.

```sh
pktwyrm flow preview my-test.yaml --flow 3 --seq 5
```

## Online verbs (need a running packetwyrmd)

These talk to a daemon over the control socket (default
`/run/packetwyrm/packetwyrmd.sock`), or to a remote proxy with `--host`.

### `pktwyrm rpc <method> [--socket PATH] [--card N]`

Issue a raw RPC and print the JSON reply. Any method name works
(`version`, `cards`, `ports`, `flows`, `stats`, …); see
[../design/rpc-protocol.md](../design/rpc-protocol.md).

```sh
pktwyrm rpc cards
pktwyrm rpc flow.stats
```

### `pktwyrm stats [--socket PATH] [--card N] [--watch MS] [--json]`

Per-card host-plane / port counters. `--watch MS` refreshes like `top`.
`pktwyrm stats clear` re-baselines all counters.

```sh
pktwyrm stats --watch 1000
pktwyrm stats clear
```

### `pktwyrm flow stats [--flow N] [--socket PATH] [--watch MS] [--json]`

Per-flow tx/rx frames + bytes, loss, duplicate, reorder, and latency
min/avg/max. Latency columns show `-` when a flow has no samples yet (no
traffic).

```sh
pktwyrm flow stats
pktwyrm flow stats --flow 1 --json
```

### `pktwyrm latency [--flow N] [--socket PATH] [--json]`

Per-flow one-way latency (same-card: exact; cross-card: J5 GPIO-corrected).

### `pktwyrm hist latency --flow N [--socket PATH] [--json]`

Per-flow power-of-two latency histogram as a text bar chart, or raw with
`--json`.

```sh
pktwyrm hist latency --flow 1
```

### `pktwyrm sfp [--card N] [--port P] [--socket PATH] [--json]`

SFP identifier + DOM (temperature, voltage, TX/RX optical power).

### `pktwyrm tap [--socket PATH] [--json]`

Host-plane TAP status + counters.

### `pktwyrm flow start|stop <id> [--socket PATH]`

Start or stop a single flow's generator.

```sh
pktwyrm flow start 1
pktwyrm flow stop 1
```

### `pktwyrm test arm|start|stop [--socket PATH] [--json]`

Whole-tester lifecycle. **Explicit-start model:** the daemon programs flows
IDLE, and **nothing transmits until `test start`**.

- `test start` — enables every flow **and** clears counters (and re-primes
  cross-card latency correction) for a clean baseline.
- `test stop` — freezes the test; counters stay readable.
- `test arm` — re-pushes the program and clears counters **without** changing
  the run state.

For cross-card flows, `arm`/`start` report `servo_converged` (plus a warning)
if the J5 GPIO servo has not locked yet.

```sh
pktwyrm test start
pktwyrm test stop
```

### `pktwyrm test run [--duration 10s] [--socket PATH] [--json]`

One-shot: arm + start + wait + stop, printing a per-flow PASS/FAIL table.
Duration accepts `s`/`ms`/`m` suffixes (default `10s`). Exit codes suit CI:

| Exit | Meaning |
|------|---------|
| `0` | PASS — every measured flow got traffic, no loss/dup/reorder |
| `1` | FAIL |
| `2` | error |

```sh
pktwyrm test run --duration 30s
```

## Firmware verbs (local, direct card)

These drive a card directly over PCIe. They need **root**, and the card must
**not** be owned by a running daemon.

### `pktwyrm firmware update <file.bin> --card BDF [--boot] [--scratch]`

Validate the image, live-write the config flash over PCIe, verify, and — with
`--boot` — trigger an ICAP reload + PCIe rescan and confirm the `build_id`
changed. Writes the BOOT image (offset 0) by default; `--scratch` targets the
`0xE00000` dev region (incompatible with `--boot`). See
[firmware-update.md](firmware-update.md).

```sh
sudo pktwyrm firmware update packetwyrm.bin --card 07:00.0 --boot
```

## Global flags

These may appear anywhere on the command line.

| Flag | Purpose |
|------|---------|
| `--secret S` | Control-socket secret. Resolution order: `--secret` > `$PACKETWYRM_SECRET` > the `secret` key of the `--env` file. |
| `--env PATH` | Env config to read the secret from (default `/etc/packetwyrm/packetwyrm.yaml`). |
| `--host H[:P]` | Talk to a remote `packetwyrm-proxyd` over HTTPS (default port `8443`) instead of the local Unix socket; `--socket` is then ignored. |
| `--socket PATH` | Control-socket path for online verbs (default `/run/packetwyrm/packetwyrmd.sock`). |
| `--json` | Machine-readable JSON output. |

## Output contract

Use `--json` for scripts: it is a stable contract. The pretty tables are
human-only and their columns may change between versions — do not parse them.
