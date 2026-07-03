# Two-router cRPD lab across a PacketWyrm DUT

Two Juniper **cRPD** containers, one per SFP+ port, peering BGP / OSPF / IS-IS
across the PacketWyrm card (SFP0↔SFP1 DAC cross-connect). Control-plane frames
(ARP / ICMP / BGP / OSPF / IS-IS) are punted to each port's host TAP, moved by
`packetwyrmd`, injected back out the port, and looped to the peer's port.

```
cRPD R1 (net0)                         cRPD R2 (net0)
   │ TAP tap-pw-p0-v0                     │ TAP tap-pw-p1-v0
   ▼                                       ▼
packetwyrmd ── inject ▶ port0 TX ─DAC─ port1 RX ▶ punt ── packetwyrmd
            ◀ punt ── port0 RX ─DAC─ port1 TX ◀ inject
```

## Bring-up (manual recipe — verified on 07:00.0, build 0x6a4726ae)

1. `sudo packetwyrmd -e configs/examples/lab-crpd-2node/packetwyrm.yaml -v`
   (creates untagged TAPs `tap-pw-p0-v0`, `tap-pw-p1-v0`; punt = arp/icmp/bgp/
   ospf/is_is on both lifs).
2. `docker run -d --rm --privileged --net none --name R1 crpd:<ver>` (and R2).
3. Move each TAP into its container netns and rename to a Junos-friendly name:
   `ip link set tap-pw-p0-v0 netns <R1-pid>`, then in the netns
   `ip link set tap-pw-p0-v0 name net0 && ip link set net0 up`.
4. cRPD: `cli request system license add …`, then `cli -c 'configure; …'`.
   - IS-IS **NET must go on `lo0`** (the Junos loopback), NOT `lo` (Linux
     loopback) — cRPD has both; the system-id derives from `lo0`'s ISO address.
   - `set protocols isis hello-padding disable` (cRPD 26.2 rejects the older
     `no-hello-padding`).

## Status (2026-07-04) — full dual-stack control plane over the DMA slow path

**All verified across the DUT on the DMA slow-path build (build_id 0x6a47e2bc):**
- **IPv4:** ARP, ICMP ping (0 % loss, ~2.2 ms RTT), BGP Established, OSPF (v2)
  Full, IS-IS L1+L2 Up.
- **IPv6:** ND, ICMPv6 ping (0 % loss), **BGP over IPv6 Established**, **OSPFv3
  Full**, IS-IS IPv6 topology.

Both routers learn each other's IPv4 *and* IPv6 loopback via OSPF/OSPFv3 *and*
IS-IS. IS-IS and >512 B frames — blocked on the old CSR-window path — now work
because the slow path is PCIe-DMA (`pw_dma_slowpath`), not the 512 B register
window. See `docs/design/dma-slow-path.md`.

The IPv6 control plane needs **`ipv6_nd: true`** in `packetwyrm.yaml` (punts
ICMPv6 ND); the flow compiler then also emits the IPv6 punt variants of OSPFv3
(0x86DD + next-hdr 89) and BGP-over-IPv6 (0x86DD + TCP/179), sharing the 0x86DD
ethertype + proto/L4 comparators with the IPv4 rules → 11/12 field comparators.
cRPD config adds `family inet6` on net0, `protocols ospf3 area 0 interface net0`,
a BGP group with an IPv6 neighbor + `family inet6 unicast`, and
`protocols isis topologies ipv6-unicast`.

### cRPD gotchas (in addition to the license / lo0-NET / hello-padding notes above)

- **OSPF/IS-IS interface reference: use `interface net0`, NOT `interface net0.0`.**
  cRPD binds the Linux-named TAP `net0` at the device level; the `.0` unit form
  did NOT attach — the interface silently never appeared in `show ospf interface`
  and no adjacency formed, even though BGP/ping worked. Use
  `set protocols ospf area 0 interface net0` and `set protocols isis interface net0`.
- `packetwyrmd` marks the TAP tun carrier UP (TUNSETCARRIER) so cRPD accepts the
  interface, but the interface-reference form above is what actually gated the IGP.

### Jumbo note

True 9000 B jumbo across the DUT additionally needs the data-plane MAC↔dp_clk CDC
FIFO (`pw_mac_axis_cdc DEPTH`, currently 2048 ≈ 2 KB) widened — a separate RTL
change. Control-plane frames (IS-IS padded hellos at MTU 1514, LSPs, ≤~2 KB data)
already traverse.

`packetwyrm.yaml` uses **untagged** lifs: the slow-path inject does not add an
802.1Q tag, so a VLAN-tagged lif would fail to match the (ingress+vlan) punt
rule. Untagged also frees the VLAN field-comparator (NCMP=12 pool).
