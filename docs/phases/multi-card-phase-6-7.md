# Multi-card extension plan: Phase 6&ndash;7

Phase 6 turns the single-card system into a multi-card system. Phase 7
lights up flows that span two cards. By the end, a four-port tester
made of two AS02MC04s presents itself to the user as one logical
tester, with consistent flow / port / stats behaviour and explicit,
honest handling of cross-card timing.

## Inputs from Phase 5

- A working single-card `packetwyrmd` with multi-card data model
  already in place (Phase 0).
- Card-worker threads exist but the daemon only ever runs one of them.

## Phase 6 deliverables

### 1. PCIe device discovery for N cards

Iterate `/sys/bus/pci/devices` for the AS02MC04 vendor / device pair.
Sort by BDF. Assign `card_id` in sort order. Log the mapping at
startup:

```
card0 -> 0000:03:00.0  fw 0.1.0
card1 -> 0000:04:00.0  fw 0.1.0
```

### 2. Per-card workers

Spawn one card-worker thread per discovered card. Each owns:

- its own BAR0 mmap,
- its own classifier / flow staging state,
- its own slow-path RX / TX rings,
- its own stats snapshot buffer.

No card-to-card shared state. The main thread coordinates via SPSC
queues.

### 3. Independent failure handling

If a worker's BAR reads return all-ones, or `pci_dev` removal events
arrive, the worker:

- marks the card `degraded`,
- stops attempting CSR writes,
- preserves last-known counter values for the aggregator,
- continues running so the surrounding daemon stays up.

`pktwyrm cards` shows `Status: degraded` for the affected card.

### 4. CLI

`pktwyrm cards` and `pktwyrm ports` show both cards / four ports.
`pktwyrm flow show` returns flows belonging to either card.

### Phase 6 acceptance

- Two AS02MC04 cards discovered, listed, and individually
  start/stoppable.
- Pulling one card's flow does not affect the other card.
- Daemon restart re-discovers both cards deterministically.

## Phase 7 deliverables

### 1. Cross-card flow compilation

The flow compiler already supports cross-card flows by construction
(Phase 0). Phase 7 simply turns on the path:

- emit a TX flow row on the TX card,
- emit an RX flow row + classifier on the RX card,
- annotate `latency_valid = false` (now the cross-card **method** flag, not a
  refusal) -- cross-card latency/jitter is accepted and HW-corrected (see §3).

### 2. Stats aggregation across cards

The aggregator picks up TX counters from card A and RX counters from
card B for the same `global_flow_id`. The CLI / JSON output shows
the result as a single global flow.

### 3. Honest cross-card timing reporting

> **UPDATE (superseded — implemented ahead of plan):** cross-card latency is now
> measured and reported, corrected per flow in hardware via the J5 GPIO
> time-sync (`pw_gpio_sync` + the per-flow `lat_correction` table). `flow.stats`
> / `pktwyrm latency` show it with `latency_method: "gpio-corrected"` (vs
> `"same-card"`); `latency_valid` is the method flag, not an availability gate.
> The original plan below (refuse cross-card latency until a clock-sync phase)
> no longer applies.

(Original plan:) `pktwyrm stats` shows `latency: unsupported` for cross-card
flows. Never a number. Same in JSON (`latency_valid: false`, optional
`latency_reason`).

### 4. Hardware setup for testing

```
card0:p0 -- DUT (switch) -- card1:p0
card0:p1 -- direct DAC -- card1:p1
```

Using a direct DAC for `p1 <-> p1` gives a no-DUT path for sanity
testing, and the DUT path exercises real cross-card flow through a
switch.

### Phase 7 acceptance

- `tx_global_port=0, rx_global_port=2` flow runs.
- Loss / duplicate / out-of-order counters agree with what was
  injected.
- Same-card flows continue to report latency correctly.
- A YAML config that requests `latency: true` on a cross-card flow
  is rejected by `pw_config_validate` before any FPGA programming
  happens.

## Migration of test material

All Phase 0 unit tests for the multi-card data model become
integration tests by retargeting from the fake-card backend to the
real CSR backend. No test code changes; only the backend selector
flips.

## Known limitations entering Phase 8

- Per-card stats poll intervals are independent. A pessimistic
  global view treats the older of the two as the snapshot time.
- `flow start` across cards is best-effort synchronous: the daemon
  writes commit bits as fast as it can, but two cards can come up
  microseconds apart. This is fine for loss / throughput tests; it
  is documented as "best-effort synchronised start" in
  `pktwyrm test`.
- TAPs on cards 0 and 1 are independent fds; routing daemons that
  span them sit in containers and rely on Linux's normal IP stack.
