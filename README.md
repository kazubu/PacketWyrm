# PacketWyrm

FPGA-based multi-port IP network tester / packet generator built around the
Alibaba Cloud **AS02MC04** PCIe card (Kintex UltraScale+ KU3P, dual SFP+).

PacketWyrm runs the high-rate data plane in the FPGA and a Linux host control /
management plane in userspace. Test traffic is generated and validated in
the FPGA; ARP, ND, LLDP, BGP, OSPF, IS-IS, ICMP and other low-rate control
packets are punted to per-logical-interface TAP devices so that routing
daemons (FRR / BIRD) running in containers can peer with a DUT through the
tester ports.

The system is designed for **multi-card scale-out** from day one: one card
yields 2 ports, two cards yield 4, eight cards yield 16. The userspace
daemon owns global IDs (`card_id`, `global_port_id`, `global_flow_id`,
`logical_if_id`); each FPGA bitstream remains card-local and identical
across slots.

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
| TAP / netdev prefix | `pw-`                               |

`AS02MC04` may appear only in board-support code and hardware docs; no
user-facing command, interface, or config name uses `as02`.

## Repository layout

```
rtl/                   shared / vendor-neutral RTL pieces
fpga/as02mc04/         AS02MC04 Vivado project, XDC, board-support RTL
sw/libpacketwyrm/      C host-side library (data model, flow compiler, ...)
sw/packetwyrmd/        userspace daemon (control / management plane)
sw/pktwyrm/            command-line client
sw/tests/              unit and integration tests
sim/                   RTL simulation testbenches
docs/                  architecture, ID system, CSR map, phase plans, tests
configs/               example YAML configurations
scripts/               helper scripts (setup, lint, packaging)
```

## Documentation

Start here:

- `docs/design/architecture.md` &mdash; overall architecture
- `docs/design/id-system.md` &mdash; `card_id` / `global_port_id` / `logical_if_id` / flow IDs
- `docs/design/csr-map.md` &mdash; register map, double-buffered tables
- `docs/design/rtl-modules.md` &mdash; FPGA module breakdown
- `docs/design/daemon.md` &mdash; `packetwyrmd` design
- `docs/design/tap-logical-if.md` &mdash; TAP / logical interface model
- `docs/design/flow-compiler.md` &mdash; YAML &rarr; per-card programming
- `docs/design/stats.md` &mdash; statistics aggregation
- `docs/design/yaml-schema.md` &mdash; configuration schema
- `docs/phases/plan.md` &mdash; phase-by-phase implementation plan
- `docs/phases/poc-phase-1-3.md` &mdash; single-card PoC plan
- `docs/phases/multi-card-phase-6-7.md` &mdash; multi-card extension plan
- `docs/test-plan.md` &mdash; RTL simulation and host integration tests
- `docs/risks.md` &mdash; prioritised risk list

## Building (Phase 0)

```sh
cd sw
make            # builds libpacketwyrm, packetwyrmd, pktwyrm
make test       # runs unit tests
```

Phase 0 ships compileable stubs of `packetwyrmd` / `pktwyrm` plus the
`libpacketwyrm` data model, YAML loader (offline validation), flow
compiler, and a fake-card backend so the host stack can be exercised
without FPGA hardware.

## Non-goals (initial)

PCIe SR-IOV / VF enumeration, DPDK PMD, large PCAP replay, large packet
capture, stateful TCP traffic generation, full IXIA / Spirent-class
protocol emulation, cross-card one-way latency, PTP / GPS / external
clock sync, and 25G are all explicitly out of scope for the first
release. 10GBASE-R is the supported target.
