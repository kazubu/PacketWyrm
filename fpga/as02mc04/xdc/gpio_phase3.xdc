# J5 header GPIO - cross-card time-sync (pw_gpio_sync). PHASE 3 ONLY.
#
# Kept out of the shared pinout.xdc because the Phase 1/2 tops have no `gpio`
# port -- a gpio constraint there would error (empty get_ports). Read only by
# project_phase3.tcl.
#
# 6 LVCMOS33 signals, each on a J5 odd/even pin pair. Bidirectional (IOBUF in the
# board top); only the CSR-configured sync-out pin is driven, the rest are hi-Z.
# Async inputs are synchronised in pw_gpio_sync and false-pathed below.
#
#   signal    FPGA LOC   J5 pins   suggested daisy-chain use
#   -------   --------   -------   -------------------------------------------
#   gpio[0]   A14        J5.3,4    sync-IN   (listen for the upstream pulse)
#   gpio[1]   E12        J5.5,6    sync-OUT  (drive pulse to the next card)
#   gpio[2]   E13        J5.7,8    spare
#   gpio[3]   F10        J5.9,10   spare
#   gpio[4]   C9         J5.11,12  spare
#   gpio[5]   D9         J5.13,14  spare
#
# The sync-in / sync-out *pin index* is software-selected (gpio_sync_ctrl bits
# [6:4] in_sel, [10:8] out_sel) -- the in=0/out=1 split above is only a wiring
# convention, not fixed in HW. Each "J5.a,b" is a pin pair; which of the two is
# the signal vs ground is per the board's J5 silkscreen (confirm before wiring).
# Wiring (2-card): card A gpio[1] (out) -> card B gpio[0] (in), common ground.

set_property -dict {LOC A14 IOSTANDARD LVCMOS33} [get_ports {gpio[0]}] ;# J5.3,4   sync-in
set_property -dict {LOC E12 IOSTANDARD LVCMOS33} [get_ports {gpio[1]}] ;# J5.5,6   sync-out
set_property -dict {LOC E13 IOSTANDARD LVCMOS33} [get_ports {gpio[2]}] ;# J5.7,8   spare
set_property -dict {LOC F10 IOSTANDARD LVCMOS33} [get_ports {gpio[3]}] ;# J5.9,10  spare
set_property -dict {LOC C9  IOSTANDARD LVCMOS33} [get_ports {gpio[4]}] ;# J5.11,12 spare
set_property -dict {LOC D9  IOSTANDARD LVCMOS33} [get_ports {gpio[5]}] ;# J5.13,14 spare

# Async sync line: inputs land in pw_gpio_sync's 2-FF synchroniser, outputs are a
# free-running pulse to the far card -- no setup/hold relationship either way.
set_false_path -from [get_ports {gpio[*]}]
set_false_path -to   [get_ports {gpio[*]}]
