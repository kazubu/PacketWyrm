# AS02MC04 SFP+ constraints (Phase 2).
#
# GTYE4 serial pairs and the 156.25 MHz MGT reference clock for the two
# SFP+ cages. Pin locations from the Taxi AS02MC04 board support
# (FPGA Ninja, LLC, CERN-OHL-S-2.0; see top-level LICENSE). The serial
# pin LOCs imply the GT channel sites (port 0 = X0Y15, port 1 = X0Y14),
# so no explicit GT placement is needed.

# 156.25 MHz SFP MGT reference clock (MGTREFCLK0_227, Y1 oscillator)
set_property -dict {LOC K7 } [get_ports sfp_mgt_refclk_p]
set_property -dict {LOC K6 } [get_ports sfp_mgt_refclk_n]
create_clock -period 6.400 -name sfp_mgt_refclk [get_ports sfp_mgt_refclk_p]

# SFP+ port 0 (GTYE4_CHANNEL_X0Y15)
set_property -dict {LOC A4 } [get_ports {sfp_rx_p[0]}]
set_property -dict {LOC A3 } [get_ports {sfp_rx_n[0]}]
set_property -dict {LOC B7 } [get_ports {sfp_tx_p[0]}]
set_property -dict {LOC B6 } [get_ports {sfp_tx_n[0]}]

# SFP+ port 1 (GTYE4_CHANNEL_X0Y14)
set_property -dict {LOC B2 } [get_ports {sfp_rx_p[1]}]
set_property -dict {LOC B1 } [get_ports {sfp_rx_n[1]}]
set_property -dict {LOC D7 } [get_ports {sfp_tx_p[1]}]
set_property -dict {LOC D6 } [get_ports {sfp_tx_n[1]}]

# SFP+ cage link-status LEDs (active-low): DS3 / DS2 next to the cages.
set_property -dict {LOC B12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {sfp_led[0]}]
set_property -dict {LOC C12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {sfp_led[1]}]
set_false_path -to [get_ports {sfp_led[*]}]
