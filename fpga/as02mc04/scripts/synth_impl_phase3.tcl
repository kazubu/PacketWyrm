set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase3"
open_project "$pd/pwfpga_as02mc04_phase3.xpr"

# Regenerate pw_version_pkg so build_id / git_hash reflect THIS build (the
# project is reused across builds, so its create-time values would otherwise
# go stale). Same substitution as project_phase3.tcl; the file is in the source
# set by path, so reset_run synth_1 below re-reads it. build_id = unix time.
set repo_root [file normalize "$d/../../.."]
set gen_dir "$pd/gen"; file mkdir $gen_dir
set version_hex "00030000"
set build_hex [format "%08x" [expr {[clock seconds] & 0xFFFFFFFF}]]
set git_hex "00000000"
if {[catch {exec git -C $repo_root rev-parse --short=8 HEAD} sha] == 0} {
    set git_hex [string trimleft $sha 0]; if {$git_hex eq ""} { set git_hex "00000000" }
}
set fh_in  [open "$repo_root/rtl/shared/pw_version_pkg.sv.in" r]
set fh_out [open "$gen_dir/pw_version_pkg.sv" w]
puts -nonewline $fh_out [string map [list @PW_VERSION@ $version_hex @PW_BUILD_ID@ $build_hex @PW_GIT_HASH@ $git_hex] [read $fh_in]]
close $fh_in; close $fh_out
puts "INFO: regenerated pw_version_pkg build_id=$build_hex git_hash=$git_hex"

# Sanity: the regenerated package MUST carry this build's git hash (catches a
# broken substitution / stale template before we spend an hour synthesising).
set _chk [open "$gen_dir/pw_version_pkg.sv" r]; set _txt [read $_chk]; close $_chk
if {$git_hex ne "00000000" && ![string match "*$git_hex*" $_txt]} {
    error "version regen failed: git_hash $git_hex not found in $gen_dir/pw_version_pkg.sv"
}

# Disable INCREMENTAL synthesis. With auto-incremental on, Vivado reuses ~90% of
# the prior run's netlist -- including pw_csr_full, which holds the per-build
# build_id / git_hash constants from pw_version_pkg. The reuse heuristic does NOT
# treat the changed constants as a reason to re-synthesise that module, so the
# regenerated build_id NEVER reaches the bitstream and the design reports the
# PREVIOUS build's id. That stale label is what sent the 2026-06-27 flash bring-up
# chasing a phantom "old image still booting" (the image was in fact fresh; only
# the build_id constant was stale). Force a full re-synth so build_id is real.
catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1] }
catch { set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1] }

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "INFO: synth_1 = [get_property STATUS [get_runs synth_1]]"
# Route only; we write the bitstream by hand below so we can stamp the build
# identity into the config registers (see USERID/USR_ACCESS below).
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
# open the routed checkpoint directly (open_run rejects a run launched only
# -to_step route_design with "has not been launched"; the routed dcp is on disk).
set routed "$pd/pwfpga_as02mc04_phase3.runs/impl_1/pwfpga_top_phase3_board_routed.dcp"
open_checkpoint $routed
puts "INFO: FINAL WNS = [get_property SLACK [get_timing_paths -setup]]"

# Stamp the build identity into the bitstream config registers so it can be read
# back over JTAG WITHOUT the PCIe CSR (which proved unreliable for build_id during
# the 2026-06-27 flash bring-up -- a stale CSR read sent us chasing a phantom
# "old image still booting"). These are read via:
#   get_property REGISTER.USERCODE   <hw_device>   == git_hash (USERID)
#   get_property REGISTER.USR_ACCESS <hw_device>   == build_id (USR_ACCESS)
# USERCODE is independent of the pw_version_pkg synth constant, so comparing it to
# the CSR-read git_hash also tells us whether a future mismatch is a stale CSR read
# vs a synth that didn't pick up the regenerated package.
set_property BITSTREAM.CONFIG.USERID    "0x$git_hex"   [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS "0x$build_hex" [current_design]
puts "INFO: stamped USERID=0x$git_hex (->USERCODE) USR_ACCESS=0x$build_hex (->build_id)"

set bit "$pd/pwfpga_as02mc04_phase3.runs/impl_1/pwfpga_top_phase3_board.bit"
write_bitstream -force $bit
puts "INFO: bit exists = [file exists $bit]"
