# Run implementation + write_bitstream on the EXISTING project, reusing
# the completed synth_1 run (so we don't re-synthesise / re-generate IP).
# Usage: vivado -mode batch -source scripts/impl_only.tcl
set script_dir [file dirname [file normalize [info script]]]
set proj_dir "$script_dir/../build/pwfpga_as02mc04_phase1"
open_project "$proj_dir/pwfpga_as02mc04_phase1.xpr"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set bit "$proj_dir/pwfpga_as02mc04_phase1.runs/impl_1/pwfpga_top_phase1.bit"
if {[file exists $bit]} {
    puts "INFO: bitstream written: $bit"
} else {
    puts "ERROR: bitstream not found at $bit"
}
