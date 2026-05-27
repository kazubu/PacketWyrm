# AS02MC04 board-support &mdash; Phase 1 bring-up

Goal of this phase: produce a bitstream that

1. configures the on-board Kintex UltraScale+ KU3P,
2. blinks a heartbeat LED at 1 Hz,
3. enumerates as a PCIe Gen3 endpoint, and
4. exposes a 64 KB BAR0 whose first 32-bit word is the PacketWyrm
   `device_id` (`0xA502BEEF`) followed by `version`, `build_id`,
   `git_hash`, `capabilities`, and the port / table size registers.

Once `lspci` sees the card and `bringup-check.sh` validates the
identity registers, Phase 1 is done. SFP+ MAC / PCS, classifier,
flow generator, slow-path DMA and Linux daemon integration ride on
this foundation in Phases 2&ndash;5.

## Source layout

```
fpga/as02mc04/
├── src/
│   ├── pwfpga_top_phase1.sv      Phase 1 top-level
│   ├── clock_reset.sv            sysclk -> 100 MHz + reset sync
│   ├── pcie_axi_lite_bridge.sv   thin shim over the PCIe Gen3 IP
│   └── pcie_gen3_stub.sv         placeholder until `make ip` runs
├── xdc/
│   ├── pinout.xdc                ALL pin assignments (TODO)
│   ├── timing.xdc                clock-domain crossings + false paths
│   └── physical.xdc              bitstream config / SPI flash mode
├── ip/
│   ├── pcie_gen3.tcl             generates `pcie_gen3_wrapper`
│   └── clk_wiz.tcl               MMCM for the 100 MHz housekeeping
├── project.tcl                   reproducible project creation
├── Makefile                      project / synth / impl / program
└── scripts/
    ├── program.tcl               JTAG programmer
    └── bringup-check.sh          host-side identity-register check
```

Board-agnostic RTL (the CSR fabric, heartbeat, timestamp counter,
shared package) lives in `../../rtl/shared/` and is consumed by the
project script. Future 25G or alternate-board projects reuse it.

## Required prerequisites

| Item                                  | Where to get it                       |
|---------------------------------------|---------------------------------------|
| Vivado 2023.2+ (UltraScale+ licence)  | Xilinx                                |
| AS02MC04 schematic                    | Alibaba Cloud / board vendor          |
| JTAG cable (FTDI / Xilinx HW-USB)     |                                       |
| Linux host with a free PCIe Gen3 slot |                                       |

## Pin assignments (TODO)

Every entry in `xdc/pinout.xdc` marked `AS02MC04_PIN_TBD` must be
filled in from the AS02MC04 schematic before the bitstream is
usable. The placeholders compile but place silently to wrong pads;
this is intentional &mdash; the rest of the project (RTL, IP,
build flow) can be verified before the board is in front of you.

Concretely, fill in:

- PCIe x8 lanes (refclk + PERST# only; lane RX / TX pairs are
  auto-placed by the PCIe Gen3 IP based on its GTY quad selection).
- Board reference clock pair (LVDS, MMCM-capable bank).
- Board reset (push button / PERST# fanout).
- 4 user LEDs.
- (Phase 2) Two SFP+ cages and the 156.25 MHz refclk for the GTY
  quad driving them.

The PCIe IP itself is configured in `ip/pcie_gen3.tcl`. The Vendor /
Device IDs there (`0x1AF4 / 0xA502`) are placeholders; replace with
the AS02MC04 PCI ID allocation before final production.

## Build flow

```sh
cd fpga/as02mc04

# 1. Create the Vivado project (no synth)
make project

# 2. (Once you have a licensed UltraScale+ Vivado in front of the
#    real board) generate the Xilinx PCIe Gen3 + MMCM IP
make ip

# 3. Synthesise
make synth

# 4. Implement + write bitstream
make impl

# 5. Program over JTAG (set HW_TARGET to the JTAG cable serial)
make program HW_TARGET=*ftdi*
```

Outputs: `build/pwfpga_as02mc04_phase1/.../pwfpga_top_phase1.bit`.

## Host-side bring-up checklist

After programming the bitstream:

```sh
# Trigger a PCIe rescan so the kernel notices the new endpoint
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'

# Verify identity registers via BAR0
sudo fpga/as02mc04/scripts/bringup-check.sh
```

Expected output:

```
[hh:mm:ss] 1. searching for 1af4:a502 via lspci ...
[hh:mm:ss]    found at 03:00.0
[hh:mm:ss] 2. checking BAR0 ...
[hh:mm:ss]    BAR0 size = 65536 bytes
[hh:mm:ss] 3. reading identity registers from BAR0 ...
   device_id=0xa502beef version=0x00010000 build=0x...   git=0x...
   caps=0x00000000 nports=0x00000002 nflows=0x00000000 nifs=0x00000000
[hh:mm:ss] OK: AS02MC04 Phase 1 bring-up checks passed.
```

`packetwyrmd` Phase 4 reads the same registers through the
forthcoming BAR backend (`pw_bar_backend_open`). Phase 1 only proves
that the BAR is reachable and the FPGA presents the right identity.

## Definition of done

| Check                                                  | Status |
|--------------------------------------------------------|--------|
| JTAG identifies the FPGA                               |        |
| Bitstream loads without errors                         |        |
| `led[0]` blinks at ~1 Hz                               |        |
| `led[1]` is high (PCIe link up)                        |        |
| `lspci -d 1af4:a502` returns the card                  |        |
| `bringup-check.sh` prints `device_id=0xa502beef`       |        |
| BAR0 size in sysfs matches the IP configuration (64K)  |        |
| Timing report closes (no negative WNS / WHS)           |        |

When every row is checked, Phase 2 (MAC / PCS frame loopback) starts.

## What gets removed in Phase 2

`pcie_gen3_stub.sv` ships only so the project synthesises before the
Xilinx IP is generated. As soon as `make ip` has produced
`pcie_gen3_wrapper` from the IP catalog, the stub becomes dead code
and is excluded from the synthesis fileset in `project.tcl`. Track
that swap explicitly when Phase 2 lands.
