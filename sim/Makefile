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

DPA_RTL := \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_flow_table_bram.sv \
    $(REPO)/rtl/phase3/pw_parser_axis.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_slice_match.sv \
    $(REPO)/rtl/phase3/pw_slice_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker_bram.sv \
    $(REPO)/rtl/phase3/pw_flowid_map.sv \
    $(REPO)/rtl/phase3/pw_lat_histogram.sv \
    $(REPO)/rtl/phase3/pw_flow_gen_axis.sv \
    $(REPO)/rtl/phase3/pw_flow_gen_multi.sv \
    $(REPO)/rtl/phase3/pw_frame_saf.sv \
    $(REPO)/rtl/phase3/pw_data_plane_axis.sv

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

LAT_RTL := \
    $(REPO)/rtl/phase3/pw_lat_histogram.sv

SPI_RTL := \
    $(REPO)/rtl/phase3/pw_spi_flash.sv

FULL_RTL := \
    $(REPO)/rtl/shared/pw_pkg.sv \
    $(REPO)/sim/sim_version_pkg.sv \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_flow_window.sv \
    $(REPO)/rtl/phase3/pw_flow_table_bram.sv \
    $(REPO)/rtl/phase3/pw_stats_snapshot.sv \
    $(REPO)/rtl/phase3/pw_lat_histogram.sv \
    $(REPO)/rtl/phase3/pw_spi_flash.sv \
    $(REPO)/rtl/phase3/pw_inject_tx_window.sv \
    $(REPO)/rtl/phase3/pw_csr_full.sv

TOP_RTL := \
    $(REPO)/rtl/shared/pw_pkg.sv \
    $(REPO)/sim/sim_version_pkg.sv \
    $(REPO)/rtl/shared/pw_csr_window.sv \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_window.sv \
    $(REPO)/rtl/phase3/pw_flow_window.sv \
    $(REPO)/rtl/phase3/pw_flow_table_bram.sv \
    $(REPO)/rtl/phase3/pw_stats_snapshot.sv \
    $(REPO)/rtl/phase3/pw_lat_histogram.sv \
    $(REPO)/rtl/phase3/pw_spi_flash.sv \
    $(REPO)/rtl/phase3/pw_punt_rx_window.sv \
    $(REPO)/rtl/phase3/pw_inject_tx_window.sv \
    $(REPO)/rtl/phase3/pw_csr_full.sv \
    $(REPO)/rtl/phase3/pw_parser_axis.sv \
    $(REPO)/rtl/phase3/pw_classifier.sv \
    $(REPO)/rtl/phase3/pw_slice_match.sv \
    $(REPO)/rtl/phase3/pw_slice_classifier.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker_bram.sv \
    $(REPO)/rtl/phase3/pw_flowid_map.sv \
    $(REPO)/rtl/phase3/pw_flow_gen_axis.sv \
    $(REPO)/rtl/phase3/pw_flow_gen_multi.sv \
    $(REPO)/rtl/phase3/pw_frame_saf.sv \
    $(REPO)/rtl/phase3/pw_data_plane_axis.sv \
    $(REPO)/rtl/phase3/pw_icap_reboot.sv \
    $(REPO)/rtl/phase3/pwfpga_top_phase3.sv

TB       := data_plane_tb/tb_data_plane.sv
TB_AXIS  := axis_serial_tb/tb_axis_serial.sv
TB_CSR   := csr_window_tb/tb_csr_window.sv
TB_FLOW  := flow_window_tb/tb_flow_window.sv
TB_STATS := stats_snapshot_tb/tb_stats_snapshot.sv
TB_LAT   := lat_histogram_tb/tb_lat_histogram.sv
TB_SPI   := spi_flash_tb/tb_spi_flash.sv
TB_FULL  := csr_full_tb/tb_csr_full.sv
TB_TOP   := phase3_top_tb/tb_phase3_top.sv
TB_VEC   := wire_vectors_tb/tb_wire_vectors.sv
TB_DPA   := data_plane_axis_tb/tb_data_plane_axis.sv
TB_SAF   := frame_saf_tb/tb_frame_saf.sv
TB_PUNT  := punt_window_tb/tb_punt_window.sv
TB_INJ   := inject_window_tb/tb_inject_window.sv
TB_CHK   := test_rx_checker_bram_tb/tb_test_rx_checker_bram.sv

CHK_RTL := \
    $(REPO)/rtl/phase3/pw_axis_pkg.sv \
    $(REPO)/rtl/phase3/pw_classifier_pkg.sv \
    $(REPO)/rtl/phase3/pw_test_rx_checker_bram.sv

VECTORS := vectors/bar_image.hex

VFLAGS := --binary -j 0 \
          -Wall \
          -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNDRIVEN \
          -Wno-IMPORTSTAR -Wno-WIDTHCONCAT -Wno-BLKSEQ -Wno-GENUNNAMED \
          -Wno-PINCONNECTEMPTY \
          --timing

.PHONY: sim sim_axis sim_csr sim_flow sim_stats sim_lat sim_spi sim_full sim_fga sim_fgm sim_fge sim_pax sim_saf sim_punt sim_inj sim_dpa sim_top sim_vec sim_all wave clean vectors

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

sim_lat: sim_build/lat_histogram
	./sim_build/lat_histogram

sim_chk: sim_build/test_rx_checker_bram
	./sim_build/test_rx_checker_bram

sim_slice: sim_build/slice_match
	./sim_build/slice_match

sim_sclass: sim_build/slice_classifier
	./sim_build/slice_classifier

sim_fidmap: sim_build/flowid_map
	./sim_build/flowid_map

sim_spi: sim_build/spi_flash
	./sim_build/spi_flash

sim_full: sim_build/csr_full
	./sim_build/csr_full

sim_fga: sim_build/flow_gen_axis
	./sim_build/flow_gen_axis

sim_fgm: sim_build/flow_gen_multi
	./sim_build/flow_gen_multi

sim_fge: sim_build/flow_gen_encap
	./sim_build/flow_gen_encap

sim_ftb: sim_build/flow_table_bram
	./sim_build/flow_table_bram

sim_pax: sim_build/parser_axis
	./sim_build/parser_axis

sim_saf: sim_build/frame_saf
	./sim_build/frame_saf

sim_punt: sim_build/punt_window
	./sim_build/punt_window

sim_inj: sim_build/inject_window
	./sim_build/inject_window

sim_dpa: sim_build/data_plane_axis
	./sim_build/data_plane_axis

sim_top: sim_build/phase3_top
	./sim_build/phase3_top

# Regenerate the C-side BAR-image vector file the wire-vector TB
# consumes. Depends on the host stack being built; we depend on
# the generator binary by path so re-running this also captures
# any change to csr.h that lands in the host stack.
$(VECTORS): $(REPO)/sw/build/gen_bar_vectors | vectors
	$(REPO)/sw/build/gen_bar_vectors $(VECTORS)

vectors:
	mkdir -p $@

vectors_clean:
	rm -f $(VECTORS)

sim_vec: sim_build/wire_vectors $(VECTORS)
	./sim_build/wire_vectors

sim_all: sim sim_axis sim_csr sim_flow sim_stats sim_lat sim_chk sim_slice sim_sclass sim_fidmap sim_spi sim_icap sim_tsi sim_full sim_fga sim_fgm sim_fge sim_pax sim_saf sim_punt sim_inj sim_dpa sim_top sim_vec

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

sim_build/lat_histogram: $(LAT_RTL) $(TB_LAT)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_lat_histogram \
	    -o lat_histogram \
	    $(LAT_RTL) $(TB_LAT)

sim_build/test_rx_checker_bram: $(CHK_RTL) $(TB_CHK)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_test_rx_checker_bram \
	    -o test_rx_checker_bram \
	    $(CHK_RTL) $(TB_CHK)

sim_build/slice_match: $(REPO)/rtl/phase3/pw_slice_match.sv slice_match_tb/tb_slice_match.sv
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_slice_match \
	    -o slice_match \
	    $(REPO)/rtl/phase3/pw_slice_match.sv slice_match_tb/tb_slice_match.sv

sim_build/slice_classifier: $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_slice_match.sv $(REPO)/rtl/phase3/pw_slice_classifier.sv slice_classifier_tb/tb_slice_classifier.sv
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_slice_classifier \
	    -o slice_classifier \
	    $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_slice_match.sv $(REPO)/rtl/phase3/pw_slice_classifier.sv slice_classifier_tb/tb_slice_classifier.sv

sim_build/flowid_map: $(REPO)/rtl/phase3/pw_flowid_map.sv flowid_map_tb/tb_flowid_map.sv
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_flowid_map \
	    -o flowid_map \
	    $(REPO)/rtl/phase3/pw_flowid_map.sv flowid_map_tb/tb_flowid_map.sv



sim_build/spi_flash: $(SPI_RTL) $(TB_SPI)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_spi_flash \
	    -o spi_flash \
	    $(SPI_RTL) $(TB_SPI)

sim_build/csr_full: $(FULL_RTL) $(TB_FULL)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_csr_full \
	    -o csr_full \
	    $(FULL_RTL) $(TB_FULL)

sim_build/parser_axis: $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_axis.sv $(REPO)/rtl/phase3/pw_parser_axis.sv parser_axis_tb/tb_parser_axis.sv
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_parser_axis -o parser_axis $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_axis.sv $(REPO)/rtl/phase3/pw_parser_axis.sv parser_axis_tb/tb_parser_axis.sv

sim_build/flow_gen_axis: $(REPO)/rtl/phase3/pw_flow_gen_axis.sv flow_gen_axis_tb/tb_flow_gen_axis.sv
	$(VERILATOR) $(VFLAGS) -Mdir sim_build --top-module tb_flow_gen_axis -o flow_gen_axis $(REPO)/rtl/phase3/pw_flow_gen_axis.sv flow_gen_axis_tb/tb_flow_gen_axis.sv

sim_build/flow_gen_multi: $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_multi.sv $(REPO)/rtl/phase3/pw_parser_axis.sv flow_gen_multi_tb/tb_flow_gen_multi.sv
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_flow_gen_multi -o flow_gen_multi $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_multi.sv $(REPO)/rtl/phase3/pw_parser_axis.sv flow_gen_multi_tb/tb_flow_gen_multi.sv

sim_build/flow_gen_encap: $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_multi.sv $(REPO)/rtl/phase3/pw_parser_axis.sv flow_gen_encap_tb/tb_flow_gen_encap.sv
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_flow_gen_encap -o flow_gen_encap $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/phase3/pw_classifier_pkg.sv $(REPO)/rtl/phase3/pw_flow_gen_multi.sv $(REPO)/rtl/phase3/pw_parser_axis.sv flow_gen_encap_tb/tb_flow_gen_encap.sv

sim_build/flow_table_bram: $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/shared/pw_csr_window.sv $(REPO)/rtl/phase3/pw_flow_table_bram.sv flow_table_bram_tb/tb_flow_table_bram.sv
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_flow_table_bram -o flow_table_bram $(REPO)/rtl/phase3/pw_axis_pkg.sv $(REPO)/rtl/shared/pw_csr_window.sv $(REPO)/rtl/phase3/pw_flow_table_bram.sv flow_table_bram_tb/tb_flow_table_bram.sv

sim_build/frame_saf: $(REPO)/rtl/phase3/pw_frame_saf.sv $(TB_SAF)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_frame_saf \
	    -o frame_saf \
	    $(REPO)/rtl/phase3/pw_frame_saf.sv $(TB_SAF)

sim_build/punt_window: $(REPO)/rtl/phase3/pw_punt_rx_window.sv $(TB_PUNT)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_punt_window \
	    -o punt_window \
	    $(REPO)/rtl/phase3/pw_punt_rx_window.sv $(TB_PUNT)

sim_build/inject_window: $(REPO)/rtl/phase3/pw_inject_tx_window.sv $(TB_INJ)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_inject_window \
	    -o inject_window \
	    $(REPO)/rtl/phase3/pw_inject_tx_window.sv $(TB_INJ)

sim_build/data_plane_axis: $(DPA_RTL) $(TB_DPA)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_data_plane_axis \
	    -o data_plane_axis \
	    $(DPA_RTL) $(TB_DPA)

sim_build/phase3_top: $(TOP_RTL) $(TB_TOP)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET \
	    -Mdir sim_build \
	    --top-module tb_phase3_top \
	    -o phase3_top \
	    $(TOP_RTL) $(TB_TOP)

sim_build/wire_vectors: $(FULL_RTL) $(TB_VEC)
	$(VERILATOR) $(VFLAGS) \
	    -Mdir sim_build \
	    --top-module tb_wire_vectors \
	    -o wire_vectors \
	    $(FULL_RTL) $(TB_VEC)

# Tell the C generator to live under sw/.
$(REPO)/sw/build/gen_bar_vectors:
	$(MAKE) -C $(REPO)/sw gen_bar_vectors

clean:
	rm -rf sim_build

ICAP_RTL := $(REPO)/rtl/phase3/pw_icap_reboot.sv
TB_ICAP  := icap_reboot_tb/tb_icap_reboot.sv
sim_icap: sim_build/icap_reboot
	./sim_build/icap_reboot
sim_build/icap_reboot: $(ICAP_RTL) $(TB_ICAP)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_icap_reboot -o icap_reboot $(ICAP_RTL) $(TB_ICAP)

TSI_RTL := $(REPO)/rtl/phase3/pw_ts_gray_cdc.sv $(REPO)/rtl/phase3/pw_ts_insert.sv
TB_TSI  := ts_insert_tb/tb_ts_insert.sv
sim_tsi: sim_build/ts_insert
	./sim_build/ts_insert
sim_build/ts_insert: $(TSI_RTL) $(TB_TSI)
	$(VERILATOR) $(VFLAGS) -Wno-SYNCASYNCNET -Mdir sim_build --top-module tb_ts_insert -o ts_insert $(REPO)/rtl/phase3/pw_ts_insert.sv $(TB_TSI)
