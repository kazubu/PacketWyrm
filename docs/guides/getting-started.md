# Getting started

A five-minute walk through PacketWyrm with no FPGA hardware.

## 1. Build

```sh
git clone <packetwyrm>
cd packetwyrm
make -C sw
```

This produces `sw/build/packetwyrmd`, `sw/build/pktwyrm`, and
`sw/build/libpacketwyrm.{a,so}`. The build depends on `libyaml-0.1`
and `libjson-c` via pkg-config. (All commands below run from the repo
root.)

## 2. Test

Host stack:

```sh
make -C sw test      # host unit tests
make -C sw e2e       # daemon <-> CLI smoke
```

RTL data plane (needs Verilator >= 5.0):

```sh
make -C sim sim_all  # SystemVerilog testbench sweep
```

Optional Python unit suite (needs Icarus Verilog + cocotb 2 + Scapy):

```sh
make -C sim/cocotb all   # parser + classifier + flow_gen units
```

## 3. Run the daemon (fake backend, real TAPs)

The example config wires one logical card with two ports and one
same-card flow. The daemon will:

- open the `bar` backend for each card; if a card's BAR cannot be
  opened it is a hard error **unless** `-F`/`--allow-fake` is given,
  which permits the no-op `fake` backend (for a no-FPGA run like this
  one);
- create a real Linux TAP device (`tap-pw-p0-v100`);
- listen for control RPCs on a Unix socket;
- (optionally) serve Prometheus on a TCP port.

```sh
sudo sw/build/packetwyrmd -v -F -s 5000 -p 9100 \
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

### Option A: bare `ip netns` (one router)

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

### Option B: `pktwyrm-tinet` (N containers)

For two-or-more routers, the lab generator + orchestrator is much
less work. Stop the daemon you started in step 3, then run:

```sh
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet up \
    configs/examples/lab-frr-2node/lab.yaml \
    -o /tmp/lab-frr/

# Wait a few seconds for FRR to boot, then:
sudo docker exec r1 vtysh -c 'show bgp summary'

# Status / re-apply / tear down:
python3 tools/pktwyrm-tinet/pktwyrm-tinet status -o /tmp/lab-frr/
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet conf -o /tmp/lab-frr/
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet down -o /tmp/lab-frr/
```

`up` starts `packetwyrmd`, polls for the TAPs to appear, runs
`tinet up` + `tinet conf`, and persists state under
`/tmp/lab-frr/.pktwyrm-lab.json`. See `tools/pktwyrm-tinet/README.md`
for the lab-spec format.

> **Security note:** these commands run as root and execute a `tinet`-generated
> shell script named by the state file under the out-dir, so the out-dir must be
> **owned by root and private** — otherwise a local user could plant a hostile
> state / tinet YAML and get root command execution. `up` creates a fresh
> out-dir as `0700` root-owned; if you pre-create it, use
> `sudo install -d -m 0700 /tmp/lab-frr`. `down`/`conf`/`up` refuse an out-dir
> owned by another user or that is group/world-writable, and refuse a state
> whose `tinet_yaml` points outside the out-dir.

## 6. Install (production)

```sh
cd sw
sudo make install                              # /usr/local + /etc + /lib/systemd/system
sudo systemd-sysusers && sudo systemd-tmpfiles --create
sudo systemctl daemon-reload
sudo systemctl enable --now packetwyrmd
```

After enabling, **verify the daemon actually reached the card under systemd**
(not just under a manual `sudo`): the unit runs as root with the full
capability set precisely because the BAR mmap / PCI-config prep need it, so a
too-narrow `CapabilityBoundingSet` would let a manual run work while the service
silently fails to open the BAR. Confirm with:

```sh
systemctl status packetwyrmd            # active (running), no restart loop
sudo journalctl -u packetwyrmd -b       # look for the card BAR opening, no
                                        #   "BAR open failed" / permission errors
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
