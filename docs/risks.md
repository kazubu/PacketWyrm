# Risk list (priority-ordered)

Each risk has a brief mitigation. Risks at the top are the ones most
likely to derail the schedule and are tackled first.

## 1. AS02MC04 SFP / GTY 10G bring-up

GTY transceiver settings, reference clock, board layout quirks, and
SFP power can all gate link-up. No software work is meaningful until
this works.

Mitigations:

- Internal PCS loopback path available before SFP cages are trusted.
- Eye-scan / IBERT enabled in early bitstreams.
- Try a known-good DAC first; defer optical SFPs.
- Capture a `lspci -vvv` + GTY status dump as part of every bring-up
  iteration.

## 2. Vivado project / XDC / clock / reset stability

A flaky project that meets timing today and fails tomorrow blocks
everyone. Single-source-of-truth XDC and a Vivado project that builds
from `tcl` scripts (no GUI-edited binaries) are required.

Mitigations:

- `project.tcl` checked in; bitstream build is reproducible.
- Timing report archived per build under `fpga/as02mc04/builds/`.
- A small CI job runs `make synth` headlessly.

## 3. MAC / PCS frame transport

Even with link-up, MAC errors at line rate make all downstream tests
unreliable. Validate this before turning on the flow generator.

Mitigations:

- Phase 2 explicitly only proves frame transport.
- TX / RX counters compared over 10^11 packets in a loop test.

## 4. PCIe endpoint / BAR Linux enumeration

If `lspci` does not see the card with the right BAR size, no host
software can run.

Mitigations:

- `device_id` / `vendor_id` registered with a clear value.
- Initial BAR size kept small (64 KB) to avoid kernel resource
  conflicts on busy hosts.
- `/sys/bus/pci/devices/.../resource0` permissions and udev rules
  documented.

## 5. FPGA timestamp / sequence checker correctness

A subtly wrong checker turns the whole tester into a confident liar.

Mitigations:

- Targeted RTL simulation: forced drops, dupes, reorders, wrap.
- Bit-exact reference checker model in `sw/tests/`.
- Long-soak integration tests on direct DAC loopback.

## 6. Slow-path queue backpressure

If the punt FIFO can starve test traffic or vice versa, real
deployments will silently misbehave under load.

Mitigations:

- Punt FIFO drops with a counter rather than backpressuring the RX
  pipeline.
- Slow-path TX has its own rate cap.
- TX arbiter has anti-starvation watermarks for slow-path packets.

## 7. TAP daemon + container FRR / BIRD integration

The whole reason for the daemon is to let routing daemons run as if
through a real NIC. Hidden bugs in TAP framing, VLAN handling, or
namespace movement will break adjacencies.

Mitigations:

- Test BGP, OSPF, LDP-equivalent control protocols end to end.
- Document container recipes in `configs/examples/`.

## 8. Multi-card discovery + global port mapping

A non-deterministic `card_id` assignment makes scripts and operators
unhappy. Conversely, a static map is brittle when cards are swapped.

Mitigations:

- BDF-order assignment by default.
- YAML can pin a specific PCI BDF to a specific `card_id`.
- Mismatches between YAML and discovered cards are explicit errors.

## 9. Cross-card flow loss / sequence measurement

Two FPGAs not sharing a clock domain still need to agree on
sequence semantics. We rely entirely on the `global_flow_id` and
the test header magic, not on time.

Mitigations:

- The RX checker's correctness has no dependence on time on the RX
  card.
- `latency` is never reported across cards.

## 10. Long-soak counter overflow / snapshot integrity

Counters that wrap silently lose data; snapshots that tear give
nonsense.

Mitigations:

- 64-bit counters everywhere.
- Read-latch on `_low` / `_high` pairs.
- Per-flow stats snapshot trigger that latches everything atomically.
- Long-soak (24 h) integration test that compares
  before / after deltas.

## 11. Thermal / link flap recovery

Optical SFPs and DACs both flap occasionally; the system must
recover without operator intervention.

Mitigations:

- Link-down does not kill `packetwyrmd`.
- Block-lock loss is a counter, not a fatal error.
- Stats freeze on degraded cards rather than go to zero.

## 12. Cross-card timestamp synchronisation

This is the gating risk for cross-card latency. Until solved, the
product cannot claim cross-card latency / jitter.

Mitigations:

- Honest reporting: `latency_valid = false`, never a fake number.
- Phase 10 is a dedicated research phase; nothing else depends on
  it.

## 13. Build / dependency drift

Multi-year FPGA / Linux projects rot quickly. Pinning toolchain
versions matters.

Mitigations:

- `scripts/` records Vivado version, kernel version, libc version
  per release.
- C code targets C11 with no compiler-specific extensions.
- Tests do not depend on third-party network state.

## 14. Operator misconfiguration

Users will request impossible flows (cross-card latency, duplicate
IDs, etc.). The daemon must refuse politely with actionable
diagnostics, not crash or pretend.

Mitigations:

- `pw_config_validate` returns precise field-path diagnostics.
- Schema document and example configs cover the common cases.
- CLI shows the rejected path verbatim.
