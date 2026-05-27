# Changelog

All notable changes to PacketWyrm. The project is in active
pre-release development; this file is updated per development
push and is the source of truth for "what's working today".

## Unreleased

### Added

- **Parser & classifier**
  - QinQ (802.1ad outer + 802.1Q inner) tag decoding
  - IPv6 (40-byte fixed header, source/dest extraction, next-header
    routing to TCP / UDP / ICMPv6)
  - Unified `l4_src` / `l4_dst` for TCP and UDP
  - Protocol class flags: `is_arp`, `is_ipv4`, `is_ipv6`, `is_tcp`,
    `is_udp`, `is_icmp`, `is_icmp6`, `is_ospf`
  - Matching mask bits for each new field
- **Test RX checker**
  - Per-flow min / max / sum / sample-count latency stats
  - Power-of-two latency histogram
- **Flow generator**
  - Token-bucket rate limit with Q16.16 bytes/cycle + burst-byte cap
- **CSR / BAR backend**
  - Wire-format structs (`pwfpga_classifier_entry`,
    `pwfpga_flow_config`, `pwfpga_test_hdr`, DMA descriptor /
    completion) are now `__attribute__((packed))` so the host
    and the RTL share a byte-for-byte view.
  - CSR window strides + commit register offsets centralised in
    `csr.h` (`PWFPGA_CLASSIFIER_STRIDE`,
    `PWFPGA_REG_CLASSIFIER_COMMIT`, etc.).
  - `pw_bar_backend_*` ops are functional end-to-end:
    classifier_write / flow_write / classifier_commit /
    flow_commit / stats_snapshot / port_stats_read /
    flow_stats_read / flow_hist_read all use word-aligned BAR
    writes/reads against the documented window layout.

- **Host stack**
  - `libpacketwyrm/tap.h` &mdash; create / configure TAP devices via
    `/dev/net/tun` + ioctl (no libnl dependency)
  - `libpacketwyrm/host_plane.h` &mdash; FPGA punt &harr; TAP fd
    bridge using slow-path RX/TX FIFOs on the backend
  - `libpacketwyrm/ipc.h` &mdash; length-prefixed JSON over Unix domain
    socket
  - Fake-backend slow-path FIFOs + `pw_fake_backend_inject_punt` /
    `_drain_tx` test helpers
  - `pw_pci_discover()` &mdash; sysfs-based PCI enumeration
  - `pw_bar_backend_open()` &mdash; mmap of
    `/sys/bus/pci/devices/<bdf>/resource0`
- **`packetwyrmd`**
  - Long-running event loop with TAP creation, host_plane stepping,
    SIGINT / SIGTERM clean shutdown
  - Initial program push to backends at startup
  - JSON-RPC server on a Unix socket:
    `version`, `cards`, `ports`, `flows`, `stats`,
    `flow.start`, `flow.stop`, `flow.stats`, `flow.hist`,
    `test.arm`, `test.start`, `test.stop`
  - Prometheus `/metrics` exporter on `-p PORT`
- **`pktwyrm`**
  - Offline: `cards`, `ports`, `map`, `load`, `flow show`, `version`
  - Online: `rpc <method>`, `stats [--watch]`, `flow start|stop`,
    `flow stats`, `test arm|start|stop`, `hist latency --flow N`
- **Packaging**
  - `make install` target with `DESTDIR` / `PREFIX` / split dirs
  - systemd unit (`packetwyrmd.service`), sysusers entry,
    tmpfiles entry, udev rule
- **Examples**
  - `configs/examples/container-frr/` &mdash; FRR-on-TAP via
    `ip netns` recipe, including a smoke-tested `start-r1.sh`
- **AS02MC04 (FPGA side)**
  - Phase 1 Vivado project skeleton with reverse-engineered pin
    assignments sourced from Julia Desmazes (Essenceia) and Alex
    Forencich (Taxi)
  - Verilator lint of the shared + AS02MC04 RTL
  - OpenOCD + J-Link JTAG bring-up recipe
- **Simulation**
  - `make -C sim sim`: Verilator-driven `tb_data_plane.sv`, 38 / 38
    assertions across scenarios: drop, punt, loopback, loss, dup,
    vlan, forward, ooo, rate, qinq, bgp, ospf, ipv6
- **Tests**
  - `make -C sw test`: 116 / 116 unit-test assertions across
    YAML / validator / flow compiler / backend (fake + BAR) /
    PCI discovery / host_plane / TAP / IPC

### Documentation

- Initial design docs under `docs/design/` and phase plan under
  `docs/phases/`
- README updated to reflect the current implementation status
- Per-board bring-up notes in `fpga/as02mc04/docs/`
- This CHANGELOG
- RPC reference: `docs/design/rpc-protocol.md`
- Getting-started: `docs/guides/getting-started.md`
