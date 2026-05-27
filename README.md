# PacketWyrm

FPGA-based multi-port IP network tester / packet generator built around the
Alibaba Cloud **AS02MC04** PCIe card (Kintex UltraScale+ KU3P, dual SFP+).

PacketWyrm runs the high-rate data plane in the FPGA and a Linux host
control / management plane in userspace. Test traffic is generated and
validated in the FPGA; ARP, ND, LLDP, BGP, OSPF, IS-IS, ICMP and other
low-rate control packets are punted to per-logical-interface TAP devices
so that routing daemons (FRR / BIRD) running in containers can peer with
a DUT through the tester ports.

The system is designed for **multi-card scale-out** from day one: one
card yields 2 ports, two cards yield 4, eight cards yield 16. The
userspace daemon owns global IDs (`card_id`, `global_port_id`,
`global_flow_id`, `logical_if_id`); each FPGA bitstream remains
card-local and identical across slots.

## Status

The project currently ships:

- **Host stack** &mdash; data model, YAML config + validator (with
  duplicate-id + cross-card latency rejection), flow compiler,
  software fake-card backend, real BAR-mmap backend, sysfs PCI
  discovery, Linux TAP device control, host packet plane (TAP &harr;
  FPGA punt / inject bridge), Unix-socket JSON RPC.
- **`packetwyrmd`** &mdash; long-running daemon. Loads YAML, opens a
  backend per card (BAR if the card is there, fake otherwise),
  creates one Linux TAP per logical interface, runs an event loop
  that drains punt frames to TAPs and TAP reads back into FPGA
  TX, exposes a control socket.
- **`pktwyrm`** &mdash; CLI. Offline subcommands work on YAML files
  (`pktwyrm cards / ports / map / load / flow show`). Online
  subcommands talk to a running `packetwyrmd` over the control
  socket (`pktwyrm stats`, `pktwyrm rpc ...`).
- **Phase 3 RTL skeleton** &mdash; SystemVerilog data plane that
  parses Ethernet (+ optional VLAN) / IPv4 / UDP, runs a
  priority classifier with `DROP / TEST_RX / PUNT_TO_HOST /
  MIRROR_TO_HOST / FORWARD_PORT` actions, generates IPv4/UDP
  test packets with sequence + timestamp via a proper Q16.16
  token-bucket scheduler, and checks RX for per-flow loss /
  duplicate / out-of-order plus a power-of-two latency
  histogram. **`make -C sim sim`** runs a Verilator testbench
  through 29 scenario assertions (drop, punt, loopback, loss,
  duplicate, VLAN, FORWARD_PORT, out-of-order, rate).
- **AS02MC04 Phase 1 Vivado project** &mdash; reproducible
  `project.tcl`, real pin assignments (refclk / PERST# / LEDs /
  PCIe x8 lanes / SFP+ MGT) sourced from the published
  reverse-engineering work, lint-clean RTL, OpenOCD + JTAG
  bring-up recipe.

| Layer                                | Status                          |
|--------------------------------------|---------------------------------|
| Phase 0  &mdash; data model + YAML   | done                            |
| Phase 0.5 &mdash; PCI vendor/device  | `10ee:a502` (private dev IDs)   |
| Phase 1  &mdash; KU3P PCIe bring-up  | RTL + XDC + project, awaits card|
| Phase 2  &mdash; SFP+ MAC / PCS      | not yet started                 |
| Phase 3  &mdash; data-plane RTL      | functional skeleton in sim      |
| Phase 4  &mdash; BAR-mmap backend    | done                            |
| Phase 5  &mdash; TAP + host plane    | done                            |
| Phase 6  &mdash; multi-card mgmt     | the host stack already does it  |
| Phase 7  &mdash; cross-card flows    | compiler + aggregator done      |
| Phase 8+                              | container integration, ...      |

Test surface today:

- **Host:** `make -C sw test` &mdash; 116 assertions across
  YAML parsing, validator, flow compiler, fake + BAR backends,
  PCI discovery, host packet plane, TAP device control, IPC.
- **RTL:** `make -C sim sim` &mdash; Verilator, 29 assertions
  across nine scenarios end-to-end through the data-plane
  skeleton.
- **End-to-end smoke:** start the daemon against an example
  config, query it with `pktwyrm stats` / `pktwyrm rpc ...`.

## Naming

| Item                | Name                                |
|---------------------|-------------------------------------|
| Project / repo      | `packetwyrm`                        |
| CLI                 | `pktwyrm`                           |
| Userspace daemon    | `packetwyrmd`                       |
| Host-side library   | `libpacketwyrm`                     |
| systemd unit        | `packetwyrmd.service`               |
| Default config      | `/etc/packetwyrm/packetwyrm.yaml`   |
| Runtime state       | `/var/lib/packetwyrm/`              |
| Logs                | `/var/log/packetwyrm/`              |
| Control socket      | `/var/run/packetwyrm/packetwyrmd.sock` |
| TAP / netdev prefix | `pw-`                               |

`AS02MC04` may appear only in board-support code and hardware docs;
no user-facing command, interface, or config name uses `as02`.

## Repository layout

```
rtl/
├── shared/             board-agnostic RTL: pw_pkg, pw_csr_min,
│                       pw_heartbeat, pw_timestamp, ...
└── phase3/             Phase 3 data plane: parser, classifier,
                        flow_gen (token bucket), test_rx_checker
                        (loss / dup / OOO / latency histogram),
                        tx arbiter
fpga/as02mc04/          AS02MC04 Vivado project, XDC, IP TCL,
                        JTAG bring-up scripts
sw/libpacketwyrm/       C library: data model, YAML, flow compiler,
                        backend abstraction (fake + BAR), PCI
                        discovery, TAP control, host packet plane,
                        JSON RPC.
sw/packetwyrmd/         Long-running daemon.
sw/pktwyrm/             Command-line client.
sw/tests/unit/          Unit + integration tests (run as `make test`).
sim/                    Verilator testbench(s) and Makefile.
configs/examples/       single-card.yaml, multi-card.yaml
scripts/                udev rule, future packaging.
docs/                   design notes (architecture, ID system, CSR
                        map, daemon, flow compiler, ...).
```

## Try it (no FPGA required)

```sh
# Host stack
cd sw
make            # libpacketwyrm + packetwyrmd + pktwyrm
make test       # 116 assertions

# Daemon against the example single-card config (uses the fake backend)
./build/packetwyrmd -v -c ../configs/examples/single-card.yaml &
sudo ./build/pktwyrm stats     # pretty table, refreshed by --watch MS
./build/pktwyrm rpc cards      # raw JSON RPC

# RTL simulation (Verilator >= 5)
cd ../sim
make sim
```

`make -C sim sim` ends with `ALL DATA PLANE SCENARIOS PASS`. The
daemon needs `CAP_NET_ADMIN` to create TAP devices; running it as
root (or with the udev rule in `scripts/`) is fine for the dev
container.

## Documentation

Start here:

- `docs/guides/getting-started.md` &mdash; 5-minute walkthrough
- `docs/design/rpc-protocol.md` &mdash; control-socket RPC
  reference (JSON wire format + every method)
- `CHANGELOG.md` &mdash; running list of what's working
- `docs/design/architecture.md` &mdash; overall architecture
- `docs/design/id-system.md` &mdash; `card_id` / `global_port_id` /
  `logical_if_id` / flow IDs
- `docs/design/csr-map.md` &mdash; register map, double-buffered tables
- `docs/design/rtl-modules.md` &mdash; FPGA module breakdown
- `docs/design/daemon.md` &mdash; `packetwyrmd` design
- `docs/design/tap-logical-if.md` &mdash; TAP / logical interface model
- `docs/design/flow-compiler.md` &mdash; YAML &rarr; per-card programming
- `docs/design/stats.md` &mdash; statistics aggregation
- `docs/design/yaml-schema.md` &mdash; configuration schema
- `docs/design/pci-ids.md` &mdash; PCI vendor / device IDs
- `docs/phases/plan.md` &mdash; phase-by-phase implementation plan
- `docs/phases/poc-phase-1-3.md` &mdash; single-card PoC plan
- `docs/phases/multi-card-phase-6-7.md` &mdash; multi-card extension plan
- `docs/test-plan.md` &mdash; RTL simulation and host integration tests
- `docs/risks.md` &mdash; priority-ordered risk list
- `fpga/as02mc04/docs/jtag-bringup.md` &mdash; OpenOCD + J-Link recipe

## Non-goals (initial)

PCIe SR-IOV / VF enumeration, DPDK PMD, large PCAP replay, large
packet capture, stateful TCP traffic generation, full IXIA /
Spirent-class protocol emulation, cross-card one-way latency,
PTP / GPS / external clock sync, and 25G are all explicitly out
of scope for the first release. 10GBASE-R is the supported target.
