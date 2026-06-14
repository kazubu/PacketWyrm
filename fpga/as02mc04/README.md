# AS02MC04 board-support &mdash; Phase 1 bring-up

Goal of this phase: produce a bitstream that

1. configures the on-board Kintex UltraScale+ KU3P
   (`xcku3p-ffvb676-1-e`, JTAG IDCODE `0x04a63093`),
2. blinks the `led_hb` LED (B9) at 1 Hz,
3. enumerates as a PCIe Gen3 endpoint, and
4. exposes a 64 KB BAR0 whose first 32-bit word is the PacketWyrm
   `device_id` (`0xA502BEEF`) followed by `version`, `build_id`,
   `git_hash`, `capabilities`, and the port / table size registers.

Once `lspci` sees the card and `bringup-check.sh` validates the
identity registers, Phase 1 is done. SFP+ MAC / PCS, classifier,
flow generator, slow-path DMA and Linux daemon integration ride on
this foundation in Phases 2&ndash;5.

## Pin assignments

Fully populated in `xdc/pinout.xdc`. All values are derived from:

- **Julia Desmazes**' reverse engineering article
  &mdash; <https://essenceia.github.io/projects/alibaba_cloud_fpga/>
  (100 MHz LVDS clock, 156.25 MHz MGT refclk, LEDs, JTAG, IDCODE).
- **Alex Forencich**'s **Taxi** AS02MC04 board support
  &mdash; <https://github.com/fpganinja/taxi> (MIT)
  (full PCIe / SFP+ / control-pin pinout).

| Function                | Pin(s)              | Bank / Function        |
|-------------------------|---------------------|------------------------|
| 100 MHz LVDS sysclk     | `E18` / `D18`       | bank 67, IS_GLOBAL_CLK |
| PCIe MGT refclk (100 M) | `T7` / `T6`         | MGTREFCLK1_225         |
| PCIe PERST#             | `A9`                | LVCMOS33               |
| PCIe Gen3 x8 lanes      | banks 224 + 225     | GTYE4 X0Y0..X0Y7       |
| Heartbeat LED `led_hb`  | `B9` (DS5)          | LVCMOS33               |
| User LEDs `led[0..3]`   | `B11`, `C11`, `A10`, `B10` | LVCMOS33        |
| SFP+ MGT refclk (Phase 2) | `K7` / `K6`       | MGTREFCLK0_227, 156.25 MHz |
| SFP+ port 0 (Phase 2)   | `A4`/`A3`, `B7`/`B6`| GTYE4 X0Y15            |
| SFP+ port 1 (Phase 2)   | `B2`/`B1`, `D7`/`D6`| GTYE4 X0Y14            |

> **Voltage note**: many AS02MC04 LVCMOS interfaces silk-screened as
> "1.8 V" are actually wired at 3.3 V. The XDC uses `LVCMOS33`
> everywhere it matters, following the Taxi board support.

## Source layout

```
fpga/as02mc04/
├── src/
│   ├── pwfpga_top_phase1.sv      Phase 1 top-level
│   ├── clock_reset.sv            sysclk -> 100 MHz + reset sync
│   ├── pcie_axi_lite_bridge.sv   thin shim over the PCIe Gen3 IP
│   └── pcie_gen3_stub.sv         placeholder until `make ip` runs
├── xdc/
│   ├── pinout.xdc                full real pin assignments
│   ├── timing.xdc                clock definitions + false paths
│   └── physical.xdc              CFGBVS / SPIx4 boot settings
├── ip/
│   ├── pcie_gen3.tcl             generates `pcie_gen3_wrapper`
│   └── clk_wiz.tcl               (optional) MMCM housekeeping
├── docs/
│   └── jtag-bringup.md           OpenOCD + J-Link workflow
├── project.tcl                   reproducible project creation
├── Makefile                      project / synth / impl / program / lint
└── scripts/
    ├── program.tcl               JTAG programmer
    ├── lint.sh                   Verilator lint of all Phase 1 RTL
    └── bringup-check.sh          host-side identity-register check
```

Board-agnostic RTL (the CSR fabric, heartbeat, timestamp counter,
shared package) lives in `../../rtl/shared/` and is consumed by the
project script.

## Required prerequisites

| Item                                  | Where to get it                       |
|---------------------------------------|---------------------------------------|
| Vivado ML Standard 2023.2+ (free)     | AMD/Xilinx — the free WebPACK/Standard edition covers xcku3p / xcku5p; no Enterprise licence needed |
| AS02MC04 board                        | eBay / second-hand                    |
| JTAG cable (J-Link / USB Blaster /    | Any 4-GPIO TAP-driving probe;         |
| FT232H)                               | see `docs/jtag-bringup.md`            |
| Linux host with a free PCIe Gen3 slot | x8 ideally; x1 also works (downgrade) |
| Active cooling for the FPGA           | KU3P runs hot                         |

## Build flow

```sh
cd fpga/as02mc04

# 1. Create the Vivado project (no synth, stub PCIe)
make project

# 2. Generate the PCIe AXI-Bridge IP (xdma, AXI Bridge mode).
#    FIRST TIME ONLY: reconcile CONFIG keys + reconcile the bridge
#    against the generated .veo -- see "PCIe IP" note below.
make ip

# 3. Synthesise (synth/impl auto-set use_ip=1: real IP, stub dropped)
make synth

# 4. Implement + write bitstream
make impl

# 5. Program over JTAG (set HW_TARGET to the JTAG cable serial / glob)
make program HW_TARGET=*jlink*
```

> **PCIe IP (read before the first `make ip`).** Phase 1 needs BAR0 as
> a memory-mapped AXI4-Lite master, so `ip/pcie_gen3.tcl` generates the
> **DMA/Bridge Subsystem for PCIe** (`xdma`) in **AXI Bridge** mode --
> *not* the bare `pcie4_uscale_plus` integrated block, which only
> exposes the AXI-Stream transaction layer. Two version-specific steps
> on first build: (1) if Vivado rejects an `xdma` `CONFIG.*` key,
> set the same intent in the IP GUI and copy its `set_property -dict`
> back into `ip/pcie_gen3.tcl`; (2) reconcile `src/pcie_axi_lite_bridge.sv`
> against the generated `pcie_gen3_wrapper.veo` instantiation template
> (port names drift -- see the comment block in that file).
> `project.tcl` auto-sets `use_ip=1` for `synth`/`impl` and then drops
> `src/pcie_gen3_stub.sv` (both define `pcie_gen3_wrapper`). Force the
> stub build with `make synth` `... -tclargs use_ip=0` only for a
> LED/timing smoke test -- PCIe will not enumerate.

If you prefer OpenOCD (no licensed Vivado on the lab box), generate
the SVF from Vivado and follow `docs/jtag-bringup.md` &mdash; that
recipe is verified working on AS02MC04 via Segger J-Link and Altera
USB Blaster.

A ready-to-use OpenOCD config for the **Digilent JTAG-HS3** cable
ships in `openocd/as02mc04-hs3.cfg`. The IDCODE read has been
verified against a real board:

```sh
openocd -f openocd/as02mc04-hs3.cfg -c "init; scan_chain; exit"
# Info : JTAG tap: xcku3p.tap tap/device found: 0x04a63093
#        (mfg: 0x049 (Xilinx), part: 0x4a63, ver: 0x0)
```

The HS3 (and HS2) probe is an FT232H reporting USB `0403:6014`. The
OpenOCD `60-openocd.rules` udev rule grants the `plugdev` group
access; if the rule was installed while the probe was already
plugged in, replug it (or `sudo udevadm control --reload &&
sudo udevadm trigger`) so the rule applies.

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
[hh:mm:ss] 1. searching for 10ee:a502 via lspci ...
[hh:mm:ss]    found at 03:00.0
[hh:mm:ss] 2. checking BAR0 ...
[hh:mm:ss]    BAR0 size = 65536 bytes
[hh:mm:ss] 3. reading identity registers from BAR0 ...
   device_id=0xa502beef version=0x00010000 build=0x...   git=0x...
   caps=0x00000000 nports=0x00000002 nflows=0x00000000 nifs=0x00000000
[hh:mm:ss] OK: AS02MC04 Phase 1 bring-up checks passed.
```

> The original Alibaba bitstream that ships on second-hand boards
> enumerates as `dabc:1017` (class `0x020000` Ethernet) &mdash; if
> you see that vendor / device ID, the board is alive but still
> running its factory NIC firmware. After PacketWyrm programming the
> ID changes to **`10ee:a502`** (Xilinx vendor / PacketWyrm device,
> subsystem `10ee:7e57`). See `docs/design/pci-ids.md` for the
> rationale behind those values.

`packetwyrmd` Phase 4 reads the same registers through the
forthcoming BAR backend (`pw_bar_backend_open`). Phase 1 only proves
that the BAR is reachable and the FPGA presents the right identity.

## Definition of done

| Check                                                       | Status |
|-------------------------------------------------------------|--------|
| JTAG IDCODE reads as `0x04a63093` (KU3P)                    | ✅ (HS3) |
| Bitstream loads without errors                              |        |
| `led_hb` blinks at ~1 Hz                                    |        |
| `led[1]` is high (PCIe link up)                             |        |
| `lspci -d 1af4:a502` returns the card                       |        |
| `bringup-check.sh` prints `device_id=0xa502beef`            |        |
| BAR0 size in sysfs matches the IP configuration (64K)       |        |
| Timing report closes (no negative WNS / WHS)                |        |

When every row is checked, Phase 2 (10G MAC / PCS frame loopback)
starts.

## Why we are not just using Taxi / Corundum

Alex Forencich's **Corundum** project (built on the **Taxi** RTL
library) already provides a working high-performance NIC bitstream
for the AS02MC04 and even a Linux driver. PacketWyrm builds a
different thing &mdash; an FPGA-side packet generator + classifier +
loss / latency / jitter tester &mdash; so the data plane is
custom. The board-support work (XDC, IP configuration, SPI flash
boot mode) is identical and is borrowed from Taxi with attribution.

If you only want a NIC on this card, Corundum is the right answer;
PacketWyrm is the right answer if you want to drive line-rate
synthetic traffic and measure what the DUT does to it.
