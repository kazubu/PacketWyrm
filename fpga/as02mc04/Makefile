# AS02MC04 Vivado bitstream Makefile.
#
# Targets:
#   make project   create the Vivado project (no synth)
#   make synth     run synthesis
#   make impl      run implementation + write_bitstream
#   make ip        regenerate Xilinx IP (PCIe Gen3, MMCM)
#   make program   load the latest bitstream over JTAG (HW_TARGET required)
#   make clean     remove build artefacts
#
# Vivado must be on PATH. Override with VIVADO=/opt/Xilinx/Vivado/2024.1/bin/vivado.

VIVADO ?= vivado
PROJ_NAME := pwfpga_as02mc04_phase1
PROJ_DIR  := build/$(PROJ_NAME)
TOP       := pwfpga_top_phase1
BITFILE   := $(PROJ_DIR)/$(PROJ_NAME).runs/impl_1/$(TOP).bit

.PHONY: project synth impl ip program lint clean

lint:
	./scripts/lint.sh

project:
	$(VIVADO) -mode batch -source project.tcl

synth:
	$(VIVADO) -mode batch -source project.tcl -tclargs synth

impl: $(BITFILE)
$(BITFILE):
	$(VIVADO) -mode batch -source project.tcl -tclargs impl

ip:
	$(VIVADO) -mode batch -source ip/pcie_gen3.tcl -source ip/clk_wiz.tcl

# Program the FPGA over JTAG. Set HW_TARGET=ftdi_xil_hs2 or similar
# according to `hw_targets` in Vivado tcl.
program: $(BITFILE)
	$(VIVADO) -mode batch -source scripts/program.tcl \
	          -tclargs $(BITFILE) $(HW_TARGET)

clean:
	rm -rf build/
