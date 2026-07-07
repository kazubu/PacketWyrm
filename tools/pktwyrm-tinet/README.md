# pktwyrm-tinet

PacketWyrm lab orchestrator: turns a small lab spec into a running
container topology backed by [tinet](https://github.com/tinynetwork/tinet),
with each container's primary interface being a PacketWyrm TAP.

## Sub-commands

```
pktwyrm-tinet generate  LAB.YAML [-o OUT/]   emit tinet.yaml + per-router FRR configs
pktwyrm-tinet up        LAB.YAML [-o OUT/]   generate + packetwyrmd + tinet up + tinet conf
pktwyrm-tinet conf               [-o OUT/]   re-apply tinet conf to a running lab
pktwyrm-tinet down               [-o OUT/]   tinet down + stop packetwyrmd
pktwyrm-tinet status             [-o OUT/]   print JSON state
```

`generate` and `status` are read-only. `up`, `conf`, and `down` need
root (packetwyrmd + `ip link set` + docker).

## Quick start

```sh
# Bring up: one command, all the moving parts.
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet up \
    configs/examples/lab-frr-2node/lab.yaml \
    -o /tmp/lab-frr/

sudo docker exec r1 vtysh -c 'show bgp summary'

# Re-apply node config (after editing the lab.yaml + re-generating):
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet conf -o /tmp/lab-frr/

# Tear down.
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet down -o /tmp/lab-frr/
```

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
          - "10.0.1.0/24"                  # advertised prefixes (v4 and/or v6)
```

`addr` must be an IPv4 address with prefix length and `addr6` an IPv6
address with prefix length (they are fed to `ip addr add` verbatim);
addresses must be unique across routers. BGP `networks` are emitted
under the matching FRR address-family (`ipv4 unicast` / `ipv6 unicast`),
and IPv6 neighbors are activated under `ipv6 unicast` automatically.

OSPF / IS-IS are intentionally not in v1 -- add them when you need
them, following the same shape under `routing:`.

## Why this lives outside `sw/`

The core PacketWyrm daemon and its JSON Schema know nothing about
containers, tinet, or FRR. Adding `routers:` to the daemon's config
schema would push container concerns into the data-plane core. Keeping
the lab spec in a separate file (referencing the PacketWyrm config by
path) leaves the core untouched and lets the lab tool evolve
independently.

## How TAPs attach

  - `pktwyrm-tinet up` starts `packetwyrmd`, then polls for the TAP
    netdevs to appear in the root netns (max 10 s).
  - `tinet up` creates the containers with `--network none`.
  - The generated tinet spec's `postinit_cmds` runs
    `ip link set <tap> netns <container>` once per router. The TAP fd
    stays in `packetwyrmd`'s process (file descriptors aren't bound to
    net namespaces); only the netdev moves.
  - `tinet conf` then runs `ip addr add ... && /usr/lib/frr/frrinit.sh
    start` inside each container.

One data-path hop fewer than a veth bridge, and the same approach as
`configs/examples/container-frr/start-r1.sh` -- just scaled to N
routers and idempotent.

## State

`up` writes `<out_dir>/.pktwyrm-lab.json` with the `packetwyrmd` pid,
the tinet.yaml path, and the TAP list. `down`, `conf`, and `status`
read that file. If you blow away the out_dir, `down` becomes a no-op
(or a best-effort `tinet down` if a stray `tinet.yaml` is still there).

## Testing

```sh
make -C tools/pktwyrm-tinet test
```

35 tests in pure Python (PyYAML + `unittest.mock` only) -- no docker,
no tinet binary, no FPGA. Covers:

  - the generator's tinet.yaml + FRR.conf goldens
  - lab-spec schema validation (positive + negative)
  - state-file round-trip + pid liveness
  - shell-command construction
  - `up`/`down`/`conf` orchestration with mocked subprocess

The full subprocess path (real `packetwyrmd`, real `tinet up`) is
covered by `make example` and by running the worked example by hand.

## Dependencies

Generator: `python3`, `PyYAML`.
Run-time (for `up`/`conf`/`down`): `packetwyrmd`, `docker` (or
compatible), `tinet`, `iproute2`.
