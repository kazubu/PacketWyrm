# pktwyrm-tinet

PacketWyrm lab-spec -> [tinet](https://github.com/tinynetwork/tinet)
topology generator. Turns a small YAML that says *"router r1 runs FRR
on logical_if 1000, router r2 runs FRR on logical_if 1001, they peer
eBGP"* into a tinet YAML plus per-router FRR config files that
`tinet up | sudo sh` can launch.

The generator is read-only against PacketWyrm. It loads an existing
PacketWyrm config to resolve `logical_if_id` -> kernel TAP name
(`tap-pw-p<gport>-v<vlan>`) and emits everything else.

## Why this lives outside `sw/`

The core PacketWyrm daemon and its JSON Schema know nothing about
containers, tinet, or FRR. Adding `routers:` to the daemon's config
schema would push container concerns into the data-plane core. Keeping
the lab spec in a separate file (referencing the PacketWyrm config by
path) leaves the core untouched and lets the lab tool evolve
independently.

## Lab spec format

```yaml
packetwyrm_config: ./packetwyrm.yaml       # path, relative to lab.yaml

routers:
  - name: r1
    image: quay.io/frrouting/frr:latest
    logical_if_id: 1000                    # existing LIF in PW config
    addr: "192.0.2.1/30"
    addr6: "2001:db8::1/64"                # optional
    routing:
      bgp:
        asn: 65001
        router_id: "192.0.2.1"
        neighbors:
          - { peer: "192.0.2.2", remote_as: 65002 }
        networks:
          - "10.0.1.0/24"                  # advertised prefixes
```

OSPF / IS-IS are intentionally not in v1 — add them when you need
them, following the same shape under `routing:`.

## Usage

```sh
# 1. Render the lab.
python3 tools/pktwyrm-tinet/generate.py generate \
    configs/examples/lab-frr-2node/lab.yaml \
    -o /tmp/lab-frr/

# 2. Start the PacketWyrm daemon (creates TAPs).
sudo packetwyrmd -c configs/examples/lab-frr-2node/packetwyrm.yaml &

# 3. Bring the containers up.
sudo sh -c "cd /tmp/lab-frr && tinet up   -c tinet.yaml | sh"
sudo sh -c "cd /tmp/lab-frr && tinet conf -c tinet.yaml | sh"

# 4. Verify.
sudo docker exec r1 vtysh -c 'show bgp summary'

# 5. Tear down.
sudo sh -c "cd /tmp/lab-frr && tinet down -c tinet.yaml | sh"
```

## How TAPs attach

Two ways exist; we pick the simpler one:

  - **Move the TAP netdev into the container netns.** The TAP fd
    stays in `packetwyrmd`'s process (because file descriptors aren't
    bound to net namespaces), while the netdev moves into the
    container netns via `ip link set <tap> netns <ctr>`. One data-path
    hop fewer than a veth bridge.

The generator emits these `ip link set` calls under tinet's
`postinit_cmds`, which run as root after containers exist but before
`tinet conf` runs the in-container setup.

## Testing

```sh
make -C tools/pktwyrm-tinet test
```

13 golden + schema-validation tests. Pure Python; no docker, no
tinet binary, no FPGA required.

```sh
make -C tools/pktwyrm-tinet example
```

Renders the in-tree example to `/tmp/lab-frr/` without running it.

## Dependencies

Generator: `python3`, `PyYAML`.
Run-time: `docker` (or compatible), `tinet`, `iproute2`, the
`packetwyrmd` binary.
