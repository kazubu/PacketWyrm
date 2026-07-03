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

## Status (2026-07-03)

Verified working across the DUT: **ARP, ICMP ping (small frames), BGP
Established, OSPF Full**. Blocked: **IS-IS** and any frame >512 B, by the
CSR-window slow path's `PWFPGA_INJECT_MAX_FRAME = 512` (large ping 1000 B → 0/2;
IS-IS MTU-padded hellos / LSPs dropped at inject). The proper fix is the
**DMA slow path** — see `docs/design/dma-slow-path.md`. Once DMA lands, re-run at
MTU 9000 with hello-padding ON and confirm IS-IS + jumbo.

`packetwyrm.yaml` uses **untagged** lifs: the slow-path inject does not add an
802.1Q tag, so a VLAN-tagged lif would fail to match the (ingress+vlan) punt
rule. Untagged also frees the VLAN field-comparator (NCMP=12 pool).
