# YAML configuration schema

The PacketWyrm configuration is a single YAML document with these
top-level keys: `system`, `cards`, `logical_interfaces`, `flows`, and
`forwards`. The schema is designed for multi-card deployments; a
single-card system simply has a `cards:` list of length one.

## Top-level

```yaml
system:               # required
cards:                # required, len >= 1
logical_interfaces:   # optional, len >= 0
flows:                # optional, len >= 0
forwards:             # optional, len >= 0  (store-and-forward rules)
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
    netns: "r1"                # optional, reserved; daemon currently
                               # ignores this. Move TAPs into a netns
                               # via `ip link set` or pktwyrm-tinet.
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

    # ipv6:                        # ... or an IPv6 block (mutually exclusive)
    #   src: "2001:db8::1"
    #   dst: "2001:db8::2"
    #   hop_limit: 64              # optional, default 64
    # An ipv6 flow is emitted as a 40-byte IPv6 header (ethertype 0x86DD) +
    # UDP with a correct, non-zero UDP checksum: the generator emits a
    # partial checksum (minus tx_timestamp) and the egress stamper folds the
    # departure timestamp into it, so IPv6 flows get the same DUT-accurate
    # egress timestamping as IPv4. The test header is unchanged, so
    # loss/latency measurement is identical.

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

    modifiers:                       # optional: per-field "field modifiers"
      dst_ipv4: { mode: increment, mask: 0x000003ff }  # rotate low 10 bits -> 1024 flows
      src_ipv4: { mode: random,    mask: 0x0000ffff }
      udp_src:  { mode: increment, mask: 0xffff }
      udp_dst:  { mode: static }     # (default; same as omitting)
```

`modifiers` vary the **masked bits** of a header field per emitted frame
so one generator slot looks like many flows to the DUT (for hashing /
ECMP / per-flow-state testing). `mode` is `static` (default) /
`increment` / `random`; `mask` selects which bits rotate (hex or decimal).
The rotated bits are driven by the slot's per-frame sequence number, so
there is no extra per-slot state. Notes:

- The **test header** (`magic` / `flow_id` / `sequence` / `tx_timestamp`)
  is never modified, so RX loss / latency / order measurement is
  unaffected — the DUT sees many flows; PacketWyrm tracks one.
- The **IPv4 header checksum** is recomputed in hardware from the modified
  addresses (the generator always emits a correct IPv4 checksum now).
- Do **not** rotate a field the classifier matches on for measurement
  (e.g. if a TEST_RX rule keys on `udp_dst`, don't modify `udp_dst`) —
  it would misclassify the return traffic.
- Per-*apparent*-flow individual RX stats are limited to the HW slot
  count (`NUM_FLOWS`); aggregate loss/latency across the diversified
  traffic is unaffected.
- v1 covers `src_ipv4` / `dst_ipv4` / `udp_src` / `udp_dst`; all rotate
  off the same sequence (correlated, not a full cross-product). MAC / VLAN
  modifiers are a mechanical extension of the same scheme.

Constraints:

- `id` unique.
- `tx_global_port` and `rx_global_port` must exist.
- `logical_if_id`, if set, must exist.
- Exactly one of `ipv4` / `ipv6` must be set (both implemented:
  IPv4 emits a correct IPv4 header checksum; IPv6 emits a 40-byte header
  + a correct non-zero UDP checksum). Field modifiers (`modifiers:`)
  apply to IPv4 src/dst + UDP ports only in v1.
- Exactly one of `traffic.rate_bps` / `traffic.rate_pps`.
- Exactly one of `traffic.frame_len` and the
  `frame_len_min/max/step` triple.
- `measurements.latency` and `.jitter` may not be `true` on a
  cross-card flow.

## `forwards`

Store-and-forward rules: relay frames from one port to another on the
same card. Each rule compiles to a classifier `FORWARD_PORT` row whose
`egress_local_port` is resolved from `egress_port`. The optional match
keys narrow which frames are relayed (all `0`/absent = forward every
frame arriving on `ingress_port`).

```yaml
forwards:
  - name: "relay-udp5000"   # optional, informational
    ingress_port: 0         # required, global port id
    egress_port: 1          # required, global port id (SAME card)
    priority: 40            # optional, 0..255, lower wins (default 40)
    ethertype: 0x0800       # optional match (0/absent = any)
    ip_proto: 17            # optional match (IPv4 proto / IPv6 next-hdr)
    udp_dst: 5000           # optional match
    vlan: 100               # optional match (0..4094)
```

- `ingress_port` and `egress_port` must resolve to ports, and must be
  on the **same card** (the classifier is per-card; `egress_local_port`
  is a local port id).
- Hex (`0x0800`) and decimal are both accepted for match values.
- FORWARD rules are independent of `flows` / `logical_interfaces`; a
  config may have only `forwards` (a pure relay/DUT-in-path setup).

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
