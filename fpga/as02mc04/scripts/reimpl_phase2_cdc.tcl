set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase2"
set taxi [file normalize "$d/../../../rtl/phase2/vendor/taxi"]
open_project "$pd/pwfpga_as02mc04_phase2.xpr"
add_files -fileset constrs_1 [list   "$taxi/src/axis/syn/vivado/taxi_axis_async_fifo.tcl"   "$taxi/src/sync/syn/vivado/taxi_sync_reset.tcl"   "$taxi/src/sync/syn/vivado/taxi_sync_signal.tcl" ]
foreach f {taxi_axis_async_fifo.tcl taxi_sync_reset.tcl taxi_sync_signal.tcl} {
  set_property USED_IN_SYNTHESIS false [get_files $f]
  set_property PROCESSING_ORDER LATE [get_files $f]
}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "INFO: impl_1 status = [get_property STATUS [get_runs impl_1]]"
open_run impl_1
puts "INFO: FINAL WNS = [get_property SLACK [get_timing_paths -setup]]"
report_timing_summary -file $pd/p2_timing_post_cdc.rpt -quiet
