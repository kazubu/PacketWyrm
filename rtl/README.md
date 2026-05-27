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
