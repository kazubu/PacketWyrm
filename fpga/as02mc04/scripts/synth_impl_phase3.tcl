set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase3"
open_project "$pd/pwfpga_as02mc04_phase3.xpr"
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
