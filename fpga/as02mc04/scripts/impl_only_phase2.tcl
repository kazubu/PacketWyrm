set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase2"
open_project "$pd/pwfpga_as02mc04_phase2.xpr"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "INFO: impl_1 status = [get_property STATUS [get_runs impl_1]]"
set bit "$pd/pwfpga_as02mc04_phase2.runs/impl_1/pwfpga_top_phase2.bit"
if {[file exists $bit]} { puts "INFO: bitstream written: $bit" } else { puts "WARN: no bitstream" }
