# PacketWyrm architecture

This document describes the overall architecture of PacketWyrm. Detailed
sub-system designs live in their own documents under `docs/design/`.

## Goals

- Build a practical IP network tester / packet generator on top of the
  Alibaba Cloud AS02MC04 PCIe card.
- Scale from one card (2 ports) to eight cards (16 ports) in a single
  Linux host without re-architecture.
- Generate test traffic and validate it (loss, duplicate, reorder,
  latency, jitter) **inside the FPGA**.
- Hand control-plane packets (ARP, ND, LLDP, BGP, OSPF, IS-IS, ICMP,
  ICMPv6) to Linux as if each tester logical interface were a normal
  NIC, so containerised routing daemons (FRR / BIRD) can peer with a
  DUT.

## Non-goals (initial release)

- PCIe SR-IOV / VF enumeration.
- DPDK PMD.
- Large PCAP replay or large packet capture.
- Stateful TCP traffic generation (handshake / ACK / retransmit / window).
  *Stateless* TCP segment generation (fixed-flag segments with a correct L4
  checksum) IS implemented — see Part C.
- Full IXIA / Spirent-class protocol emulation.
- Full PTP / GPS / external clock discipline. *Cross-card one-way latency /
  jitter* IS supported — the daemon offset-corrects the RX-checker latency
  using the J5 GPIO time-sync (a coarse latch, not a disciplined clock); see
  the cross-card latency design note.
- 25G production support.

## High-level diagram

```
Linux host
+----------------------------------------------------------+
| containers / network namespaces                          |
|  - FRR / BIRD container #1                               |
|  - FRR / BIRD container #2                               |
|  - test / control tools                                  |
|                                                          |
| TAP / netdev                                             |
|  tap-pw-p0-v100   tap-pw-p2-v200   ...                   |
|                                                          |
| packetwyrmd                                              |
|  - global controller                                     |
|  - per-card workers                                      |
|  - flow compiler                                         |
|  - stats aggregator                                      |
|  - TAP packet dispatcher                                 |
+----------------------------------------------------------+
                    | PCIe BAR / DMA / MSI-X (later)
                    v
AS02MC04 FPGA card (one per slot)
+----------------------------------------------------------+
| PCIe endpoint / BAR / DMA                                |
|                                                          |
| RX: SFP -> MAC/PCS -> parser -> classifier               |
|         {TEST_RX, PUNT_TO_HOST, MIRROR, FORWARD, DROP}   |
|                                                          |
| TX: Linux slow-path TX -+                                |
|                         +-> TX arbiter -> MAC/PCS -> SFP |
|     FPGA flow gens     -+                                |
|                                                          |
| CSR / flow table / classifier / counters / histograms    |
+----------------------------------------------------------+
```

## Split of responsibilities

**FPGA (data plane).**
Single card scope only &mdash; the RTL never sees any global ID.

- 10GBASE-R MAC / PCS for two SFP+ ports.
- Header parser (Ethernet / 802.1Q / IPv4 / IPv6 / UDP / TCP / ICMP / ARP /
  LLDP / OSPF / BGP TCP-179).
- Classifier with a small linear (priority) or hash table, actions
  `DROP / TEST_RX / PUNT_TO_HOST / MIRROR_TO_HOST / FORWARD_PORT`.
- Test packet checker: sequence, duplicate, reorder, latency histogram
  using the FPGA timestamp counter.
- Flow generators (token-bucket scheduled).
- Slow-path RX / TX rings for punt / inject.
- Per-port and per-flow counters with snapshot-atomic 64-bit reads.

**Linux host (control plane).**
Multi-card aware from day one. Single-card systems exercise the same
code path.

- PCIe device discovery, BAR mmap, `card_id` assignment.
- `global_port_id` / `logical_if_id` / `global_flow_id` allocation.
- YAML config parsing and validation.
- Flow compiler &mdash; turns global YAML flows into per-card local
  programming.
- Classifier compiler.
- TAP / netdev creation, one per `logical_if_id`.
- Slow-path packet plane &mdash; FPGA punt &harr; TAP and TAP &rarr; FPGA
  inject.
- Stats polling and global aggregation.
- CLI / JSON / Prometheus export.

## `packetwyrmd` block diagram

```
packetwyrmd
+-- global_controller
|     PCIe device discovery, ID assignment, config parser,
|     flow compiler, classifier compiler, logical interface
|     manager, TAP/netdev manager, stats aggregator,
|     test orchestration
|
+-- card_worker[0..N-1]    (one per AS02MC04)
|     BAR mmap, local flow / classifier programming,
|     slow-path RX/TX rings, local stats polling,
|     link monitoring
|
+-- host_packet_plane
      TAP RX/TX dispatch, logical_if_id mapping,
      punt-packet routing, host TX injection
```

The single-card case is just `N=1`; no special path exists. Every flow,
port and interface goes through global -> card-local resolution.

## Data path summary

| Plane          | Direction        | Path                                                                           |
|----------------|------------------|--------------------------------------------------------------------------------|
| Test data      | Egress           | flow gen &rarr; TX arbiter &rarr; MAC/PCS &rarr; SFP                           |
| Test data      | Ingress          | SFP &rarr; MAC/PCS &rarr; parser &rarr; classifier (`TEST_RX`) &rarr; checker  |
| Control / slow | Egress (Linux TX)| TAP &rarr; daemon &rarr; FPGA slow-path TX ring &rarr; TX arbiter              |
| Control / slow | Ingress (punt)   | SFP &rarr; parser &rarr; classifier (`PUNT_TO_HOST`) &rarr; punt ring &rarr; TAP |

The TX arbiter must never starve the slow-path queue (otherwise control
protocols time out under load), and slow-path TX is itself rate-limited.

## Single-card vs cross-card flows

Same-card flows (`tx_global_port` and `rx_global_port` resolve to the
same `card_id`) get full per-packet measurements because TX and RX
timestamps come from a single FPGA timestamp counter.

Cross-card flows now also get **latency / jitter**, corrected per flow in
hardware. The two cards share a time base over the J5 GPIO sync
(`pw_gpio_sync`); the daemon servo tracks each card pair's counter offset and
writes it into the RX checker's per-flow `lat_correction` table, so the checker
accumulates `lat = (rx_wire_ts + corr[slot]) - tx_ts` per sample -- min / max /
avg / histogram all in the true one-way timebase, no post-hoc smear. The
free-running counter is never disciplined (that would break the Gray-CDC
timestamp path); only the latency computation is corrected. Same-card flows
stay exact (single FPGA counter, `corr = 0`). `flow.stats` distinguishes them
via `latency_method` (`"same-card"` / `"gpio-corrected"`); it requires the
cards' J5 headers wired.

## Phase progression

See `docs/phases/plan.md`. The big arc is:

1. Phase 0 &ndash; repository skeleton + multi-card data model (this commit).
2. Phase 1&ndash;3 &ndash; single AS02MC04 bring-up, MAC/PCS loopback, FPGA
   packet generator / checker.
3. Phase 4&ndash;5 &ndash; PCIe BAR control + userspace TAP daemon with
   control-plane punt.
4. Phase 6&ndash;7 &ndash; dual-card bring-up, cross-card flows
   (loss / sequence only).
5. Phase 8&ndash;9 &ndash; container routing daemon integration,
   multi-card orchestration.
6. Phase 10+ &ndash; timing-sync research, optional kernel netdev driver,
   25G.
