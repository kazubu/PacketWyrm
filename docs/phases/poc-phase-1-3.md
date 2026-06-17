# PoC plan: Phase 1&ndash;3 (single-card)

> **Status: COMPLETE on hardware.** All three phases run on the AS02MC04:
> PCIe enumerates, dual 10GBASE-R links up, and the data plane generates
> test flows out one SFP, loops them through a DAC into the other, and
> reports per-flow loss / latency (egress-timestamped) / jitter from
> `pktwyrm`. The plan below is the original workstream breakdown; see
> `CHANGELOG.md` and `docs/design/rtl-modules.md` for the as-built result
> (which scaled to 32 flows / 16 classifier rows and added a BRAM
> histogram, egress HW timestamping, soft-reset, and live flash/reboot).

This is the proof-of-concept work that turns the design into a single
working AS02MC04 tester. The PoC ends when one card can generate test
traffic out of SFP0, receive it on SFP1 through a DAC, and report
loss / latency / jitter from a Linux command line.

## Workstreams

### A. FPGA project bring-up (Phase 1)

1. Create the Vivado project under `fpga/as02mc04/`.
2. Capture pinout / clocking / reset in XDC.
3. Bring up the on-board reference clock and produce a known LED
   heartbeat.
4. Configure the GTY quad for the two SFP+ cages.
5. Bring up the Xilinx PCIe Gen3 hard IP at the minimum lane width
   that AS02MC04 supports.
6. Map BAR0 to a tiny CSR with at least `device_id`, `version`,
   `build_id`, `git_hash`, `capabilities`.
7. Verify on Linux via `lspci` and a tiny `mmap` test.

Definition of done: heartbeat LED runs, both SFP cages report
plugged-state correctly to the CSR, `lspci -v` shows the card with
non-zero BAR0 of expected size.

### B. MAC / PCS loopback (Phase 2)

1. Instantiate 10GBASE-R MAC + PCS for both ports.
2. Connect a minimal RX path: MAC &rarr; per-port frame counter.
3. Connect a minimal TX path: a host-writable frame template &rarr;
   MAC. Phase 2 does not need the full flow generator; a single
   "send N copies of this template" register block is enough.
4. Add a per-port loopback control bit (internal PCS loopback) for
   silicon debug before the SFP cages are stable.

Definition of done: with a DAC between SFP0 and SFP1, the TX template
on one port reaches the other port's RX counter at line rate with
zero errors.

### C. Generator / checker (Phase 3)

1. Add the `flow_gen` module: token-bucket per-flow scheduler,
   IPv4 / UDP template builder, optional sequence + timestamp insertion.
2. Add the `parser` and `classifier` modules with one priority-ordered
   linear table. Phase 3 only needs `DROP` and `TEST_RX` actions.
3. Add the `test_rx_checker`: sequence tracking, duplicate / reorder /
   late detection, latency histogram fed by the `timestamp_unit`.
4. Add per-flow counters and the stats snapshot window.

Definition of done:

- One flow programmed via BAR CSRs (host writes flow row + classifier
  row + commit bits).
- Direct DAC loopback shows `lost_est == 0` after billions of
  packets at line rate.
- Forcing TX disable for 100 ms increments `lost_est` by the expected
  count.
- Latency histogram bins are populated and visually reasonable.

## Software workstreams (in parallel with FPGA)

### D. `libpacketwyrm` &rarr; real-card backend

Phase 0 lands the fake-card backend. As soon as Phase 1 produces a
readable BAR0, port the fake backend to a real `pwfpga_card_backend`
that uses `pread64` / `pwrite64` against a `/sys/bus/pci/devices/.../resource0`
mapping, then mmap it.

### E. `packetwyrmd` &rarr; CSR programming

Once the real backend exists, wire the flow compiler outputs into
actual CSR writes. Keep the fake-card backend in the build so the
unit tests still cover the compiler in CI.

### F. `pktwyrm cards / ports / flow start / stats`

These commands already exist in skeleton form in Phase 0. Light them
up against the real card by removing fake-card guards.

## Hardware setup

```
Linux host PCIe slot
   |
   v
AS02MC04 card0
   SFP0 +---- DAC ----+ SFP1
```

## Risks specific to the PoC

- GTY transceiver settings / equalisation may need iteration; have a
  fallback internal PCS loopback path ready.
- PCIe enumeration can fail silently if BAR size / IO space is
  misconfigured &mdash; verify `lspci -vvv` early.
- 10GBASE-R block lock takes hundreds of milliseconds; provide a
  status bit and do not interpret missing link as a fatal error in
  the first second after power on.
- Token-bucket overflow at line rate can introduce micro-bursts that
  break the receive checker. Validate IFG correctness at peak rate
  before measuring loss.

## Out of scope for the PoC

- DMA rings (Phase 4 / 5 / 6).
- Multiple cards (Phase 6+).
- Cross-card flows (Phase 7).
- TAP plane (Phase 5).

These all rely on the PoC's single-card data plane being trustworthy
first.
