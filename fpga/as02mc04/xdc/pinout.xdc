# AS02MC04 pin assignments for Phase 1.
#
# !!! TODO !!!
# Every entry below marked AS02MC04_PIN_TBD must be replaced with the
# real pin from the AS02MC04 board schematic before the bitstream is
# usable on hardware. Synthesis will succeed without this, but the
# implementation step will either fail to place or place silently to
# wrong pads.
#
# The expected sources:
#   - PCIe lanes (Gen3 x8)         : SLR / GTY quad documented in the
#                                    Kintex UltraScale+ KU3P pkg pinout
#                                    crossed against the AS02MC04 PCB
#                                    rev N schematic.
#   - SFP+ cages (port 0 and 1)    : GTY quad pair, populated in Phase 2.
#   - sysclk                       : board's MMCM-capable LVDS clock.
#   - sys_rst_n                    : push button / PERST# fanout.
#   - LEDs                         : user LEDs, polarity from schematic.

############################################################
# PCIe
############################################################
# PCIe x8 lanes, RX/TX pairs. Use GTY transceiver locations and let
# the PCIe IP wrapper auto-place; only the refclk and PERST# need
# explicit XDC entries.

# 100 MHz PCIe reference clock (differential)
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports pcie_refclk_p]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports pcie_refclk_n]
# create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# PCIe PERST#
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports pcie_perst_n]
# set_property IOSTANDARD  LVCMOS18         [get_ports pcie_perst_n]
# set_property PULLUP      true             [get_ports pcie_perst_n]

############################################################
# Board reference clock and reset
############################################################
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports sys_clk_p]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports sys_clk_n]
# set_property IOSTANDARD  LVDS             [get_ports {sys_clk_p sys_clk_n}]
# create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports sys_rst_n]
# set_property IOSTANDARD  LVCMOS18         [get_ports sys_rst_n]
# set_property PULLUP      true             [get_ports sys_rst_n]

############################################################
# User LEDs (4)
############################################################
# led[0] heartbeat, led[1] PCIe link up, led[2..3] reserved for SFP links
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports {led[0]}]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports {led[1]}]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports {led[2]}]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports {led[3]}]
# set_property IOSTANDARD  LVCMOS18         [get_ports {led[*]}]

############################################################
# SFP+ port 0 / 1 (Phase 2)
############################################################
# Placeholder for the two SFP+ cages. Phase 2 fills these in along
# with the 156.25 MHz reference clock for the 10GBASE-R PCS/MAC.
#
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports sfp0_tx_p]
# set_property PACKAGE_PIN AS02MC04_PIN_TBD [get_ports sfp0_tx_n]
# ...
