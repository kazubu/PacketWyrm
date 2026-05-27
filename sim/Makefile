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

TB := data_plane_tb/tb_data_plane.sv

VFLAGS := --binary -j 0 \
          --top-module tb_data_plane \
          -Wall \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNDRIVEN \
          -Wno-IMPORTSTAR -Wno-WIDTHCONCAT -Wno-BLKSEQ -Wno-GENUNNAMED \
          --timing

.PHONY: sim wave clean

sim: sim_build/data_plane
	./sim_build/data_plane

wave: VFLAGS += --trace-fst
wave: clean sim_build/data_plane
	./sim_build/data_plane
	@echo "trace: sim_build/data_plane.fst"

sim_build/data_plane: $(PHASE3_RTL) $(TB)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    -o data_plane \
	    $(PHASE3_RTL) $(TB)

clean:
	rm -rf sim_build
