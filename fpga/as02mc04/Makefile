# AS02MC04 Vivado bitstream Makefile.
#
# Targets:
#   make project   create the Vivado project (no synth)
#   make synth     run synthesis
#   make impl      run implementation + write_bitstream
#   make ip        create the project WITH the PCIe IP generated (use_ip=1)
#   make program   load the latest bitstream over JTAG (volatile)
#   make flash     write the bitstream into onboard SPI flash (boots at power-on)
#   make clean     remove build artefacts
#
# Targets default to PHASE 3 (the production build). For the older bring-up
# builds pass PHASE=1 / PHASE=2, e.g. `make flash PHASE=1`.
#
# Vivado must be on PATH. Override with VIVADO=/opt/Xilinx/Vivado/2024.1/bin/vivado.

VIVADO ?= vivado

# Which board build to target. Phase 3 -- the production 64-bit AXIS data plane
# (PCIe + dual 10G + flow gen/checker + cross-card GPIO sync) -- is the DEFAULT.
# Override for the older bring-up builds: `make flash PHASE=1`, `make impl PHASE=2`.
PHASE ?= 3

ifeq ($(PHASE),3)
  PROJ_NAME   := pwfpga_as02mc04_phase3
  TOP         := pwfpga_top_phase3_board
  PROJECT_CMD := $(VIVADO) -mode batch -source project_phase3.tcl
  # Phase 3 reuses the existing .xpr and does a full reset+synth+route, stamping
  # build_id/USERID into the bitstream (scripts/synth_impl_phase3.tcl).
  IMPL_CMD    := $(VIVADO) -mode batch -source scripts/synth_impl_phase3.tcl
else ifeq ($(PHASE),2)
  PROJ_NAME   := pwfpga_as02mc04_phase2
  TOP         := pwfpga_top_phase2
  PROJECT_CMD := $(VIVADO) -mode batch -source project.tcl
  IMPL_CMD    := $(VIVADO) -mode batch -source project.tcl -tclargs impl
else
  PROJ_NAME   := pwfpga_as02mc04_phase1
  TOP         := pwfpga_top_phase1
  PROJECT_CMD := $(VIVADO) -mode batch -source project.tcl
  IMPL_CMD    := $(VIVADO) -mode batch -source project.tcl -tclargs impl
endif
PROJ_DIR  := build/$(PROJ_NAME)
BITFILE   := $(PROJ_DIR)/$(PROJ_NAME).runs/impl_1/$(TOP).bit

.PHONY: project synth impl ip program flash lint clean

# Flash part on the AS02MC04 (Micron MT25QU256, SPIx4). Override if a
# board has a different device.
CFGMEM ?= mt25qu256-spi-x1_x2_x4

# Lint both board tops: the Phase 1 top (PCIe bridge + CSR + clocking) and the
# Phase 3 production data-plane core (data plane + DMA slow path + classifiers +
# GPIO/ICAP/SPI). The Phase 3 *board* wrapper (GT/clocking/PCIe) is vendor-heavy
# and is checked at Vivado synth time.
lint:
	./scripts/lint.sh
	./scripts/lint-phase3.sh

project:
	$(PROJECT_CMD)

# synth-only is the phase1/2 PCIe-IP flow; phase 3 has no synth-only step --
# `make impl` (synth_impl_phase3.tcl) does synth+route+bitstream in one pass.
synth:
	$(VIVADO) -mode batch -source project.tcl -tclargs synth

impl: $(BITFILE)
$(BITFILE):
	$(IMPL_CMD)

# IP generation must happen inside the project (the IP scripts call
# current_project), so this drives project.tcl with use_ip=1 rather
# than sourcing the IP scripts standalone. synth/impl auto-set use_ip=1.
ip:
	$(VIVADO) -mode batch -source project.tcl -tclargs use_ip=1

# Program the FPGA over JTAG. Set HW_TARGET=ftdi_xil_hs2 or similar
# according to `hw_targets` in Vivado tcl.
program: $(BITFILE)
	$(VIVADO) -mode batch -source scripts/program.tcl \
	          -tclargs $(BITFILE) $(HW_TARGET)

# Write the bitstream into onboard SPI flash (persists across power-off).
flash: $(BITFILE)
	$(VIVADO) -mode batch -source scripts/flash.tcl \
	          -tclargs $(BITFILE) $(CFGMEM) $(HW_TARGET)

clean:
	rm -rf build/
