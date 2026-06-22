# Reproducible Vivado project for the AS02MC04 Phase 2 bitstream
# (Phase 1 PCIe/CSR + dual SFP+ 10GBASE-R via the Taxi MAC/PCS/GTY).
#
#   vivado -mode batch -source project_phase2.tcl              # create
#   vivado -mode batch -source project_phase2.tcl -tclargs synth
#   vivado -mode batch -source project_phase2.tcl -tclargs impl
#
# The Taxi submodule must be initialised:
#   git submodule update --init rtl/phase2/vendor/taxi

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../.."]
set taxi       "$repo_root/rtl/phase2/vendor/taxi"

set proj_name  "pwfpga_as02mc04_phase3"
set proj_dir   "$script_dir/build/$proj_name"
set part       "xcku3p-ffvb676-1-e"
set top_module "pwfpga_top_phase3_board"

foreach arg $argv { if {[regexp {^([^=]+)=(.*)$} $arg -> k v]} { set $k $v } }

# --- Resolve a Taxi .f filelist to a flat list of .sv paths ----------------
# Paths in a .f are relative to the .f's directory; per-area lib/taxi
# symlinks (lib/taxi -> repo root) resolve via [file normalize].
proc read_taxi_f {fpath seen_var} {
    upvar 1 $seen_var seen
    set fpath [file normalize $fpath]
    if {[info exists seen($fpath)]} { return {} }
    set seen($fpath) 1
    set out {}
    set dir [file dirname $fpath]
    set fh [open $fpath r]
    foreach line [split [read $fh] "\n"] {
        set line [string trim [regsub {#.*$} $line ""]]
        if {$line eq ""} { continue }
        set p [file normalize [file join $dir $line]]
        if {[string match *.f $line]} {
            set out [concat $out [read_taxi_f $p seen]]
        } elseif {[string match *.sv $line]} {
            lappend out $p
        }
    }
    close $fh
    return $out
}

file mkdir $proj_dir
create_project -force $proj_name $proj_dir -part $part

# --- generated version package ---------------------------------------------
set gen_dir "$proj_dir/gen"; file mkdir $gen_dir
set version_hex "00030000"
set build_hex   [format "%08x" [expr {[clock seconds] & 0xFFFFFFFF}]]
set git_hex     "00000000"
if {[catch {exec git -C $repo_root rev-parse --short=8 HEAD} sha] == 0} {
    set git_hex [string trimleft $sha 0]; if {$git_hex eq ""} { set git_hex "00000000" }
}
set fh_in  [open "$repo_root/rtl/shared/pw_version_pkg.sv.in" r]
set fh_out [open "$gen_dir/pw_version_pkg.sv" w]
puts -nonewline $fh_out [string map [list @PW_VERSION@ $version_hex @PW_BUILD_ID@ $build_hex @PW_GIT_HASH@ $git_hex] [read $fh_in]]
close $fh_in; close $fh_out

# --- PacketWyrm sources -----------------------------------------------------
set pw_srcs [list \
    "$repo_root/rtl/shared/pw_pkg.sv" \
    "$gen_dir/pw_version_pkg.sv" \
    "$repo_root/rtl/phase3/pw_axis_pkg.sv" \
    "$repo_root/rtl/phase3/pw_classifier_pkg.sv" \
    "$repo_root/rtl/shared/pw_heartbeat.sv" \
    "$repo_root/rtl/shared/pw_timestamp.sv" \
    "$repo_root/rtl/shared/pw_csr_window.sv" \
    "$repo_root/rtl/phase3/pw_parser_axis.sv" \
    "$repo_root/rtl/phase3/pw_classifier.sv" \
    "$repo_root/rtl/phase3/pw_flow_gen_multi.sv" \
    "$repo_root/rtl/phase3/pw_test_rx_checker_bram.sv" \
    "$repo_root/rtl/phase3/pw_flowid_map.sv" \
    "$repo_root/rtl/phase3/pw_lat_histogram.sv" \
    "$repo_root/rtl/phase3/pw_stats_snapshot.sv" \
    "$repo_root/rtl/phase3/pw_classifier_window.sv" \
    "$repo_root/rtl/phase3/pw_flow_window.sv" \
    "$repo_root/rtl/phase3/pw_flow_table_bram.sv" \
    "$repo_root/rtl/phase3/pw_spi_flash.sv" \
    "$repo_root/rtl/phase3/pw_punt_rx_window.sv" \
    "$repo_root/rtl/phase3/pw_inject_tx_window.sv" \
    "$repo_root/rtl/phase3/pw_frame_saf.sv" \
    "$repo_root/rtl/phase3/pw_data_plane_axis.sv" \
    "$repo_root/rtl/phase3/pw_csr_full.sv" \
    "$repo_root/rtl/phase3/pw_icap_reboot.sv" \
    "$repo_root/rtl/phase3/pw_ts_gray_cdc.sv" \
    "$repo_root/rtl/phase3/pw_ts_insert.sv" \
    "$repo_root/rtl/phase3/pwfpga_top_phase3.sv" \
    "$script_dir/src/pcie_axi_lite_bridge.sv" \
    "$script_dir/src/clock_reset.sv" \
    "$repo_root/rtl/phase2/pw_sfp_10g.sv" \
    "$repo_root/rtl/phase2/pw_mac_axis_cdc.sv" \
    "$script_dir/src/pwfpga_top_phase3_board.sv" \
]

# --- Taxi sources (dependency closure of the AS02MC04 10G data path) --------
array set seen {}
set taxi_srcs [read_taxi_f "$taxi/src/eth/rtl/us/taxi_eth_mac_25g_us.f" seen]
set taxi_srcs [concat $taxi_srcs [read_taxi_f "$taxi/src/axis/rtl/taxi_axis_async_fifo.f" seen]]
lappend taxi_srcs "$taxi/src/sync/rtl/taxi_sync_reset.sv" "$taxi/src/sync/rtl/taxi_sync_signal.sv"
set taxi_srcs [lsort -unique $taxi_srcs]
puts "INFO: Taxi closure = [llength $taxi_srcs] .sv files"

add_files -fileset sources_1 [concat $pw_srcs $taxi_srcs]
set_property file_type SystemVerilog [get_files *.sv]

# --- constraints ------------------------------------------------------------
# Board/IO XDC first, then Taxi's scoped CDC timing tcls (they self-scope
# via get_cells -hier REF_NAME filters, so they relax the async-FIFO /
# reset-synchroniser crossings inside the MAC). Marked late-processing so
# they run after the netlist exists in implementation.
add_files -fileset constrs_1 [list \
    "$script_dir/xdc/pinout.xdc" \
    "$script_dir/xdc/timing.xdc" \
    "$script_dir/xdc/physical.xdc" \
    "$script_dir/xdc/sfp.xdc" \
    "$taxi/src/axis/syn/vivado/taxi_axis_async_fifo.tcl" \
    "$taxi/src/sync/syn/vivado/taxi_sync_reset.tcl" \
    "$taxi/src/sync/syn/vivado/taxi_sync_signal.tcl" \
    "$script_dir/xdc/phase3_cdc.xdc" \
]
foreach cf {taxi_axis_async_fifo.tcl taxi_sync_reset.tcl taxi_sync_signal.tcl phase3_cdc.xdc} {
    set_property USED_IN_SYNTHESIS false [get_files $cf]
    set_property PROCESSING_ORDER LATE   [get_files $cf]
}

# --- IP: PCIe XDMA (Phase 1) + GTY 10G (Taxi) -------------------------------
source "$script_dir/ip/pcie_gen3.tcl"
# AXI4-Lite clock converter: BAR (axi_aclk 250) -> data-plane dp_clk (156.25).
source "$script_dir/ip/axi_clk_conv.tcl"
# Taxi GTY IP for the DATA_W=64 / low-latency path (25G GT core @ 10G).
source "$taxi/src/eth/rtl/us/taxi_eth_phy_25g_us_gty_10g_156.tcl"

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

if {[lsearch $argv "synth"] >= 0 || [lsearch $argv "impl"] >= 0} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
if {[lsearch $argv "impl"] >= 0} {
    # Enable physical optimisation (post-place + post-route): the 32/16/16
    # data plane (incl. IPv6: 256-byte rows + IPv6 UDP checksum) closes at
    # 156.25 MHz only by a thin margin (post-route WNS ~+0.12 ns), so
    # marginal route-dominated paths need phys_opt to recover reliably.
    # NB: read timing POST-ROUTE (report_timing on the routed dcp) -- the
    # post-place estimate runs optimistic and there is no timing gate here.
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    # Timing-closure directives: the encap + BRAM-flow-table data plane is dense
    # (~87% LUT) and the dp_clk floor is placement/congestion-dominated, so use
    # the Explore directives for place / phys_opt / route to chase WNS harder.
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    puts "INFO: bitstream at $proj_dir/$proj_name.runs/impl_1/${top_module}.bit"
}
puts "INFO: Phase 2 project at $proj_dir"
