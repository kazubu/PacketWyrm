# AS02MC04 JTAG bring-up via OpenOCD

The AS02MC04 exposes a 6-pin JTAG header on the PCB. There is no
AMD-approved cable required: any reasonable JTAG adapter (Segger
J-Link, Altera USB Blaster, FT232H) plus OpenOCD will configure the
FPGA's CCLs over JTAG. Empirically verified workflow (see Julia
Desmazes' article linked below).

## Scan chain

A single TAP, IR length **6 bits**, IDCODE **`0x04a63093`** &mdash;
matches the Kintex UltraScale+ **KU3P** entry in UG570. Vivado's
hardware manager autodetects this fine, but OpenOCD needs the IR
length specified explicitly because it defaults to 2.

## OpenOCD configuration

```tcl
# openocd.cfg
source [find interface/jlink.cfg]
transport select jtag

# 1 MHz for probing, 10 MHz works fine for programming.
adapter speed 1000
reset_config none

jtag newtap xcku3p tap -irlen 6 -expected-id 0x04a63093

# Xilinx Virtex/UltraScale-style PLD driver. svf playback works too.
pld device virtex2 xcku3p.tap 1
```

Confirm the chain:

```sh
openocd -c "init; scan_chain; exit"
```

Expected output:

```
Info : JTAG tap: xcku3p.tap tap/device found: 0x04a63093
       (mfg: 0x049 (Xilinx), part: 0x4a63, ver: 0x0)
```

## Programming flow

1. Generate the bitstream (`make impl` &mdash; produces
   `pwfpga_top_phase1.bit`).
2. Convert to SVF (Vivado `write_cfgmem -format svf` or the existing
   Vivado scripts; can be added under `scripts/` in Phase 2).
3. Replay the SVF through OpenOCD:

```sh
openocd -f openocd.cfg \
        -c "init; adapter speed 10000; svf /path/to/bitstream.svf; exit"
```

Alternatively, with the `virtex2` pld driver:

```sh
openocd -f openocd.cfg \
        -c "init; pld load 0 /path/to/bitstream.bit; exit"
```

## After programming

The PCIe interface only re-trains on PERST# being toggled (or a host
reboot). To force a re-scan without rebooting:

```sh
sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
```

Then run the host-side identity check:

```sh
sudo fpga/as02mc04/scripts/bringup-check.sh
```

## References

- Julia Desmazes, *"Alibaba cloud FPGA: the 200&dollar; Kintex
  UltraScale+"*: <https://essenceia.github.io/projects/alibaba_cloud_fpga/>
- AMD/Xilinx UG570 (UltraScale Architecture Configuration User Guide).
- Alex Forencich, **Taxi** project AS02MC04 board support (MIT):
  <https://github.com/fpganinja/taxi> &mdash; `src/cndm/board/AS02MC04/`.

PacketWyrm's XDC and bitstream config in this directory are derived
from Taxi's AS02MC04 board support (with MIT attribution in each
file). Taxi / Corundum is an excellent reference NIC design; we
build a different application (a network tester) but the board
support work is the same physical board.
