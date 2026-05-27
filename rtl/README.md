# Shared (board-agnostic) RTL

Module breakdown lives in `docs/design/rtl-modules.md`. Phase 1
populates this directory with:

- `parser/` &mdash; Ethernet / VLAN / IPv4 / IPv6 / TCP / UDP / ICMP /
  LLDP / OSPF / BGP / ICMPv6 / ND header extraction
- `classifier/` &mdash; priority-ordered linear match table with
  `DROP / TEST_RX / PUNT_TO_HOST / MIRROR_TO_HOST / FORWARD_PORT`
  actions; double-buffered with commit
- `flow_gen/` &mdash; per-flow token-bucket scheduled generator with
  test-header insertion
- `test_rx_checker/` &mdash; sequence / duplicate / reorder / late /
  latency tracking, latency histogram
- `csr_fabric/` &mdash; AXI-Lite decode, W1C, double-buffered tables,
  counter snapshot
- `tx_arbiter/` &mdash; mixing FPGA flow generators and slow-path TX

Board-specific wrappers (GTY, PCIe IP, clocking) live under
`fpga/<board>/`. The shared RTL must not depend on any board pinout.

## Phase 1 (current)

The minimum board-agnostic RTL needed for AS02MC04 PCIe bring-up
lives under `shared/`:

- `pw_pkg.sv` &mdash; shared constants (device id, CSR offsets,
  capability bits).
- `pw_version_pkg.sv.in` &mdash; build-time generated `version /
  build_id / git_hash` package.
- `pw_csr_min.sv` &mdash; AXI4-Lite slave with the Phase 1 identity
  registers, timestamp pair read-latch, and W1C error register.
- `pw_heartbeat.sv` &mdash; LED heartbeat at a configurable rate.
- `pw_timestamp.sv` &mdash; free-running 64-bit timestamp counter.
- `xilinx_prims_blackbox.sv` &mdash; black-box stubs of the
  UltraScale+ primitives used by board-side RTL (IBUFDS, BUFG).
  Used only by Verilator lint; Vivado picks up `unisims`.
