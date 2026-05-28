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

FLOW_RTL := \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_flow_window.sv \
    $(REPO)/rtl/phase3/pw_parser.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker.sv \
    $(REPO)/rtl/phase3/pw_flow_gen.sv \
    $(REPO)/rtl/phase3/pw_data_plane.sv

STATS_RTL := \
    $(REPO)/rtl/phase3/pw_stats_snapshot.sv

HIST_RTL := \
    $(REPO)/rtl/phase3/pw_histogram_snapshot.sv

FULL_RTL := \
    $(REPO)/rtl/shared/pw_pkg.sv \
    $(REPO)/sim/sim_version_pkg.sv \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_flow_window.sv \
    $(REPO)/rtl/phase3/pw_stats_snapshot.sv \
    $(REPO)/rtl/phase3/pw_histogram_snapshot.sv \
    $(REPO)/rtl/phase3/pw_csr_full.sv

TOP_RTL := \
    $(REPO)/rtl/shared/pw_pkg.sv \
    $(REPO)/sim/sim_version_pkg.sv \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_axis_serial.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_flow_window.sv \
    $(REPO)/rtl/phase3/pw_stats_snapshot.sv \
    $(REPO)/rtl/phase3/pw_histogram_snapshot.sv \
    $(REPO)/rtl/phase3/pw_csr_full.sv \
    $(REPO)/rtl/phase3/pw_parser.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker.sv \
    $(REPO)/rtl/phase3/pw_flow_gen.sv \
    $(REPO)/rtl/phase3/pw_data_plane.sv \
    $(REPO)/rtl/phase3/pwfpga_top_phase3.sv

TB       := data_plane_tb/tb_data_plane.sv
TB_AXIS  := axis_serial_tb/tb_axis_serial.sv
TB_CSR   := csr_window_tb/tb_csr_window.sv
TB_FLOW  := flow_window_tb/tb_flow_window.sv
TB_STATS := stats_snapshot_tb/tb_stats_snapshot.sv
TB_HIST  := histogram_tb/tb_histogram.sv
TB_FULL  := csr_full_tb/tb_csr_full.sv
TB_TOP   := phase3_top_tb/tb_phase3_top.sv

VFLAGS := --binary -j 0 \
          -Wall \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNDRIVEN \
          -Wno-IMPORTSTAR -Wno-WIDTHCONCAT -Wno-BLKSEQ -Wno-GENUNNAMED \
          -Wno-PINCONNECTEMPTY \
          --timing

.PHONY: sim sim_axis sim_csr sim_flow sim_stats sim_hist sim_full sim_top sim_all wave clean

sim: sim_build/data_plane
	./sim_build/data_plane

sim_axis: sim_build/axis_serial
	./sim_build/axis_serial

sim_csr: sim_build/csr_window
	./sim_build/csr_window

sim_flow: sim_build/flow_window
	./sim_build/flow_window

sim_stats: sim_build/stats_snapshot
	./sim_build/stats_snapshot

sim_hist: sim_build/histogram
	./sim_build/histogram

sim_full: sim_build/csr_full
	./sim_build/csr_full

sim_top: sim_build/phase3_top
	./sim_build/phase3_top

sim_all: sim sim_axis sim_csr sim_flow sim_stats sim_hist sim_full sim_top

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

sim_build/flow_window: $(FLOW_RTL) $(TB_FLOW)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_flow_window \
	    -o flow_window \
	    $(FLOW_RTL) $(TB_FLOW)

sim_build/stats_snapshot: $(STATS_RTL) $(TB_STATS)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_stats_snapshot \
	    -o stats_snapshot \
	    $(STATS_RTL) $(TB_STATS)

sim_build/histogram: $(HIST_RTL) $(TB_HIST)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_histogram \
	    -o histogram \
	    $(HIST_RTL) $(TB_HIST)

sim_build/csr_full: $(FULL_RTL) $(TB_FULL)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_csr_full \
	    -o csr_full \
	    $(FULL_RTL) $(TB_FULL)

sim_build/phase3_top: $(TOP_RTL) $(TB_TOP)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_phase3_top \
	    -o phase3_top \
	    $(TOP_RTL) $(TB_TOP)

clean:
	rm -rf sim_build
