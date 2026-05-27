# Phase-by-phase implementation plan

Each phase has an explicit acceptance gate. No phase ships without
passing its gate; phases are otherwise independent enough to be worked
in parallel by separate people once their prerequisites are met.

## Phase 0 &mdash; repository skeleton + data model (this commit)

Deliverables: directory tree, design docs, `libpacketwyrm` C data
model, YAML schema, fake-card backend, CLI / daemon stubs, build
system, example configs, initial unit tests.

Acceptance:

- The host stack builds with `make` and `make test` passes.
- A single card and a four-card multi-card config both pass
  validation.
- Duplicate `card_id`, `global_port_id`, `logical_if_id`, `flow_id`
  are detected and reported by file + path.
- Cross-card flows that request `latency: true` are rejected with a
  clear message.

## Phase 1 &mdash; single AS02MC04 bring-up

Deliverables: Vivado project for AS02MC04, clocking / reset / LED
heartbeat, SFP GTY basic bring-up, 10GBASE-R link up, PCIe endpoint
enumerates with vendor / device IDs, CSR `device_id` / `version` /
`capabilities` readable from `packetwyrmd`.

Acceptance:

- JTAG identifies the FPGA.
- Bitstream loads and the heartbeat LED blinks.
- `pktwyrm cards` shows `card0`.
- `pktwyrm ports` shows `p0`, `p1`.
- Link state for both ports is reported correctly.

## Phase 2 &mdash; Ethernet MAC / frame loopback

Deliverables: MAC / PCS plumbing, simple TX-from-host (BAR write
trampoline) for Ethernet frames, RX counters.

Acceptance:

- 64 B&ndash;1518 B frames sent from SFP0 are seen at SFP1.
- TX and RX frame counters match over a long run.
- Line-rate fixed-size frames do not increment error counters.

## Phase 3 &mdash; FPGA packet generator / checker

Deliverables: flow generator, test header, sequence + timestamp
insertion, RX classifier with `TEST_RX` action, RX checker with
loss / duplicate / reorder counters, latency histogram.

Acceptance:

- One flow can run at user-specified rate.
- Loss = 0 in a direct DAC loopback.
- Intentional drops increment `lost_est`.
- Latency histogram updates and matches expected loop length.
- Same-card flow reports `latency_valid = true`; the daemon already
  knows to mark cross-card flows `latency_valid = false`.

## Phase 4 &mdash; PCIe BAR control

Deliverables: PCIe enumerates on Linux, BAR mmap from
`packetwyrmd`, classifier / flow programming over CSRs, stats
read via snapshot window, all going through the multi-card code
path.

Acceptance:

- `packetwyrmd` discovers the card, prints `device_id`, `version`.
- A YAML flow can be programmed and torn down via CSR writes.
- Stats read from the snapshot window are consistent (no torn
  64-bit reads).

## Phase 5 &mdash; userspace TAP daemon

Deliverables: TAP creation per logical interface, classifier punt
rules from `logical_interfaces:`, slow-path RX / TX through BAR
(or initial DMA), Linux can ARP / ping through a tester port.

Acceptance:

- `tap-pw-p0-v100` exists after `pktwyrm load`.
- ARP and ping to an external DUT succeed via the TAP.
- Concurrent FPGA flow + slow-path traffic both run; neither
  starves the other.

## Phase 6 &mdash; dual-card bring-up

Deliverables: discovery of two cards, deterministic `card_id`
assignment, per-card workers, isolated failure handling.

Acceptance:

- `pktwyrm cards` shows two cards.
- `pktwyrm ports` shows `p0`..`p3`.
- Flows on `card0` and `card1` can be started / stopped
  independently.
- Forcibly disabling one card does not kill `packetwyrmd` or affect
  the other card's flows.

## Phase 7 &mdash; cross-card flows

Deliverables: flow compiler emits separate TX-card and RX-card
programming for a single global flow; aggregator merges results.

Acceptance:

- `tx_global_port=0, rx_global_port=2` flow runs end to end.
- TX counters on card0 match RX counters on card1 (modulo
  intentional drops).
- `latency` is reported as `unsupported` / `invalid`, never a
  number.

## Phase 8 &mdash; container routing daemon integration

Deliverables: TAPs movable into netns; FRR / BIRD images that
peer over PacketWyrm TAPs; sample container configs.

Acceptance:

- Two FRR containers on TAPs of `p0` and `p2` (different cards)
  bring up a BGP / OSPF adjacency through a DUT.
- Test traffic and routing-control traffic both flow.

## Phase 9 &mdash; multi-card orchestration

Deliverables: `pktwyrm test arm/start/stop`, group operations,
best-effort synchronised start, per-card degraded state, test
profile execution.

Acceptance:

- A test profile spanning all cards starts and stops as a unit.
- A degraded card does not block orchestration; its flows are
  marked `unknown`, others continue.

## Phase 10 &mdash; timing synchronisation research

Investigative phase. Outputs are an internal report and
candidate proof-of-concepts. Not required for shipping a usable
tester; required before claiming cross-card latency support.

## Phase 11 &mdash; optional kernel netdev driver

Once the userspace TAP daemon is proven, evaluate moving slow-path
into a kernel driver with multiple netdevs, MSI-X, NAPI, ethtool,
devlink.

## Phase 12 &mdash; 25G support

Optional, after 10G stability. May involve new SFP cages, new GTY
configuration, and possibly new PCS / MAC choices. Out of scope for
the initial release.
