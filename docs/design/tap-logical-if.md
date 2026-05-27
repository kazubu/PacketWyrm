# TAP / logical interface design

A **logical interface** is the unit of control-plane visibility. Each
one maps to:

- exactly one `global_port_id` (and therefore one
  `(card_id, local_port_id)`),
- exactly one VLAN (or untagged),
- exactly one Linux TAP device,
- one classifier punt-tag (`logical_if_id`) that the FPGA writes into
  every punt descriptor.

This is what lets containerised FRR / BIRD instances see a tester port
as a normal NIC.

## Naming

```
tap-pw-p<global_port_id>-v<vlan_id>
```

Examples:

```
tap-pw-p0-v100
tap-pw-p1-v100
tap-pw-p2-v200
tap-pw-p3-v300
```

Untagged interfaces use `v0`:

```
tap-pw-p0-v0
```

Names are deterministic so containers can pin them by name.

## Lifecycle

1. `packetwyrmd` parses the config and validates each
   `logical_interfaces:` entry.
2. For each entry it creates a TAP (`IFF_TAP | IFF_NO_PI`), sets MAC
   and MTU, leaves it `down`.
3. The daemon installs classifier punt rules for the requested
   protocols (`arp`, `ipv6_nd`, `lldp`, `icmp`, `bgp`, `ospf`,
   `is_is`, ...) using the entry's `logical_if_id`.
4. The TAP fd is kept by the daemon; reads see Linux-injected
   packets, writes deliver FPGA punted packets to Linux.
5. Operators move TAPs into containers / namespaces:

```sh
ip netns add r1
ip link set tap-pw-p0-v100 netns r1
ip netns exec r1 ip link set tap-pw-p0-v100 up
ip netns exec r1 ip addr add 192.0.2.1/30 dev tap-pw-p0-v100
ip netns exec r1 frr -d
```

## Punt flow

```
SFP -> MAC/PCS -> parser -> classifier (match: ARP / dst MAC / ...)
                          -> PUNT_TO_HOST with logical_if_id = K
                          -> punt FIFO (carries metadata)
                          -> PCIe slow-path RX ring
                          -> packetwyrmd card worker
                          -> dispatch by logical_if_id
                          -> write to TAP fd K
                          -> Linux netns delivers to container
```

If the logical interface owns the VLAN, the daemon strips the 802.1Q
tag before writing to the TAP. The container sees an untagged
interface and configures its own L3.

## Inject flow

```
container writes to tap-pw-p0-v100
   |
   v
packetwyrmd reads TAP fd
   |
   +-- prepend VLAN tag (if the logical interface owns one)
   +-- enqueue slow-path TX descriptor:
         egress_local_port = 0
         logical_if_id = K
         optional priority
   |
   v
card worker writes descriptor to FPGA slow-path TX ring
   |
   v
TX arbiter merges with FPGA flow generators -> MAC -> SFP
```

Slow-path TX is rate-limited so a misbehaving control plane cannot
starve test flows; conversely, the TX arbiter is forbidden from
starving slow-path packets (anti-starvation watermarks).

## Classifier rule generation

For every logical interface, the classifier compiler emits at least:

| Match                                       | Action          | Tag           |
|---------------------------------------------|-----------------|---------------|
| ARP, ingress port + VLAN                    | PUNT_TO_HOST    | logical_if_id |
| ND (ICMPv6 type 135/136), dst MAC = if-MAC  | PUNT_TO_HOST    | logical_if_id |
| LLDP (ethertype 0x88cc)                     | PUNT_TO_HOST    | logical_if_id |
| ICMP / ICMPv6 to if-IP                      | PUNT_TO_HOST    | logical_if_id |
| TCP port 179 (BGP), if-IP                   | PUNT_TO_HOST    | logical_if_id |
| OSPF (IP proto 89), if-MAC / multicast      | PUNT_TO_HOST    | logical_if_id |
| IS-IS (Ethernet, optional)                  | PUNT_TO_HOST    | logical_if_id |

These are gated by the per-interface `punt:` block in YAML so users can
disable noisy protocols.

## Coexistence with test traffic

Test packets carry the magic `pwfpga_test_hdr` and match a higher
priority `TEST_RX` rule. Control packets do not have the magic and
fall through to the punt rules. There is no overlap by design.

## Failure handling

- TAP creation failure &rarr; config rejected.
- TAP write would block (Linux not draining) &rarr; drop, increment
  `logical_if_tap_tx_dropped`. Control plane retransmits.
- Container moves the TAP back to the daemon's namespace
  unexpectedly &rarr; daemon detects via `IFLA_NET_NS_PID` events
  and logs.
- Classifier rule install failure during reload &rarr; full rollback
  to previous active classifier (using the staging buffer).
