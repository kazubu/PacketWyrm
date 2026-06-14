# Write the Phase 1 bitstream into the AS02MC04 onboard SPI flash so the
# KU3P configures from flash at power-on (no JTAG + reboot dance).
#
#   vivado -mode batch -source scripts/flash.tcl -tclargs <bitfile> [cfgmem_part] [hw_glob]
#
# Default flash: Micron MT25QU256 (256 Mb, 1.8 V, SPIx4) -- the part on
# the AS02MC04. The board straps config mode to Master SPI, and the
# bitstream carries the SPIx4 settings from xdc/physical.xdc.
#
# Vivado's indirect flow loads a flash-programmer design into the FPGA
# (this drops the running PacketWyrm config / PCIe endpoint), reads the
# flash JEDEC ID -- aborting on a part mismatch before any write -- then
# erases / programs / verifies. After it completes, COLD power-cycle the
# host so the FPGA reloads from flash at power-on.

if {[llength $argv] < 1} {
    puts stderr "usage: ... flash.tcl <bitfile> \[cfgmem_part\] \[hw_glob\]"
    exit 1
}
set bit  [lindex $argv 0]
set part [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "mt25qu256-spi-x1_x2_x4"}]
set glob [expr {[llength $argv] >= 3 ? [lindex $argv 2] : "*"}]
set mcs  "[file rootname $bit].mcs"

# 256 Mb = 32 MB. The bitstream (~6 MB) loads at offset 0.
write_cfgmem -force -format MCS -size 32 -interface SPIx4 \
    -loadbit "up 0x00000000 $bit" -file $mcs
puts "INFO: wrote $mcs"

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets $glob]
if {[llength $targets] == 0} { puts stderr "no hw_target matched '$glob'"; exit 2 }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set memparts [get_cfgmem_parts $part]
if {[llength $memparts] == 0} { puts stderr "no cfgmem part '$part'"; exit 3 }
set cfgmem [create_hw_cfgmem -hw_device $dev [lindex $memparts 0]]

set_property PROGRAM.ADDRESS_RANGE {use_file}  $cfgmem
set_property PROGRAM.FILES         [list $mcs] $cfgmem
set_property PROGRAM.BLANK_CHECK   0           $cfgmem
set_property PROGRAM.ERASE         1           $cfgmem
set_property PROGRAM.CFG_PROGRAM   1           $cfgmem
set_property PROGRAM.VERIFY        1           $cfgmem
set_property PROGRAM.CHECKSUM      0           $cfgmem

# Load the flash-programmer helper bitstream into the FPGA.
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev

program_hw_cfgmem -hw_cfgmem $cfgmem
puts "INFO: SPI flash programmed and verified."
puts "INFO: COLD power-cycle the host -> the KU3P configures from flash at power-on."
