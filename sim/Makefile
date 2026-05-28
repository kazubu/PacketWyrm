# PacketWyrm RTL simulation.
#
# Targets:
#   make sim         build + run the data-plane testbench
#   make wave        rebuild with FST tracing enabled, run, leave
#                    sim_build/data_plane.fst for inspection
#   make clean

VERILATOR ?= verilator
REPO      := $(realpath $(CURDIR)/..)

PHASE3_RTL := \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_parser.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker.sv \
    $(REPO)/rtl/phase3/pw_flow_gen.sv \
    $(REPO)/rtl/phase3/pw_data_plane.sv

AXIS_RTL := \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_axis_serial.sv

CSR_RTL := \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_parser.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker.sv \
    $(REPO)/rtl/phase3/pw_flow_gen.sv \
    $(REPO)/rtl/phase3/pw_data_plane.sv

TB     := data_plane_tb/tb_data_plane.sv
TB_AXIS := axis_serial_tb/tb_axis_serial.sv
TB_CSR  := csr_window_tb/tb_csr_window.sv

VFLAGS := --binary -j 0 \
          -Wall \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNDRIVEN \
          -Wno-IMPORTSTAR -Wno-WIDTHCONCAT -Wno-BLKSEQ -Wno-GENUNNAMED \
          --timing

.PHONY: sim sim_axis sim_csr sim_all wave clean

sim: sim_build/data_plane
	./sim_build/data_plane

sim_axis: sim_build/axis_serial
	./sim_build/axis_serial

sim_csr: sim_build/csr_window
	./sim_build/csr_window

sim_all: sim sim_axis sim_csr

wave: VFLAGS += --trace-fst
wave: clean sim_build/data_plane
	./sim_build/data_plane
	@echo "trace: sim_build/data_plane.fst"

sim_build/data_plane: $(PHASE3_RTL) $(TB)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_data_plane \
	    -o data_plane \
	    $(PHASE3_RTL) $(TB)

sim_build/axis_serial: $(AXIS_RTL) $(TB_AXIS)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_axis_serial \
	    -o axis_serial \
	    $(AXIS_RTL) $(TB_AXIS)

sim_build/csr_window: $(CSR_RTL) $(TB_CSR)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_csr_window \
	    -o csr_window \
	    $(CSR_RTL) $(TB_CSR)

clean:
	rm -rf sim_build
