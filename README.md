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
  JSON Schema mirror, duplicate-id + unknown-port rejection; cross-card
  latency is supported via J5 GPIO time-sync, not rejected),
  flow compiler, software fake-card backend, real BAR-mmap backend,
  sysfs PCI discovery, Linux TAP device control, host packet plane
  (TAP &harr; FPGA punt / inject bridge), Unix-socket JSON RPC,
  Prometheus `/metrics` exporter.
- **`packetwyrmd`** &mdash; long-running daemon. Loads YAML, opens a
  real backend per card; a BAR-open failure is fatal unless `-F` /
  `--allow-fake` is passed (then it falls back to the no-op fake
  backend, for dev/CI), creates one Linux TAP per logical interface,
  spawns per-card worker threads, exposes a control socket. Live
  `config.load` reload deploys a new program without restart.
- **`pktwyrm`** &mdash; CLI. Offline subcommands work on YAML files
  (`pktwyrm cards / ports / map / load / flow show`). Online
  subcommands talk to a running `packetwyrmd` over the control
  socket (`pktwyrm stats`, `pktwyrm flow`, `pktwyrm test`,
  `pktwyrm hist`, `pktwyrm rpc ...`).
- **Phase 3 RTL** &mdash; SystemVerilog data plane that parses
  Ethernet (+ optional VLAN / QinQ) / IPv4 / IPv6 / TCP / UDP, runs
  a priority classifier with `DROP / TEST_RX / PUNT_TO_HOST /
  MIRROR_TO_HOST / FORWARD_PORT` actions, generates IPv4/UDP test
  packets with sequence + timestamp via a Q16.16 token-bucket
  scheduler, and checks RX for per-flow loss / duplicate /
  out-of-order plus per-flow min/max/sum/count latency and a
  power-of-two latency histogram (BRAM-backed). The 64-bit AXIS
  streams straight from the MAC into the data plane (no wide-frame
  serializer); `pwfpga_top_phase3` integrates the data plane + CSR
  window (`pw_csr_full` AXI4-Lite slave) + punt-AXIS path. On the
  AS02MC04 it runs on silicon at 32 flows / 16 classifier rows / 16
  latency bins, loss=0 at line rate, with egress hardware
  timestamping (per-flow DUT latency), a CSR data-plane soft-reset,
  live SPI-flash write over PCIe (`pktwyrm flash`), and in-band
  reconfiguration via ICAP (`pw_reboot`). The classifier `FORWARD_PORT`
  action (host-selectable egress port) and the full slow path are on
  silicon too: **PUNT_TO_HOST / MIRROR_TO_HOST RX** and **host&rarr;FPGA
  TX inject** ride a **PCIe-DMA slow path** (`pw_dma_slowpath`, XDMA
  AXI-Stream) &mdash; validated end-to-end on hardware by a full cRPD
  dual-stack control plane across the DUT (ARP/ND, ping, BGP+BGP-v6,
  OSPFv2/OSPFv3, IS-IS) at MTU 9000. The legacy BAR-polled
  `pw_punt_rx_window` (0x1000) / `pw_inject_tx_window` (0x0D00) remain
  only for the older non-DMA bitstream.
- **Lab / container integration** &mdash; `tools/pktwyrm-tinet/`
  turns a small lab spec into a [tinet](https://github.com/tinynetwork/tinet)
  topology + per-router FRR configs that boot N routing containers
  each bound to a PacketWyrm TAP. One command (`pktwyrm-tinet up
  lab.yaml`) starts `packetwyrmd`, waits for TAPs, runs `tinet up`
  and `tinet conf`. State persists under `<out>/.pktwyrm-lab.json`
  so `down` / `conf` / `status` work standalone.
- **AS02MC04 FPGA build** &mdash; reproducible `project_phase3.tcl`
  builds the full Phase 1+2+3 bitstream (PCIe + dual 10GBASE-R +
  streaming data plane), closes timing at 156.25 MHz, and is flashed
  to the on-board SPI as the cold-boot image. Real pin assignments
  (refclk / PERST# / LEDs / PCIe x8 / SFP+ MGT), JTAG program/flash
  recipes (`make program` / `make flash`), and host tools for live
  flash update (`pw_flash`) and in-band reboot (`pw_reboot`).

| Phase | Layer                     | Status            |
|-------|---------------------------|-------------------|
| 0     | data model + YAML         | done              |
| 0.5   | PCI vendor/device         | `10ee:a502`       |
| 1     | KU3P PCIe bring-up        | done on HW        |
| 2     | SFP+ MAC / PCS            | done on HW        |
| 3     | data-plane RTL            | done on HW        |
| 4     | BAR-mmap backend          | done              |
| 5     | TAP + host plane          | done              |
| 6     | multi-card mgmt           | done              |
| 7     | cross-card flows          | done              |
| 8     | container labs            | done              |
| 11    | kernel netdev driver      | skeleton          |

(Details of the on-hardware Phase 1–3 results are in the bullets above.)

Test surface today (all green):

| Command                            | Covers                              |
|------------------------------------|-------------------------------------|
| `make -C sw test`                  | host unit tests                     |
| `make -C sw e2e`                   | daemon &harr; CLI smoke             |
| `make -C sim sim_all`              | Verilator RTL testbench suite       |
| `make -C sim/cocotb all`           | Scapy-driven RTL units              |
| `make -C tools/pktwyrm-tinet test` | lab generator + orchestrator        |
| `make -C fpga/as02mc04 lint`       | RTL lint                            |
| `make -C kernel`                   | kernel module build                 |

CI runs the host job (build + `make test` + `make e2e` + staged
install) and the RTL job (`make sim_all` + AS02MC04 lint).

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
| Control socket      | `/run/packetwyrm/packetwyrmd.sock` |
| TAP / netdev format | `tap-pw-p<gport>-v<vlan>`           |

`AS02MC04` may appear only in board-support code and hardware docs;
no user-facing command, interface, or config name uses `as02`.

## Repository layout

```
rtl/
├── shared/             board-agnostic RTL: pw_pkg, pw_csr_min,
│                       pw_heartbeat, pw_timestamp, ...
└── phase3/             Phase 3 data plane: parser, classifier,
                        flow_gen (Q16.16 token bucket), test_rx_checker
                        (loss / dup / OOO / per-flow latency + histogram),
                        tx arbiter, AXIS serializer/deserializer,
                        pw_csr_full AXI-Lite slave, pwfpga_top_phase3.
fpga/as02mc04/          AS02MC04 Vivado project, XDC, IP TCL,
                        JTAG bring-up scripts.
sw/libpacketwyrm/       C library: data model, YAML, JSON Schema,
                        flow compiler, backend abstraction
                        (fake + BAR), PCI discovery, TAP control,
                        host packet plane, JSON RPC.
sw/packetwyrmd/         Long-running daemon (per-card worker threads).
sw/pktwyrm/             Command-line client.
sw/tests/unit/          Unit tests (`make -C sw test`).
sw/tests/integration/   e2e_smoke.sh - daemon + CLI shell smoke
                        (`make -C sw e2e`).
kernel/                 Phase 11 out-of-tree PCI skeleton driver
                        (`make -C kernel`).
sim/                    SystemVerilog testbenches: data_plane,
                        axis, csr/csr_full, flow, stats, hist,
                        phase3_top, wire_vectors. `make sim_all`.
sim/cocotb/             Scapy + cocotb unit suite (Icarus-driven)
                        for parser / classifier / flow_gen behavioural
                        mirrors.
tools/pktwyrm-tinet/    Lab generator + orchestrator
                        (PacketWyrm + FRR-in-container via tinet).
configs/examples/       single-card.yaml, multi-card.yaml,
                        container-frr/ (bare netns recipe),
                        lab-frr-2node/ (tinet-driven two-router lab).
scripts/                udev rule, packaging helpers.
docs/                   design notes (architecture, ID system, CSR
                        map, daemon, flow compiler, ...).
```

### Standalone hardware tools (`sw/tests/`, vfio/BAR)

Single-shot diagnostics that talk to a real card directly (run as
`sudo env PW_BACKEND=vfio sw/build/<tool> <pci-bdf> ...`; build with
`make -C sw <tool>`). They bypass the daemon, so stop `packetwyrmd`
first (it holds the device).

| Tool                 | What it does                                                        |
|----------------------|---------------------------------------------------------------------|
| `pw_card_probe`      | Read + verify the identity block (device_id / version / build / git). |
| `pw_sfp_test`        | SFP+ link / block-lock status check.                                |
| `pw_phase3_loopback` | Program one flow, loop SFP0<->SFP1 over a DAC, report loss/latency. |
| `pw_phase3_forward`  | Validate the SAF `FORWARD_PORT` path; `[fwd_egress]` picks the port. |
| `pw_phase3_punt`     | Validate the PUNT/slow-path: punt frames to the host, check lif + length. |
| `pw_phase3_inject`   | Validate slow-path TX: inject a frame, loop it back via PUNT, byte-compare. |
| `pw_flash`           | Live in-system SPI config-flash erase/program/verify over PCIe.     |
| `pw_reboot`          | Trigger in-band ICAP IPROG reconfiguration from flash.              |
| `gen_bar_vectors`    | Dump the post-write BAR byte image (drives the `sim_vec` regression). |

## Try it (no FPGA required)

```sh
# Host stack
make -C sw            # libpacketwyrm + packetwyrmd + pktwyrm
make -C sw test       # host unit tests
make -C sw e2e        # daemon <-> CLI smoke

# Daemon against the example single-card config. -F/--allow-fake permits the
# no-op fake backend when no card's BAR can be opened (without it a BAR-open
# failure is a hard error, so -F is required for a no-FPGA run).
sudo ./sw/build/packetwyrmd -v -F -c configs/examples/single-card.yaml &
sudo ./sw/build/pktwyrm stats          # pretty table, refresh with --watch MS
./sw/build/pktwyrm rpc cards           # raw JSON RPC

# RTL (Verilator >= 5 for sim_all; Icarus >= 12 + cocotb 2 for sim/cocotb)
make -C sim sim_all                    # SystemVerilog testbenches (Verilator)
make -C sim/cocotb all                 # Scapy-driven units

# Lab / container integration (no FPGA still works for the
# generator + wiring smoke; docker + tinet are only needed at
# bring-up time)
make -C tools/pktwyrm-tinet test       # generator + orchestrator
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet up \
    configs/examples/lab-frr-2node/lab.yaml -o /tmp/lab-frr/
```

The daemon needs `CAP_NET_ADMIN` to create TAP devices; running it
as root (or with the udev rule in `scripts/`) is fine for the dev
container.

## Packaging / releases

```sh
make -C sw deb        # -> packaging/dist/packetwyrm_<version>_<arch>.deb
```

Pushing a version tag builds the `.deb` in GitHub Actions and publishes it as a
release asset (`.github/workflows/release.yml`); the package version comes from
the tag, so use a leading-digit semver:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

## Documentation

Start here:

- **`docs/guides/`** &mdash; **operator guides** (start at
  `docs/guides/README.md`): installation, configuration, running tests, the
  CLI reference, the Web GUI, monitoring, firmware updates, troubleshooting.
- `NEXT-STEPS.md` &mdash; **read this first if you're picking the
  project up.** Priority-ordered TODO + Verilator hazards we hit.
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
- `docs/design/kernel-driver.md` &mdash; Phase 11 kernel netdev
  driver scoping + skeleton
- `docs/phases/plan.md` &mdash; phase-by-phase implementation plan
- `docs/phases/poc-phase-1-3.md` &mdash; single-card PoC plan
- `docs/phases/multi-card-phase-6-7.md` &mdash; multi-card extension plan
- `docs/test-plan.md` &mdash; RTL simulation and host integration tests
- `docs/risks.md` &mdash; priority-ordered risk list
- `sim/README.md` &mdash; SV testbench catalogue (data_plane, axis,
  csr, csr_full, flow, stats, hist, phase3_top, wire_vectors)
- `sim/cocotb/README.md` &mdash; Scapy + cocotb unit suite
- `tools/pktwyrm-tinet/README.md` &mdash; lab generator + orchestrator
- `fpga/as02mc04/docs/jtag-bringup.md` &mdash; OpenOCD + J-Link recipe

## Known limitations

This is an active, pre-release project (v0.1.0). Known open items:

- **Kernel driver is a probe-only skeleton** &mdash; no ioctl / mmap / chardev /
  netdev. The userspace vfio + BAR-mmap path is the supported one; the
  in-kernel netdev is Phase 11, not yet built.
- **Single / low-flow IPv6 loopback is low-volume on the current rig** &mdash;
  the stock `phase3-ipv6.yaml` reproduces a very low rx while IPv4 multiflow
  runs at line rate; IPv6 at higher flow counts loops clean (loss=0). Under
  investigation (DAC / MAC-PCS / IPv6 classification behaviour).
- **Cross-card latency deep-underflow edge** &mdash; one-way latency is measured
  and corrected per flow, but the clamp behaviour at extreme timebase skew is a
  known edge (see the `xcard-latency-wrap` note); normal operation is unaffected.

See `NEXT-STEPS.md` for the full priority-ordered list.

## Licensing

PacketWyrm is **split-licensed** (see `LICENSE` for the full explanation):

- **Host software** (`sw/`, plus `tools/`, `configs/`, `docs/`) &mdash; **MIT**
  (`LICENSE.sw`). The published `.deb` ships this software only, so the release
  artifact is MIT in its entirety.
- **FPGA gateware** (`rtl/phase3/`, `fpga/`) &mdash; **CERN-OHL-S-2.0**
  (`LICENSE.rtl`), matching the vendored Taxi 10G MAC/PCS submodule
  (`rtl/phase2/vendor/taxi`, CERN-OHL-S-2.0) it is synthesised with, so
  distributing the combined design or bitstream is reciprocity-clean.

The host software is an independent work that talks to the card over PCIe/BAR;
the hardware reciprocity licence does not reach it.

## Non-goals (initial)

PCIe SR-IOV / VF enumeration, DPDK PMD, large PCAP replay, large
packet capture, stateful TCP traffic generation, full IXIA /
Spirent-class protocol emulation, PTP / GPS / external clock sync,
and 25G are all explicitly out of scope for the first release.
10GBASE-R is the supported target.
