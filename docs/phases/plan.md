# Phase-by-phase implementation plan

Each phase has an explicit acceptance gate. No phase ships without
passing its gate; phases are otherwise independent enough to be worked
in parallel by separate people once their prerequisites are met.

> **Status (see README status table):** Phases 0&ndash;8 are **DONE** (0/4/5/6/7/8
> in software; 1/2/3 on real AS02MC04 hardware, shipping build `0x6a4d2892`).
> Phase 9 orchestration landed with the explicit-start test model
> (`pktwyrm test run`). Phase 10 (timing-sync research) was **superseded** — the
> J5 GPIO time-sync delivered corrected cross-card latency without the
> research phase. Phase 11 (kernel netdev) is a **skeleton**. Phase 12 (25G) is
> still out of scope. The acceptance gates below are kept as the historical
> definition-of-done for each phase.

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
  > **UPDATE (implemented ahead of this plan):** cross-card latency IS now
  > measured, corrected per flow in hardware via the J5 GPIO time-sync
  > (`pw_gpio_sync` + the per-flow `lat_correction` table), rather than deferred
  > to a clock-sync research phase. `flow.stats` reports it with
  > `latency_method: "gpio-corrected"`. See `design/rtl-modules.md`.

## Phase 8 &mdash; container routing daemon integration

Deliverables: TAPs movable into netns; FRR / BIRD images that
peer over PacketWyrm TAPs; sample container configs.

Acceptance:

- Two FRR containers on TAPs of `p0` and `p2` (different cards)
  bring up a BGP / OSPF adjacency through a DUT.
- Test traffic and routing-control traffic both flow.

## Phase 9 &mdash; multi-card orchestration &mdash; DONE

Deliverables: `pktwyrm test arm/start/stop`, group operations,
best-effort synchronised start, per-card degraded state, test
profile execution.

Delivered: the daemon now stages flows IDLE at program/`config.load` time
and only puts traffic on the wire at an explicit `test.start` (which clears
counters and re-primes cross-card correction); `test.arm`/`test.stop` and the
one-shot `pktwyrm test run [--duration]` (arm+start+wait+stop → per-flow
PASS/FAIL + CI exit codes) drive it. `-a`/`--autostart` restores the legacy
generate-on-program behaviour. Cross-card arms report `servo_converged`.

Acceptance:

- A test profile spanning all cards starts and stops as a unit.
- A degraded card does not block orchestration; its flows are
  marked `unknown`, others continue.

## Phase 10 &mdash; timing synchronisation research &mdash; SUPERSEDED

Originally an investigative phase, required before claiming cross-card latency
support. **Superseded / not needed as a separate phase:** the J5 GPIO
time-sync (`pw_gpio_sync` + per-flow `lat_correction` table) delivered
HW-corrected cross-card latency directly (see Phase 7 and
`design/rtl-modules.md`), at the intrinsic noise floor, without a dedicated
clock-sync research effort.

## Phase 11 &mdash; optional kernel netdev driver &mdash; SKELETON

Once the userspace TAP daemon is proven, evaluate moving slow-path
into a kernel driver with multiple netdevs, MSI-X, NAPI, ethtool,
devlink. A skeleton kernel module exists (`make -C kernel` builds); the
userspace TAP plane remains the shipping slow path.

## Phase 12 &mdash; 25G support

Optional, after 10G stability. May involve new SFP cages, new GTY
configuration, and possibly new PCS / MAC choices. Out of scope for
the initial release.
