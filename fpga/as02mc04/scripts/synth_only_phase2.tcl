set d [file dirname [file normalize [info script]]]
open_project "$d/../build/pwfpga_as02mc04_phase2/pwfpga_as02mc04_phase2.xpr"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "INFO: synth_1 status = [get_property STATUS [get_runs synth_1]]"
puts "INFO: synth_1 progress = [get_property PROGRESS [get_runs synth_1]]"
