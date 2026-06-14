set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase2"
open_project "$pd/pwfpga_as02mc04_phase2.xpr"
if {[llength [get_files -quiet phase2_cdc.xdc]] == 0} {
  add_files -fileset constrs_1 "$d/../xdc/phase2_cdc.xdc"
  set_property USED_IN_SYNTHESIS false [get_files phase2_cdc.xdc]
  set_property PROCESSING_ORDER LATE   [get_files phase2_cdc.xdc]
}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
puts "INFO: FINAL WNS = [get_property SLACK [get_timing_paths -setup]]"
