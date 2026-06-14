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
set part        "xcku3p-ffvb676-1-e"   ;# Kintex UltraScale+ KU3P -1 speed, confirmed by JTAG IDCODE 0x04a63093 and Taxi board support.
set top_module  "pwfpga_top_phase1"

# use_ip = 1 generates the real PCIe AXI-Bridge IP (ip/pcie_gen3.tcl)
# and DROPS src/pcie_gen3_stub.sv from the fileset (both define module
# pcie_gen3_wrapper -> a duplicate otherwise). Defaults to 1 whenever a
# real build (synth/impl) is requested, since the stub does not bring
# up PCIe. Force off with -tclargs use_ip=0 to synthesise the stub
# (PCIe will not enumerate -- only useful for LED / timing smoke).
set use_ip ""

# Allow the caller to override the part / top / use_ip via -tclargs key=value.
foreach arg $argv {
    if {[regexp {^([^=]+)=(.*)$} $arg -> k v]} { set $k $v }
}

set do_build [expr {[lsearch $argv "synth"] >= 0 || [lsearch $argv "impl"] >= 0}]
if {$use_ip eq ""} { set use_ip [expr {$do_build ? 1 : 0}] }

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
# The stub (src/pcie_gen3_stub.sv) and the generated IP both define
# module pcie_gen3_wrapper; include the stub only when not generating IP.
set src_files [list \
    "$repo_root/rtl/shared/pw_pkg.sv" \
    "$tmpl_out" \
    "$repo_root/rtl/shared/pw_heartbeat.sv" \
    "$repo_root/rtl/shared/pw_timestamp.sv" \
    "$repo_root/rtl/shared/pw_csr_min.sv" \
    "$script_dir/src/pcie_axi_lite_bridge.sv" \
    "$script_dir/src/clock_reset.sv" \
    "$script_dir/src/pwfpga_top_phase1.sv" \
]
if {!$use_ip} {
    lappend src_files "$script_dir/src/pcie_gen3_stub.sv"
}
add_files -fileset sources_1 $src_files

# --- constraints ----------------------------------------------------------
add_files -fileset constrs_1 [list \
    "$script_dir/xdc/pinout.xdc" \
    "$script_dir/xdc/timing.xdc" \
    "$script_dir/xdc/physical.xdc" \
]

# --- IP generation --------------------------------------------------------
# Requires a Xilinx-licensed Vivado (UltraScale+) that can synthesise
# the xdma DMA/Bridge Subsystem on this part. See ip/pcie_gen3.tcl for
# the CONFIG-key version-reconciliation note.
if {$use_ip} {
    puts "INFO: use_ip=1 -> generating PCIe AXI-Bridge IP (stub excluded)"
    source "$script_dir/ip/pcie_gen3.tcl"
    # source "$script_dir/ip/clk_wiz.tcl"   ;# enable if clock_reset moves to clk_wiz
} else {
    puts "INFO: use_ip=0 -> synthesising with pcie_gen3_stub (PCIe will NOT enumerate)"
}

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
