# Program a bitstream over JTAG via Vivado hw_server.
# Invoked by `make program HW_TARGET=...`.

if {[llength $argv] < 1} {
    puts stderr "usage: vivado -mode batch -source program.tcl -tclargs <bitfile> \[hw_target_glob\]"
    exit 1
}

set bitfile [lindex $argv 0]
set glob    [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "*"}]

open_hw_manager
connect_hw_server -allow_non_jtag

set targets [get_hw_targets $glob]
if {[llength $targets] == 0} {
    puts stderr "no hw_target matched '$glob'; available:"
    foreach t [get_hw_targets] { puts stderr "  $t" }
    exit 2
}

current_hw_target [lindex $targets 0]
open_hw_target

set dev [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "INFO: programmed $bitfile onto $dev"
