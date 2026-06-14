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
# Vivado must be on PATH. Override with VIVADO=/opt/Xilinx/Vivado/2024.1/bin/vivado.

VIVADO ?= vivado
PROJ_NAME := pwfpga_as02mc04_phase1
PROJ_DIR  := build/$(PROJ_NAME)
TOP       := pwfpga_top_phase1
BITFILE   := $(PROJ_DIR)/$(PROJ_NAME).runs/impl_1/$(TOP).bit

.PHONY: project synth impl ip program flash lint clean

# Flash part on the AS02MC04 (Micron MT25QU256, SPIx4). Override if a
# board has a different device.
CFGMEM ?= mt25qu256-spi-x1_x2_x4

lint:
	./scripts/lint.sh

project:
	$(VIVADO) -mode batch -source project.tcl

synth:
	$(VIVADO) -mode batch -source project.tcl -tclargs synth

impl: $(BITFILE)
$(BITFILE):
	$(VIVADO) -mode batch -source project.tcl -tclargs impl

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
