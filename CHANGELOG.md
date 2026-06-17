# Changelog

All notable changes to PacketWyrm. The project is in active
pre-release development; this file is updated per development
push and is the source of truth for "what's working today".

For where work is going next, see `NEXT-STEPS.md`.

## Unreleased

### Added

- **Phase 3 data plane on silicon (AS02MC04 / KU3P)** — the 64-bit
  streaming data plane runs on hardware at line rate, loss=0:
  - Rewrote the unroutable wide `pw_frame_t` bus into a 64-bit AXIS
    streaming plane (`pw_parser_axis`, `pw_flow_gen_multi`,
    `pw_frame_saf`, `pw_data_plane_axis`); closes timing at 156.25 MHz.
  - Scaled to **32 flows / 16 classifier rows / 16 latency bins**;
    bidirectional + 16 concurrent flows validated at loss=0.
  - **Store-and-forward FORWARD validated on silicon** — a classifier
    `FORWARD_PORT` rule routes ingress frames through `pw_frame_saf` to
    the egress port; HW test (`pw_phase3_forward`) crossed the DAC twice
    at line rate with loss=0.
  - **FORWARD egress port now host-selectable** — added
    `egress_local_port` (byte 92) to the classifier wire struct and
    decoded it in `pw_classifier_window`; the data plane already routed
    by the classifier result's `egress_port` (previously hardwired to
    0). `pw_phase3_forward [fwd_egress]` validates routing to either
    port; `sim_vec` covers the new wire byte.
  - **Timing margin recovered** — pipelined `pw_parser_axis` key extract
    into two stages; WNS +0.003 → +0.020 ns at 156.25 MHz, HW-revalidated
    at loss=0.
  - **PUNT / slow-path RX to the host** — `pw_punt_rx_window` sinks the
    data plane's punt AXIS (`PUNT_TO_HOST` / `MIRROR_TO_HOST`) into a
    CSR-polled single-frame buffer (`PWFPGA_WIN_PUNT_RX`, BAR, no DMA).
    The SAF now carries each frame's `logical_if_id` + ingress port as
    metadata; `bar_slow_path_rx` drains frame + lif, and the daemon
    `host_plane` routes them to the per-`logical_if_id` TAP. New
    `sim_punt` unit tb; the `sim_top` punt scenario reads the frame back
    over the CSR BAR (lif verified).
  - **PUNT / slow-path TX from the host** — `pw_inject_tx_window` is the
    host → FPGA complement: the host composes a frame in a CSR buffer
    (`PWFPGA_WIN_INJECT_TX`, 512 B max), sets length + egress, writes GO;
    the window emits it into that egress port's TX arbiter (priority
    between forwarded frames and the generator). `bar_slow_path_tx`
    drives it. New `sim_inj` unit tb + a `tb_data_plane_axis` inject
    scenario (arbiter routes inject to the chosen egress). HW round-trip
    (`pw_phase3_inject`): inject out egress 0 → DAC → RX1 → PUNT → read
    back byte-identical, proving both slow-path directions on silicon.
  - **BRAM-backed latency histogram** (`pw_lat_histogram`) — freed the
    FF wall that capped flow scaling; read live via the CSR window.
  - **Egress hardware timestamping** (`pw_ts_insert` + `pw_ts_gray_cdc`)
    — tx_timestamp applied at the MAC (PTP one-step style), so measured
    latency reflects the DUT, not the tester's own TX queuing.
  - **CSR data-plane soft-reset** (`REG_DP_RESET`) — recover a wedged
    data plane without a JTAG reconfig.
  - **Wide CSR address map** — classifier/flow/stats windows 16 KB,
    histogram 8 KB (128 B stride); commit/trigger/clear above the data
    region. (ABI change; see `docs/design/csr-map.md`.)
- **In-system flash + reconfiguration**
  - `pw_spi_flash` CSR SPI master via STARTUPE3 — erase/program/read the
    config flash live over PCIe (no JTAG); `pktwyrm flash` / `pw_flash`.
  - `pw_icap_reboot` (ICAP IPROG via `REG_REBOOT`) — reload the bitstream
    from flash in-band; `pw_reboot`. The full-feature image is flashed as
    the cold-boot image.
- **Lab integration: pktwyrm-tinet**
  - `tools/pktwyrm-tinet/` generates a [tinet](https://github.com/tinynetwork/tinet)
    topology + per-router FRR configs from a small lab spec that
    references an existing PacketWyrm config. Each router runs in a
    container; its assigned PacketWyrm TAP is moved into the
    container's network namespace via tinet `postinit_cmds`, so
    PacketWyrm stays the data-plane truth and tinet handles the
    container lifecycle.
  - v1 supports BGP (asn / router_id / neighbors / advertised
    networks). OSPF / IS-IS can be added under the same `routing:`
    shape when needed.
  - Lifecycle CLI: `pktwyrm-tinet up LAB.YAML` starts `packetwyrmd`,
    waits for TAPs to appear, runs `tinet up` + `tinet conf`, and
    persists state (pid, tinet.yaml, TAP list) under
    `<out_dir>/.pktwyrm-lab.json`. `conf`, `down`, and `status`
    operate against that state file. `down` is idempotent and falls
    back to a best-effort `tinet down` when the state file is gone
    but a tinet.yaml is still present.
  - `make -C tools/pktwyrm-tinet test`: 35 / 35 tests in pure Python
    (PyYAML + `unittest.mock` only). No docker / tinet / FPGA
    required. Covers golden YAML/FRR rendering, lab-spec schema
    validation, state-file round-trip, shell command construction,
    and the up/down/conf orchestrator (with mocked subprocess).
  - Worked example at `configs/examples/lab-frr-2node/` with two FRR
    routers peering eBGP across a DUT.
  - Lab spec lives in its own file (referencing the PacketWyrm config
    by path); the core daemon and its JSON Schema are untouched.
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
  - **Per-card worker threads**: one pthread per opened card runs
    its own `poll()` over its TAP fds + `pw_host_plane_step()`.
    The main thread keeps the control socket and Prometheus
    listener, so slow-path latency on one card cannot be starved
    by a busy control socket or by another card. Workers exit on
    a `stdatomic` stop flag set by the signal handler.
  - Initial program push to backends at startup
  - JSON-RPC server on a Unix socket:
    `version`, `cards`, `ports`, `flows`, `stats`,
    `flow.start`, `flow.stop`, `flow.stats`, `flow.hist`,
    `test.arm`, `test.start`, `test.stop`, `config.load`
  - **Live config reload** (`config.load`): the daemon accepts
    a fresh YAML body over RPC, parses / validates / compiles
    it, stops old flows, pushes the new program to every open
    backend, and swaps the cfg+prog atomically. Topology
    changes (cards / logical_ifs) are explicitly rejected
    because live TAP/backend swap isn't safe yet.
  - Prometheus `/metrics` exporter on `-p PORT`
- **`pktwyrm`**
  - Offline: `cards`, `ports`, `map`, `load`, `flow show`, `version`
  - Online: `rpc <method>`, `stats [--watch]`, `flow start|stop`,
    `flow stats`, `test arm|start|stop`, `hist latency --flow N`,
    `load <config.yaml> --socket PATH` (live deploy)
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
  - `make -C sim sim_csr`: 24 / 24 assertions exercising the CSR
    window pipeline (AXI-Lite-style writes → shadow → commit →
    typed classifier table → data plane).
  - `make -C sim sim_flow`: 16 / 16 assertions for the flow-table
    window (per-port flow-gen inputs decoded from
    `pwfpga_flow_config` rows, lowest-indexed enabled row wins
    per egress port, atomic commit, disable via re-commit).
  - `make -C sim sim_stats`: 16 / 16 assertions for the stats
    snapshot window (per-port + per-flow counters latched on
    trigger, wire-format byte offsets match `pw_port_stats` /
    `pw_flow_stats`, re-trigger replaces the shadow).
  - `make -C sim sim_lat`: 16 / 16 assertions for the BRAM-backed
    per-flow latency histogram (`pw_lat_histogram`): accumulate via
    per-port checker events, live addressed read through
    `PWFPGA_WIN_HISTOGRAM` (NUM_BUCKETS u64s per flow at
    `lfid * PWFPGA_FLOW_HIST_STRIDE`), and clear.
  - `make -C sim sim_full`: 12 / 12 assertions exercising the
    full `pw_csr_full` AXI4-Lite slave end-to-end: identity
    reads, classifier write+commit through `axi_write`, stats
    snapshot trigger latches counters readable via the
    snapshot window, histogram trigger latches readable buckets.
  - `make -C sim sim_top`: 4 / 4 assertions exercising the
    `pwfpga_top_phase3` end-to-end loop: AXI-Lite host writes
    program both windows, the data plane emits frames via the
    AXIS serializer, the TB loops port-0 TX into port-1 RX
    through the deserializer, classifier hits TEST_RX, and the
    snapshot RPC reports rx_frames > 0. ARP on RX[0] raises
    the punt AXIS path.
  - `make -C sim sim_vec`: 25 / 25 assertions for the C ↔ SV
    wire-format byte-vector regression. A C-side generator
    (`sw/build/gen_bar_vectors`) drives the real
    `pw_bar_backend` ops against a tmpfs BAR, dumps the post-
    write image as a `$readmemh` hex file, and the RTL TB
    replays those dwords through `pw_csr_full` and verifies the
    decoded `pw_classifier_table_t` and per-port flow_gen
    inputs match what the host wrote. Drift in either side
    (csr.h struct layout, classifier_window byte offsets,
    flow_window byte offsets) fails this test before silicon
    ever boots.
- **CSR window RTL (Phase 3 ↔ BAR backend hookup)**
  - `rtl/shared/pw_csr_window.sv` &mdash; generic windowed-row CSR
    table with shadow + write-1-to-commit semantics. Parameters:
    `DEPTH`, `ROW_BYTES`, `WIN_BASE`, `COMMIT_OFFSET`. Live rows
    are exposed as packed byte arrays with byte 0 in the low bits,
    matching the AXI-Lite little-endian wire format.
  - `rtl/phase3/pw_classifier_window.sv` &mdash; adapts the wire-
    format `pwfpga_classifier_entry` rows into the typed
    `pw_classifier_table_t` that `pw_data_plane` consumes.
  - `rtl/phase3/pw_flow_window.sv` &mdash; adapts the wire-format
    `pwfpga_flow_config` rows into per-egress-port flow-generator
    inputs (token bucket Q16.16 tokens/cycle, burst bytes, MAC /
    IP / UDP / VLAN). The lowest-indexed enabled row binds to each
    `egress_local_port`.
  - Wire additions to `pwfpga_flow_config`:
    `tokens_per_tick_fp` (Q16.16 bytes/cycle, host-precomputed
    from `rate_bps` and `PWFPGA_DATA_PLANE_CLOCK_HZ`) and
    `burst_bytes`. The host flow compiler now populates both.
  - `rtl/phase3/pw_stats_snapshot.sv` &mdash; on
    `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER` write, latches the live
    per-flow counters from `pw_test_rx_checker` and the per-port
    drop counters from the data plane into a shadow byte region
    whose layout matches `struct pw_port_stats` /
    `struct pw_flow_stats`. Reads served via `rd_addr/rd_data`.
  - Wire fix: `PWFPGA_FLOW_STATS_BASE` moved from `0x80` to
    `0x100` to keep the per-port stats area (2 × 128 B) from
    overlapping per-flow stats inside the snapshot window.
  - `rtl/phase3/pw_histogram_snapshot.sv` &mdash; same trigger
    semantics, separate window. Stores `NUM_BUCKETS` u64s per
    flow starting at `lfid * PWFPGA_FLOW_HIST_STRIDE`. Reads
    served via `rd_addr/rd_data`.
  - `rtl/phase3/pw_csr_full.sv` &mdash; AXI4-Lite slave (16-bit
    address) that wraps the identity registers and the four
    windows under one decode. Single write-strobe drives all
    four windows; a write to `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER`
    latches the stats and histogram shadows in lockstep.
  - `rtl/phase3/pwfpga_top_phase3.sv` &mdash; board-agnostic
    integration top wiring `pw_csr_full` + `pw_data_plane`
    + per-port AXIS serializer / deserializer pair + a punt
    AXIS master. Per-board tops (e.g. AS02MC04) bring their
    PCIe → AXI-Lite bridge and 10G MAC IP around this core.
  - Wire change: `PWFPGA_CLS_FLAG_ENABLE` (bit 0 of
    `pwfpga_classifier_entry.flags`); the RTL ignores any row
    whose ENABLE bit is clear, and the host flow compiler sets
    it for every TEST_RX and PUNT_TO_HOST row.
- **Kernel driver (Phase 11 starting point)**
  - `kernel/packetwyrm.c` &mdash; out-of-tree PCI skeleton:
    `pci_driver` match on `10ee:a502`, BAR0 ioremap, identity-
    register read, dev_info dump.
  - `kernel/Kbuild` + `kernel/Makefile` for building against
    `linux-headers-$(uname -r)`.
  - `docs/design/kernel-driver.md` scoping doc: when the kernel
    driver becomes desirable vs. sticking with the userspace TAP
    plane, target architecture (NAPI / DMA / ethtool / devlink),
    coexistence rules, risks.

- **Tests**
  - `sw/libpacketwyrm/schema/packetwyrm.schema.json` &mdash;
    JSON Schema (Draft 2020-12) mirror of
    `docs/design/yaml-schema.md`. Informative only (the C
    validator is authoritative); useful for editor plugins
    (vscode-yaml, etc.) and a forcing function to keep the
    schema and the docs in sync.
  - `scripts/check-schema.sh` &mdash; optional dev tool that
    validates the example configs against the schema when
    `python3 + jsonschema + PyYAML` are installed (skips
    cleanly otherwise).
  - `make -C sw test`: 164 / 164 unit-test assertions across
    YAML / validator / flow compiler / backend (fake + BAR
    window writes / stats reads) / PCI discovery / host_plane /
    TAP / IPC
  - `make -C sw e2e`: shell-based daemon ↔ CLI smoke - launches
    packetwyrmd against an example config and walks the full
    JSON-RPC surface from pktwyrm, including `config.load`
    (same-topology accepted, different-topology rejected).
    18 / 18 checks.
  - `make -C sim/cocotb all`: Scapy + cocotb unit suite for the
    Phase 3 sub-modules. 17 / 17 Python assertions across
    `pw_parser`, `pw_classifier`, and `pw_flow_gen` behavioural
    mirrors. Runs under Icarus Verilog (the system Verilator
    5.020 predates cocotb 2.x's 5.036 minimum); the small
    behavioural RTL under `sim/cocotb/rtl/` mirrors the spec
    of the production modules on Icarus-friendly flat ports.
    The Verilator SV suite remains the integration gate against
    the production RTL.

### Documentation

- Initial design docs under `docs/design/` and phase plan under
  `docs/phases/`
- README updated to reflect the current implementation status
- Per-board bring-up notes in `fpga/as02mc04/docs/`
- This CHANGELOG
- RPC reference: `docs/design/rpc-protocol.md`
- Getting-started: `docs/guides/getting-started.md`
