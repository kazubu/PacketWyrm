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
- `punt.*` are independent booleans. Each compiles to a narrowly-scoped PUNT
  classifier rule on the ingress: `arp`/`lldp` by ethertype; `icmp`/`ospf` by
  IPv4 proto; `ipv6_nd` by IPv6 next-header; `bgp` by **TCP port 179** (two
  rules, dst:179 + src:179 — so other TCP, e.g. generated SYN-flood traffic, is
  not punted); `is_is` by the **802.3/LLC DSAP/SSAP 0xFEFE** signature (not a
  catch-all). Slow-path / control-plane traffic only — keep these off for flows
  you intend to measure.

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
    #   dscp: 0                    # optional 0..63 -> IPv6 traffic class
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
      frame_len: 512               # total L2 frame bytes (excl FCS); or
                                   #   frame_len_min/max/step for a size sweep.
                                   # The generator emits this exact size (min==max)
                                   # or sweeps min->max by step (IMIX). Sizes below
                                   # the 74 B test-frame floor clamp up to it.
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

    background: false                # optional, default false. true = TX-only
                                     # load traffic: the flow generates but gets
                                     # NO RX classifier rule and is not measured.
                                     # Background flows don't consume a classifier
                                     # entry, so a config can run more generator
                                     # flows (up to the HW slot count) than the
                                     # classifier capacity (e.g. 32 gen / 16 meas).

    encap:                           # optional: wrap the inner frame in a tunnel
      type: ipip                     #   ipip | gre | etherip
      outer:                         #   outer L3 -- exactly one of ipv4 / ipv6
        ipv4: { src: "10.0.0.1", dst: "10.0.0.2", ttl: 32, dscp: 0 }
        # ipv6: { src: "2001:db8::1", dst: "2001:db8::2", hop_limit: 64 }
      # inner_l2:                    # EtherIP only, optional: MAC of the inner
      #   src_mac: "02:bb:00:00:00:01"   # Ethernet frame. Defaults to the flow
      #   dst_mac: "02:bb:00:00:00:02"   # l2 MAC when omitted.
    rx_expect: tunneled              # optional, default inner. inner = DUT
                                     #   decapsulated (RX gets the bare inner
                                     #   frame); tunneled = RX gets the frame
                                     #   with the outer+tunnel still on it.

    classify: header                 # optional, default map. RX classification:
                                     #   map    = key on the test header flow_id
                                     #            via the flow-id map (scales to
                                     #            256 flows; needs the flow_id at
                                     #            a fixed payload offset).
                                     #   header = classify by an EXACT header tuple
                                     #            {dst IP, dst port, src port,
                                     #            proto} via the hash exact table
                                     #            (payload carries NO classification
                                     #            dependency -- fill it freely).
                                     #            Scales to the checker's NUM_FLOWS;
                                     #            the compiler finds a collision-
                                     #            free hash seed. (Punt/forward use
                                     #            the field+UDF classifier.)

    match:                           # optional: narrow the RX match for masked
      udp_dst: 0xff00                # field-comparator matching. bitwise mask
      ipv4_dst: 0xffffff00           # (1 = bit must match); default full match.
                                     # (classify: header uses an exact tuple, so
                                     # the masks are advisory there.) Also lets a
                                     # modifier rotate the unmatched bits.
                                     # rotate the unmatched bits. mask 0 = ignore
                                     # that field. A modifier on a matched field
                                     # auto-relaxes its mask.

    modifiers:                       # optional: per-field "field modifiers"
      dst_ipv4: { mode: increment, mask: 0x000003ff }  # rotate low 10 bits -> 1024 flows
      src_ipv4: { mode: random,    mask: 0x0000ffff }
      # For an ipv6 flow, use src_ipv6 / dst_ipv6 instead (same syntax); the
      # mask rotates the low 32 bits of the address (host / interface-ID).
      #   dst_ipv6: { mode: increment, mask: 0x000000ff }
      udp_src:  { mode: increment, mask: 0xffff }
      udp_dst:  { mode: static }     # (default; same as omitting)
      src_mac:  { mode: increment, mask: 0x0000000000ff }  # 48-bit mask
      dst_mac:  { mode: random,    mask: 0x00000000ffff }
      vlan:     { mode: increment, mask: 0x0ff }           # low 12 bits (VLAN ID)
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
- The **IPv4/IPv6 checksums** are recomputed in hardware from the modified
  addresses (IPv4 header checksum; IPv6 UDP checksum).
- Do **not** rotate a field the classifier matches on for measurement
  (e.g. if a TEST_RX rule keys on `udp_dst`, don't modify `udp_dst`) —
  it would misclassify the return traffic.
- Per-*apparent*-flow individual RX stats are limited to the HW slot
  count (`NUM_FLOWS`); aggregate loss/latency across the diversified
  traffic is unaffected.
- Covers `src_ipv4` / `dst_ipv4` (or `src_ipv6` / `dst_ipv6`, low 32 bits) /
  `udp_src` / `udp_dst` / `src_mac` / `dst_mac` (48-bit mask) / `vlan` (low 12
  bits). MAC / VLAN modifiers only rewrite the Ethernet header (not in any
  checksum). All rotate off the same sequence (correlated, not a full
  cross-product). Full 128-bit IPv6-address rotation is a mechanical
  extension of the same scheme.

`encap` wraps the flow's inner IP/UDP/test frame in an outer L3 + tunnel
header so PacketWyrm can exercise a DUT's tunnel decap/encap path:

- `type: ipip` — bare outer IP (proto 4 for a v4 inner, 41 for a v6 inner).
- `type: gre` — outer IP proto 47 + a 4-byte GRE header (protocol-type
  `0x0800` / `0x86DD` matching the inner family).
- `type: etherip` — outer IP proto 97 + a 2-byte EtherIP header + a full
  inner Ethernet header. The inner Ethernet MAC comes from `encap.inner_l2`
  (`src_mac`/`dst_mac`); when that block is omitted it reuses the flow's `l2`
  MACs.
- `outer:` carries its own `ipv4`/`ipv6` block (src/dst, ttl/hop_limit,
  dscp); the **outer family is independent of the inner** (v4-in-v6, etc.).
- The outer IPv4 header checksum is computed in hardware. The inner header
  checksums (IPv4 header / IPv6 UDP) are unchanged — egress timestamping
  still rewrites the inner test header's `tx_timestamp` and fixes up the
  inner UDP checksum at its (encap-dependent) deep offset.
- The test header lives in the **innermost** UDP payload, so loss/latency
  measurement is identical to a non-encapsulated flow.

`rx_expect` says how the measured return traffic arrives:

- `inner` (default) — the DUT decapsulated; RX receives the bare inner frame.
- `tunneled` — RX receives the frame with the outer + tunnel header still on
  it (the DUT relayed it as-is or added its own encap).

The RX parser auto-decapsulates recognized tunnels (IPIP/GRE/EtherIP) and
classifies on the **inner** frame, so both `rx_expect` modes are measured by
matching the inner test header; `rx_expect` is recorded for the daemon's
benefit. (Both inner and outer may be v4 or v6.)

Constraints:

- `id` unique.
- `tx_global_port` and `rx_global_port` must exist.
- `logical_if_id`, if set, must exist.
- Exactly one of `ipv4` / `ipv6` must be set, at full feature parity:
  both emit DSCP/traffic-class, TTL/hop-limit, and address field modifiers
  (IPv4 emits a correct header checksum; IPv6 a correct non-zero UDP
  checksum). Address modifiers use the family key (`src_ipv4`/`dst_ipv4` or
  `src_ipv6`/`dst_ipv6`); for IPv6 they rotate the low 32 bits.
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
