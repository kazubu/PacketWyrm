set d [file dirname [file normalize [info script]]]
set pd "$d/../build/pwfpga_as02mc04_phase2"
open_project "$pd/pwfpga_as02mc04_phase2.xpr"
# ensure CDC constraints present (idempotent)
set taxi [file normalize "$d/../../../rtl/phase2/vendor/taxi"]
foreach f {taxi_axis_async_fifo.tcl taxi_sync_reset.tcl taxi_sync_signal.tcl} {
  if {[llength [get_files -quiet $f]] == 0} {
    set sub [expr {$f eq "taxi_axis_async_fifo.tcl" ? "axis" : "sync"}]
    add_files -fileset constrs_1 "$taxi/src/$sub/syn/vivado/$f"
    set_property USED_IN_SYNTHESIS false [get_files $f]
    set_property PROCESSING_ORDER LATE [get_files $f]
  }
}
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
puts "INFO: FINAL WNS = [get_property SLACK [get_timing_paths -setup]]"
set bit "$pd/pwfpga_as02mc04_phase2.runs/impl_1/pwfpga_top_phase2.bit"
puts "INFO: bit exists = [file exists $bit]"
