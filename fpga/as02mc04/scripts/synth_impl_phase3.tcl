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

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "INFO: synth_1 = [get_property STATUS [get_runs synth_1]]"
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
puts "INFO: FINAL WNS = [get_property SLACK [get_timing_paths -setup]]"
set bit "$pd/pwfpga_as02mc04_phase3.runs/impl_1/pwfpga_top_phase3_board.bit"
puts "INFO: bit exists = [file exists $bit]"
