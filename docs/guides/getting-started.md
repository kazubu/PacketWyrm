# Getting started

A five-minute walk through PacketWyrm with no FPGA hardware.

## 1. Build

```sh
git clone <packetwyrm>
cd packetwyrm/sw
make
```

This produces `build/packetwyrmd`, `build/pktwyrm`, and
`build/libpacketwyrm.{a,so}`. The build depends on `libyaml-0.1`
and `libjson-c` via pkg-config.

## 2. Test

Host stack:

```sh
make -C sw test
# expected: 116/116 assertions pass
```

RTL data plane (needs Verilator >= 5.0):

```sh
make -C sim sim
# expected: ALL DATA PLANE SCENARIOS PASS
```

## 3. Run the daemon (fake backend, real TAPs)

The example config wires one logical card with two ports and one
same-card flow. The daemon will:

- open the `bar` backend if the PCI vendor/device match a card,
  otherwise fall back to `fake`;
- create a real Linux TAP device (`tap-pw-p0-v100`);
- listen for control RPCs on a Unix socket;
- (optionally) serve Prometheus on a TCP port.

```sh
sudo sw/build/packetwyrmd -v -s 5000 -p 9100 \
    -c configs/examples/single-card.yaml
```

You will see `tap-pw-p0-v100` appear in `ip link`. Stop the daemon
with Ctrl-C; the TAP disappears with it.

## 4. Talk to it

In another terminal:

```sh
# Pretty-printed table of host_plane counters per card
pktwyrm stats

# Full per-flow stats as a table (use --json for raw)
pktwyrm flow stats
pktwyrm flow stats --watch 1000      # top-like refresh
pktwyrm flow stats --flow 1 --json   # one flow, raw JSON

# Toggle a flow
pktwyrm flow start 1
pktwyrm flow stop  1

# Whole-tester orchestration
pktwyrm test start
pktwyrm test stop

# Latency histogram (real numbers once you have an FPGA in the loop)
pktwyrm hist latency --flow 1

# Raw JSON for any RPC
pktwyrm rpc cards
pktwyrm rpc flow.stats
```

Prometheus:

```sh
curl -s http://localhost:9100/metrics | head -20
```

## 5. Attach a routing daemon

A second terminal moves the TAP into a fresh netns and (optionally)
starts FRR:

```sh
sudo configs/examples/container-frr/start-r1.sh \
    tap-pw-p0-v100 r1

sudo ip netns exec r1 ip -br addr show
# tap-pw-p0-v100   UNKNOWN   192.0.2.1/30
```

If `frr` is on the host's PATH, the script also launches it with
`configs/examples/container-frr/frr-r1.conf` (a minimal BGP
`AS 65001` peering with `192.0.2.2 AS 65002`).

## 6. Install (production)

```sh
cd sw
sudo make install                              # /usr/local + /etc + /lib/systemd/system
sudo systemd-sysusers && sudo systemd-tmpfiles --create
sudo systemctl daemon-reload
sudo systemctl enable --now packetwyrmd
```

The default unit runs against `/etc/packetwyrm/packetwyrm.yaml`;
pick one of the example configs as a starting point:

```sh
sudo cp /etc/packetwyrm/single-card.yaml.example \
        /etc/packetwyrm/packetwyrm.yaml
```

## What happens when there's no FPGA?

The fake backend supports the full set of host-side calls
(read32 / write32 / classifier / flow / stats / slow_path),
returning zero counters and accepting writes. The pipeline is
identical end to end: the only difference is that `cards` reports
`backend: "fake"` instead of `"bar"`, and per-flow stats / hist
return zeros.

This is why every host-side feature in PacketWyrm can be developed,
tested, and demoed without real hardware. As soon as an
AS02MC04 card is in the slot and the bitstream comes up, the
daemon picks it up automatically and the same RPCs start returning
real numbers.
