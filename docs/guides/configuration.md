# Configuration

PacketWyrm reads YAML. Configuration comes in two roles:

- The **environment config** (rarely changed) holds `system`, `cards`,
  `logical_interfaces`, and an optional `secret`. It describes the
  hardware. Deploy it as `/etc/packetwyrm/packetwyrm.yaml` and pass it
  to the daemon with `-e` (alias `-c`).
- The **test config** (changed often) holds `flows` and `forwards`
  only. It describes the traffic. Load it onto a running daemon with
  `pktwyrm load`, or attach it at startup with `-t`.

A single combined file (system + cards + flows) also works for a quick
one-file setup — the split just keeps stable hardware topology apart
from the traffic you iterate on.

For the exhaustive field-by-field reference see
[../design/yaml-schema.md](../design/yaml-schema.md). This guide is the
practical orientation.

## Generate a starting point

`pktwyrm init` discovers the cards present and prints an env-config
skeleton with real PCI BDFs filled in:

```sh
sudo pktwyrm init --out /etc/packetwyrm/packetwyrm.yaml
```

Then edit the ports and logical interfaces to taste.

## Environment config

```yaml
system:
  name: lab-tester
  mode: tester
  default_speed: 10G
  control_socket: /run/packetwyrm/packetwyrm.sock   # optional
  secret: correct-horse-battery                     # optional (see below)

cards:
  - id: 0
    name: card0
    pci: "0000:07:00.0"       # BDF; short "07:00.0" also accepted
    ports:
      - { local_port: 0, global_port: 0, name: p0 }
      - { local_port: 1, global_port: 1, name: p1 }

logical_interfaces:
  - id: 100
    global_port: 0
    vlan: 100
    mac: 02:00:00:00:00:01
    mtu: 1500
    punt: { arp: true, ipv6_nd: true, lldp: false, icmp: true, bgp: true, ospf: true }
```

`cards` / `ports` / `logical_interfaces` describe the topology. The
`punt:` block on each logical interface selects which control-plane
protocols are punted to that interface's host TAP.

## The secret (access control)

If `system.secret` is set, every client must supply a matching secret
on each RPC. Clients resolve it in this order:

1. `--secret` on the command line
2. `$PACKETWYRM_SECRET`
3. the `secret:` key of the `--env` file

Because option 3 reads the env file, **file read-permission is the
access gate**. If no secret is set at all, the control socket's own
file permission (`0660 root:packetwyrm`) is the ACL.

Note: `config.get_raw` and the Web GUI **redact** the secret, so
saving that redacted view back will not clobber the real secret on
disk.

## Test config (flows)

```yaml
flows:
  - id: 1
    name: v4-udp
    tx_global_port: 0
    rx_global_port: 1
    logical_if_id: 100          # optional
    l2:   { src_mac: 02:00:00:00:00:01, dst_mac: 02:00:00:00:00:02, vlan: 100 }
    ipv4: { src: 192.0.2.1, dst: 192.0.2.2, ttl: 64, dscp: 0 }
    # or ipv6: { src: 2001:db8::1, dst: 2001:db8::2, hop_limit: 64, dscp: 0 }
    udp:  { src_port: 12345, dst_port: 53 }
    # or set l4_proto: 6 for TCP, plus tcp_flags
    traffic:
      frame_len: 512            # or frame_len_min/max/step for a sweep
      rate_bps: 1000000000      # or rate_pps
      burst_size: 1
      payload: 0x00
      insert_sequence: true
      insert_timestamp: true
    measurements: { loss: true, latency: true, jitter: true }
```

A few optional knobs (one sentence each — full detail in
[../design/yaml-schema.md](../design/yaml-schema.md)):

- `frame_template` (`test` | `l4raw` | `l3raw` | `l2raw`) selects how
  much of the frame PacketWyrm builds versus takes verbatim.
- `modifiers:` vary individual header fields (inc / rand / mask) across
  frames — preview them per the [running-tests](running-tests.md) guide.
- `encap:` wraps the flow in an IPIP, GRE, or EtherIP tunnel.
- `background: true` makes a TX-only load flow with no RX side and no
  measurement.
- `classify: header` classifies RX by header match instead of the
  default flow-id map.

## Deploying

```sh
pktwyrm load flows.yaml            # deploy to the running daemon
pktwyrm load flows.yaml --check    # validate offline only
```

PacketWyrm uses an **explicit-start** model: a freshly loaded config
transmits nothing until `pktwyrm test start` (see
[running-tests.md](running-tests.md)). Over-capacity configs — more
measured flows than the bitstream supports, e.g. 33 on a 32-flow build
— are rejected with a message naming the numbers.

## Editing in the browser

The Web GUI has a Flows / Forwards editor that reads and writes this
same YAML (via `config.get_test` / `config.load`) — see
[web-gui.md](web-gui.md).

## See also

- [running-tests.md](running-tests.md) — starting, stopping, and
  observing traffic
- [web-gui.md](web-gui.md) — the browser dashboard and editor
- [../design/yaml-schema.md](../design/yaml-schema.md) — the exhaustive
  field reference
