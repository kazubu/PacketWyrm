#!/usr/bin/env bash
# Verilator lint of the AS02MC04 Phase 3 production data-plane integration
# (pwfpga_top_phase3: parser + classifiers + flow gen/checker + DMA slow path +
# CSR + GPIO sync + ICAP/SPI). Complements scripts/lint.sh (Phase 1 board top).
# The Phase 3 *board* wrapper (pwfpga_top_phase3_board: GT / clocking / PCIe) is
# vendor-primitive heavy and is checked at Vivado synth time, not here; the
# core top below is the RTL that actually changes per feature. Uses the taxi
# submodule for the async-FIFO/adapter and the xilinx-prims blackbox so UNISIM
# cells elaborate off-Vivado.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
taxi="$repo_root/rtl/phase2/vendor/taxi/src"

if [ ! -d "$taxi/axis/rtl" ]; then
    echo "taxi submodule missing ($taxi); run: git submodule update --init --recursive" >&2
    exit 1
fi

tmp_ver=$(mktemp --suffix=.sv)
trap 'rm -f "$tmp_ver"' EXIT
sed -e 's/@PW_VERSION@/00010000/' \
    -e 's/@PW_BUILD_ID@/FACE0003/' \
    -e 's/@PW_GIT_HASH@/DEADBEEF/' \
    "$repo_root/rtl/shared/pw_version_pkg.sv.in" > "$tmp_ver"

p3="$repo_root/rtl/phase3"

verilator --lint-only --top-module pwfpga_top_phase3 \
    -Wall \
    -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
    -Wno-TIMESCALEMOD \
    `# accepted style/width conventions (phase3 uses import::* + sized consts;` \
    `# taxi vendor RTL uses blocking assigns) -- structural checks (PINNOTFOUND,` \
    `# UNDRIVEN, port mismatch) stay ERRORS:` \
    -Wno-IMPORTSTAR -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT \
    -Wno-GENUNNAMED -Wno-BLKSEQ \
    -y "$taxi/axis/rtl" -y "$taxi/sync/rtl" -y "$taxi/lib/rtl" \
    "$repo_root/rtl/shared/pw_pkg.sv" \
    "$tmp_ver" \
    "$repo_root/rtl/shared/xilinx_prims_blackbox.sv" \
    "$repo_root/rtl/shared/pw_csr_window.sv" \
    "$p3/pw_axis_pkg.sv" \
    "$p3/pw_classifier_pkg.sv" \
    "$p3/pw_flow_window.sv" \
    "$p3/pw_flow_table_bram.sv" \
    "$p3/pw_stats_snapshot.sv" \
    "$p3/pw_lat_histogram.sv" \
    "$p3/pw_spi_flash.sv" \
    "$p3/pw_punt_rx_window.sv" \
    "$p3/pw_inject_tx_window.sv" \
    "$p3/pw_csr_full.sv" \
    "$p3/pw_parser_axis.sv" \
    "$p3/pw_slice_match.sv" \
    "$p3/pw_field_classifier.sv" \
    "$p3/pw_hash_classifier.sv" \
    "$p3/pw_test_rx_checker_bram.sv" \
    "$p3/pw_flowid_map.sv" \
    "$p3/pw_flow_gen_axis.sv" \
    "$p3/pw_flow_gen_multi.sv" \
    "$p3/pw_frame_saf.sv" \
    "$p3/pw_data_plane_axis.sv" \
    "$p3/pw_dma_slowpath.sv" \
    "$p3/pw_icap_reboot.sv" \
    "$p3/pw_gpio_sync.sv" \
    "$p3/pwfpga_top_phase3.sv"

echo "lint OK (phase3 core)"
