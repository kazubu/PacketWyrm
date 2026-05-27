# YAML configuration schema

The PacketWyrm configuration is a single YAML document with four top-level
keys: `system`, `cards`, `logical_interfaces`, and `flows`. The schema is
designed for multi-card deployments; a single-card system simply has a
`cards:` list of length one.

## Top-level

```yaml
system:               # required
cards:                # required, len >= 1
logical_interfaces:   # required, len >= 0
flows:                # required, len >= 0
```

## `system`

```yaml
system:
  name: "pw-multiport-tester"   # required, freeform identifier
  mode: "multi-card"            # required, must be "multi-card"
  default_speed: "10g"          # required for now; only "10g"
  stats_poll_interval_ms: 100   # optional, default 100
  control_socket: "/var/run/packetwyrm/packetwyrmd.sock"  # optional
```

## `cards`

```yaml
cards:
  - id: 0
    name: "card0"
    pci: "0000:03:00.0"
    ports:
      - local_port: 0
        global_port: 0
        name: "p0"
      - local_port: 1
        global_port: 1
        name: "p1"
```

Constraints:

- `id` unique across `cards`.
- `pci` unique; must match a discovered AS02MC04 BDF.
- `local_port` is `0` or `1`.
- `(card.id, local_port)` unique.
- `global_port` unique across all cards.
- `name` defaults to `p<global_port>` and must be unique.

## `logical_interfaces`

```yaml
logical_interfaces:
  - id: 1000
    name: "tap-pw-p0-v100"     # optional; default tap-pw-p<gport>-v<vlan>
    global_port: 0
    vlan: 100                  # 0 means untagged
    mac: "02:a5:02:00:00:64"
    mtu: 9000                  # optional, default 1500
    netns: "r1"                # optional; daemon moves the TAP here
    punt:
      arp: true
      ipv6_nd: true
      lldp: true
      icmp: true
      bgp: true
      ospf: true
      is_is: false
```

Constraints:

- `id` unique tester-wide.
- `name`, if explicit, must match `tap-pw-` prefix.
- `global_port` must exist in `cards[].ports[]`.
- `vlan` 0..4094 (4095 reserved).
- `mac` valid 48-bit hex.
- `punt.*` are independent booleans.

## `flows`

```yaml
flows:
  - id: 1                          # global_flow_id, unique
    name: "same-card-flow"         # optional
    tx_global_port: 0
    rx_global_port: 1
    logical_if_id: 1000            # optional metadata, no forwarding effect

    l2:
      src_mac: "02:a5:02:00:00:01"
      dst_mac: "02:a5:02:00:00:02"
      vlan: 100                    # optional

    ipv4:                          # exactly one of ipv4 / ipv6 must be set
      src: "192.0.2.1"
      dst: "192.0.2.2"
      ttl: 64                      # optional, default 64
      dscp: 0                      # optional

    udp:
      src_port: 49152
      dst_port: 50001

    traffic:
      frame_len: 512               # or frame_len_min/max/step
      rate_bps: 1000000000         # or rate_pps
      burst_size: 1                # optional, default 1
      burst_gap_ticks: 0           # optional
      payload: "increment"         # one of: zero, increment, prbs, random
      payload_seed: 0              # for prbs / random
      insert_sequence: true
      insert_timestamp: true

    measurements:
      loss: true
      latency: true
      jitter: true
      # Cross-card flows must set latency:false and jitter:false.
      # The daemon refuses the config otherwise.
```

Constraints:

- `id` unique.
- `tx_global_port` and `rx_global_port` must exist.
- `logical_if_id`, if set, must exist.
- Exactly one of `ipv4` / `ipv6` (Phase 0&ndash;3 implement IPv4 only;
  validator may accept `ipv6` blocks but feature flag them as
  not-yet-supported).
- Exactly one of `traffic.rate_bps` / `traffic.rate_pps`.
- Exactly one of `traffic.frame_len` and the
  `frame_len_min/max/step` triple.
- `measurements.latency` and `.jitter` may not be `true` on a
  cross-card flow.

## Validator output

`pw_config_validate` returns an enumerated error code plus a
human-readable diagnostic that names the offending field path,
for example:

```
flows[2].measurements.latency: cross-card flow does not support latency
```

```
logical_interfaces[3].global_port: 7 is not declared in any card
```

## JSON-schema (informative)

A JSON-schema mirror of this document lives in
`sw/libpacketwyrm/schema/packetwyrm.schema.json` and is used by the
unit tests; it is informative only &mdash; the C validator is
authoritative.
