# Reproducible Vivado project creation for the AS02MC04 Phase 1
# bitstream.
#
# Usage:
#   vivado -mode batch -source project.tcl                    # create
#   vivado -mode batch -source project.tcl -tclargs synth     # + synth
#   vivado -mode batch -source project.tcl -tclargs impl      # + impl + bit
#
# Outputs go under build/$proj_name/.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

set proj_name   "pwfpga_as02mc04_phase1"
set proj_dir    "$script_dir/build/$proj_name"
set part        "xcku3p-ffvb676-2-e"   ;# Kintex UltraScale+ KU3P. Confirm exact package against AS02MC04 schematic.
set top_module  "pwfpga_top_phase1"

# Allow the caller to override the part / top via -tclargs key=value.
foreach arg $argv {
    if {[regexp {^([^=]+)=(.*)$} $arg -> k v]} { set $k $v }
}

file mkdir $proj_dir

create_project -force $proj_name $proj_dir -part $part

# --- generated version package -------------------------------------------
set gen_dir "$proj_dir/gen"
file mkdir $gen_dir

set version_hex "00010000"
set build_hex   [format "%08x" [expr {[clock seconds] & 0xFFFFFFFF}]]
set git_hex     "00000000"
if {[catch {exec git -C $repo_root rev-parse --short=8 HEAD} sha] == 0} {
    set git_hex [string trimleft $sha 0]
    if {$git_hex eq ""} { set git_hex "00000000" }
}

set tmpl_in  "$repo_root/rtl/shared/pw_version_pkg.sv.in"
set tmpl_out "$gen_dir/pw_version_pkg.sv"
set fh_in  [open $tmpl_in r]
set fh_out [open $tmpl_out w]
puts -nonewline $fh_out [string map [list \
    @PW_VERSION@  $version_hex \
    @PW_BUILD_ID@ $build_hex \
    @PW_GIT_HASH@ $git_hex \
] [read $fh_in]]
close $fh_in
close $fh_out
puts "INFO: wrote $tmpl_out (version=$version_hex build=$build_hex git=$git_hex)"

# --- sources --------------------------------------------------------------
add_files -fileset sources_1 [list \
    "$repo_root/rtl/shared/pw_pkg.sv" \
    "$tmpl_out" \
    "$repo_root/rtl/shared/pw_heartbeat.sv" \
    "$repo_root/rtl/shared/pw_timestamp.sv" \
    "$repo_root/rtl/shared/pw_csr_min.sv" \
    "$script_dir/src/pcie_gen3_stub.sv" \
    "$script_dir/src/pcie_axi_lite_bridge.sv" \
    "$script_dir/src/clock_reset.sv" \
    "$script_dir/src/pwfpga_top_phase1.sv" \
]

# --- constraints ----------------------------------------------------------
add_files -fileset constrs_1 [list \
    "$script_dir/xdc/pinout.xdc" \
    "$script_dir/xdc/timing.xdc" \
    "$script_dir/xdc/physical.xdc" \
]

# --- IP generation (uncomment once you have a Xilinx-licensed Vivado that
# can synthesise pcie4_uscale_plus / clk_wiz on the targeted part).
# source "$script_dir/ip/pcie_gen3.tcl"
# source "$script_dir/ip/clk_wiz.tcl"

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

# --- optional follow-up actions -------------------------------------------
if {[lsearch $argv "synth"] >= 0 || [lsearch $argv "impl"] >= 0} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
if {[lsearch $argv "impl"] >= 0} {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    puts "INFO: bitstream at $proj_dir/$proj_name.runs/impl_1/${top_module}.bit"
}

puts "INFO: project created at $proj_dir"
