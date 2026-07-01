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

# PULLDOWN: when no card is driving a line (a slave/listener leaves its sync-out
# hi-Z), the far card's input would otherwise float and the 2-FF synchroniser
# could latch noise as spurious edges. The sync line idles LOW (the pulse is
# active-high, rising-edge detected), so a weak pulldown holds an undriven input
# at the idle level -- harmless when the line IS driven (the driver wins). This
# lets the J5 be cross-wired (A.out<->B.in both ways) so master/slave can be
# chosen at runtime without re-wiring; the unused reverse leg sits cleanly low.
set_property -dict {LOC A14 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[0]}] ;# J5.3,4   sync-in
set_property -dict {LOC E12 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[1]}] ;# J5.5,6   sync-out
set_property -dict {LOC E13 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[2]}] ;# J5.7,8   spare
set_property -dict {LOC F10 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[3]}] ;# J5.9,10  spare
set_property -dict {LOC C9  IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[4]}] ;# J5.11,12 spare
set_property -dict {LOC D9  IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports {gpio[5]}] ;# J5.13,14 spare

# Async sync line: inputs land in pw_gpio_sync's 2-FF synchroniser, outputs are a
# free-running pulse to the far card -- no setup/hold relationship either way.
set_false_path -from [get_ports {gpio[*]}]
set_false_path -to   [get_ports {gpio[*]}]

# --- Per-SFP I2C management bus (SW bit-bang, open-drain). PHASE 3 ONLY. ------
# One 2-wire bus per SFP cage, to read the module EEPROM (0xA0 base ID @ i2c
# 0x50, 0xA2 DOM @ 0x51). Bidirectional (IOBUF in the board top); the FPGA only
# drives low, PULLUP gives the idle-high (the board also has external pull-ups).
# Kept out of the shared sfp.xdc because that file is read by the Phase 2 project
# too, whose top has no sfp_scl/sfp_sda port (empty get_ports -> error there).
#   signal       FPGA LOC   bank     SFP cage
#   sfp_scl[0]   C13        BANK87   SFP_1
#   sfp_sda[0]   C14        BANK87   SFP_1
#   sfp_scl[1]   D10        BANK86   SFP_2
#   sfp_sda[1]   D11        BANK86   SFP_2
set_property -dict {LOC C13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12 PULLTYPE PULLUP} [get_ports {sfp_scl[0]}]
set_property -dict {LOC C14 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12 PULLTYPE PULLUP} [get_ports {sfp_sda[0]}]
set_property -dict {LOC D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12 PULLTYPE PULLUP} [get_ports {sfp_scl[1]}]
set_property -dict {LOC D11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12 PULLTYPE PULLUP} [get_ports {sfp_sda[1]}]

# Async, SW-timed bit-bang: pad inputs are 2FF-synced in the core; no setup/hold.
set_false_path -from [get_ports {sfp_scl[*] sfp_sda[*]}]
set_false_path -to   [get_ports {sfp_scl[*] sfp_sda[*]}]

# --- Front-panel R/G health LED. PHASE 3 ONLY. -------------------------------
# Bicolor status LED (active-low: 0 = lit). led_r=A13, led_g=A12 (LVCMOS33).
# Driven from data-plane health synchronised into the 100 MHz LED domain; async
# output, false-pathed. Kept out of the shared pinout.xdc (Phase 1/2 tops have
# no led_r/led_g port -> empty get_ports there).
set_property -dict {LOC A13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports led_r]
set_property -dict {LOC A12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports led_g]
set_false_path -to [get_ports {led_r led_g}]
