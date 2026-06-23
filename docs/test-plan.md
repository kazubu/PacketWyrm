# Test plan

PacketWyrm's tests live in three layers: RTL simulation, host software
unit tests, and hardware-in-the-loop integration tests. Each layer
catches a different class of bug; none of them subsumes the others.

## RTL simulation

Two complementary stacks live under `sim/`:

- **SystemVerilog testbenches under Verilator** (`make sim_all`).
  This is the integration gate against the production RTL. See
  `sim/README.md` for the per-target catalogue.
- **Scapy + cocotb unit suite under Icarus Verilog**
  (`make -C sim/cocotb all`). Spec-level checks on
  small behavioural mirrors of `pw_parser`, `pw_classifier`, and
  `pw_flow_gen`. Runs because cocotb 2.x's VPI shim needs
  Verilator >= 5.036 and the system Verilator here is 5.020; when a
  newer Verilator lands we can retarget cocotb at the production
  RTL and drop the mirrors.

Optional Xilinx Vivado simulation remains the fall-back for
IP-heavy modules (PCIe hard-IP, transceiver IBERT) once they land.

### Targets

- `parser` &mdash; per-protocol header extraction.
- `classifier` &mdash; priority / mask matching, action selection.
- `flow_gen` &mdash; template assembly, sequence / timestamp insertion,
  token bucket behaviour.
- `test_rx_checker` &mdash; sequence tracking, duplicate, reorder,
  late, latency (per-flow min/max/sum/count + histogram).
- `timestamp_unit` &mdash; monotonicity, wrap behaviour.
- `csr_full` &mdash; AXI-Lite slave fabric: register decode, W1C
  semantics, table commit, snapshot triggers across all four windows
  (classifier / flow / stats / histogram).
- `axis_serial` &mdash; wide<->64-bit AXIS serializer/deserializer
  (MAC interface staging).
- `wire_vectors` &mdash; C `pw_bar_backend` byte image vs SV
  `pw_csr_full` decoder agreement.
- `phase3_top` &mdash; `pwfpga_top_phase3`: AXI-Lite host writes
  end-to-end through to a frame on the AXIS pipe and back.
- `slow_path_rx/tx_dma` &mdash; descriptor fetch, completion ordering
  (still pending).

### Required cases

| Case                                  | Notes                              |
|---------------------------------------|------------------------------------|
| VLAN tagged / untagged                | parser + classifier                |
| QinQ                                  | optional, capability bit           |
| ARP punt                              | classifier action                  |
| IPv4 UDP test packet                  | `TEST_RX` end to end               |
| TCP/179 punt                          | BGP match                          |
| OSPF punt                             | IP proto 89 match                  |
| Unknown packet drop                   | catch-all rule                     |
| 64 B .. 1518 B frame length sweep     | flow_gen IFG correctness           |
| Jumbo (9000 B) frame                  | parser + MAC interoperability      |
| Rate limiter at <1 Mbps and 10 Gbps   | token bucket accuracy              |
| Forced sequence gap                   | checker counts loss                |
| Forced duplicate                      | checker counts duplicate           |
| Out-of-order delivery                 | checker counts reorder             |
| Histogram bin boundary                | bin index correctness              |
| 64-bit counter overflow               | wrap-around correctness            |
| CSR snapshot atomicity                | concurrent counter update + read   |
| Classifier mid-write read             | shadow / commit isolation          |
| Punt FIFO overflow                    | drop with counter, no stall        |
| Slow-path TX vs flow_gen contention   | arbiter fairness, no starvation    |

## Host software unit tests

Location: `sw/tests/unit/`. Built against `libpacketwyrm` with a
fake-card backend. No FPGA required, no root required.

### Targets

- YAML parser / schema validator.
- `card_id` / `global_port_id` / `logical_if_id` / `global_flow_id`
  allocation and duplicate detection.
- Logical interface mapping (name generation, MAC, MTU, punt rules).
- Flow compiler same-card path.
- Flow compiler cross-card path.
- Classifier compiler (priority, dedup with test rules).
- TAP creation (mocked at the syscall layer).
- BAR register access (against the fake card).
- Stats aggregation, including `latency_valid` propagation.
- Degraded-card behaviour: aggregator output, CLI output.
- Partial-config-failure rollback: shadow tables restored, previous
  active config keeps running.

### Required cases

- Single-card minimal config validates and compiles.
- Four-card configuration validates and compiles.
- Duplicate `card_id` rejected with file + path diagnostic.
- Duplicate `global_port_id` rejected.
- Cross-card flow with `latency: true` rejected.
- Reload that adds, removes, and modifies flows reuses
  `local_flow_id` for unchanged flows.
- Fake card reports a fault: aggregator marks it degraded; daemon
  test exits cleanly.

## Hardware-in-the-loop integration tests

Location: `sw/tests/integration/`. Require at least one AS02MC04
card with both SFP+ cages connected through a DAC.

### Single-card

Topology:

```
card0:SFP0  --DAC--  card0:SFP1
```

Tests:

- Link up / down.
- Fixed 64 B frame at line rate.
- 1518 B frame.
- Jumbo frame.
- VLAN 100 / 200.
- ARP punt &mdash; ARP request from Linux TAP reaches a peer host.
- ICMP punt &mdash; ping through TAP succeeds.
- UDP test flow not punted &mdash; TAP never sees test packets.
- Flow start / stop.
- Stats reset.
- Latency histogram populated.
- Intentional loss injection counted.

### Dual-card

Topology:

```
card0:SFP0 --switch-- card1:SFP0     (cross-card via a switch)
card0:SFP1 ---DAC---- card1:SFP1     (cross-card direct)
```

Tests:

- Two cards listed by `pktwyrm cards`.
- `p0..p3` listed by `pktwyrm ports`.
- Card-local flow on `card0`.
- Card-local flow on `card1`.
- Cross-card flow `p0 -> p2`.
- Cross-card flow `p2 -> p0`.
- Simultaneous flows in all four directions.
- Force link-down on one port; other flows unaffected.
- Stop flows on one card; other card unaffected.
- Daemon restart re-discovers both cards.
- Config reload changes flows live.
- TAP on `p0` and TAP on `p2` moved into separate netns, FRR peers
  through a DUT.

## Test infrastructure

- `make -C sw test` runs the host unit tests against the fake card
  backend.
- `make -C sw e2e` runs `e2e_smoke.sh` -- daemon + CLI smoke
  exercising the JSON-RPC surface, including `config.load`.
- `make -C sim sim_all` runs the SV testbench sweep under Verilator.
- `make -C sim/cocotb all` runs the Scapy / Python unit suite under
  Icarus.
- `make -C tools/pktwyrm-tinet test` runs the lab generator +
  orchestrator unit suite (pure Python + `unittest.mock`; no docker /
  tinet / FPGA required).
- `make hwtest` is gated on an environment variable
  (`PW_HW_DEV=card0`) and runs the integration tests against real
  hardware. CI runs the host job + RTL job above; `make hwtest`
  runs on a lab box on a separate cadence.

## Coverage gates

For each phase, the corresponding test slice **must** be green
before merging to the main branch:

| Phase | Required green tests                                              |
|-------|-------------------------------------------------------------------|
| 0     | sw test                                                           |
| 1     | sw test + smoke `pktwyrm cards/ports`                             |
| 2     | sw test + sim parser/flow_gen + frame loopback                    |
| 3     | sw test + sim_all + single-card integration                       |
| 4     | + CSR programming integration                                     |
| 5     | + TAP integration (ARP, ping)                                     |
| 6     | + dual-card integration                                           |
| 7     | + cross-card flow integration                                     |
| 8     | + pktwyrm-tinet test + lab-frr-2node manual bring-up              |
