# AS02MC04 pin assignments.
#
# All pin locations below are derived from the published reverse
# engineering work for the Alibaba Cloud AS02MC04 board:
#
#   - https://essenceia.github.io/projects/alibaba_cloud_fpga/
#     (Julia Desmazes, 2025) - confirmed 100 MHz LVDS clock,
#     156.25 MHz MGT refclk, and four user LEDs.
#   - https://github.com/fpganinja/taxi/blob/<sha>/src/cndm/board/
#     AS02MC04/fpga/fpga.xdc  (FPGA Ninja, LLC, CERN-OHL-S-2.0) -
#     full PCIe / SFP+ / control-pin pinout. See top-level LICENSE.
#
# Phase 1 only uses the PCIe and LED / reset pins. SFP+ entries are
# included (commented out) so Phase 2 just needs to uncomment.

############################################################
# 100 MHz global system clock (Y2 oscillator, bank 67)
############################################################
set_property -dict {LOC E18  IOSTANDARD LVDS} [get_ports clk_100mhz_p]
set_property -dict {LOC D18  IOSTANDARD LVDS} [get_ports clk_100mhz_n]

############################################################
# PCIe Gen3 x8 (bank 224 + 225)
############################################################
# 100 MHz PCIe MGT reference clock (MGTREFCLK1_225)
set_property -dict {LOC T7  } [get_ports pcie_refclk_p]
set_property -dict {LOC T6  } [get_ports pcie_refclk_n]

# PCIe PERST# from the host
set_property -dict {LOC A9   IOSTANDARD LVCMOS33 PULLUP true} [get_ports pcie_reset_n]
set_false_path -from [get_ports pcie_reset_n]
set_input_delay 0    [get_ports pcie_reset_n]

# 8 PCIe lanes
set_property -dict {LOC P2  } [get_ports {pcie_rx_p[0]}]
set_property -dict {LOC P1  } [get_ports {pcie_rx_n[0]}]
set_property -dict {LOC R5  } [get_ports {pcie_tx_p[0]}]
set_property -dict {LOC R4  } [get_ports {pcie_tx_n[0]}]
set_property -dict {LOC T2  } [get_ports {pcie_rx_p[1]}]
set_property -dict {LOC T1  } [get_ports {pcie_rx_n[1]}]
set_property -dict {LOC U5  } [get_ports {pcie_tx_p[1]}]
set_property -dict {LOC U4  } [get_ports {pcie_tx_n[1]}]
set_property -dict {LOC V2  } [get_ports {pcie_rx_p[2]}]
set_property -dict {LOC V1  } [get_ports {pcie_rx_n[2]}]
set_property -dict {LOC W5  } [get_ports {pcie_tx_p[2]}]
set_property -dict {LOC W4  } [get_ports {pcie_tx_n[2]}]
set_property -dict {LOC Y2  } [get_ports {pcie_rx_p[3]}]
set_property -dict {LOC Y1  } [get_ports {pcie_rx_n[3]}]
set_property -dict {LOC AA5 } [get_ports {pcie_tx_p[3]}]
set_property -dict {LOC AA4 } [get_ports {pcie_tx_n[3]}]
set_property -dict {LOC AB2 } [get_ports {pcie_rx_p[4]}]
set_property -dict {LOC AB1 } [get_ports {pcie_rx_n[4]}]
set_property -dict {LOC AC5 } [get_ports {pcie_tx_p[4]}]
set_property -dict {LOC AC4 } [get_ports {pcie_tx_n[4]}]
set_property -dict {LOC AD2 } [get_ports {pcie_rx_p[5]}]
set_property -dict {LOC AD1 } [get_ports {pcie_rx_n[5]}]
set_property -dict {LOC AD7 } [get_ports {pcie_tx_p[5]}]
set_property -dict {LOC AD6 } [get_ports {pcie_tx_n[5]}]
set_property -dict {LOC AE4 } [get_ports {pcie_rx_p[6]}]
set_property -dict {LOC AE3 } [get_ports {pcie_rx_n[6]}]
set_property -dict {LOC AE9 } [get_ports {pcie_tx_p[6]}]
set_property -dict {LOC AE8 } [get_ports {pcie_tx_n[6]}]
set_property -dict {LOC AF2 } [get_ports {pcie_rx_p[7]}]
set_property -dict {LOC AF1 } [get_ports {pcie_rx_n[7]}]
set_property -dict {LOC AF7 } [get_ports {pcie_tx_p[7]}]
set_property -dict {LOC AF6 } [get_ports {pcie_tx_n[7]}]

############################################################
# LEDs (all LVCMOS33; original "1.8V" silkscreen is misleading)
############################################################
# led_hb (B9, DS5) - 1 Hz heartbeat: FPGA is alive
# led[1] (C11, DS7) - PCIe link up
# led[0,2,3] - reserved for SFP / per-port status (Phase 2)
# sfp_led[0..1], led_r, led_g - unconnected in Phase 1. Phase 2+ wires sfp_led
#   in sfp.xdc; Phase 3 wires the R/G health LED (led_r=A13, led_g=A12) in the
#   phase3-only gpio_phase3.xdc (those ports don't exist in the Phase 1/2 tops).
set_property -dict {LOC B9   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports led_hb]
set_property -dict {LOC B11  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[0]}]
set_property -dict {LOC C11  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[1]}]
set_property -dict {LOC A10  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[2]}]
set_property -dict {LOC B10  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[3]}]

set_false_path     -to [get_ports {led[*] led_hb}]
set_output_delay 0    [get_ports {led[*] led_hb}]

############################################################
# Phase 2: SFP+ ports 0 and 1, MGT bank 227 (commented)
############################################################
# 156.25 MHz MGTREFCLK0_227 (Y1 oscillator)
# set_property -dict {LOC K7  } [get_ports sfp_mgt_refclk_p]
# set_property -dict {LOC K6  } [get_ports sfp_mgt_refclk_n]
#
# SFP+ port 0 (GTYE4_CHANNEL_X0Y15)
# set_property -dict {LOC A4  } [get_ports {sfp_rx_p[0]}]
# set_property -dict {LOC A3  } [get_ports {sfp_rx_n[0]}]
# set_property -dict {LOC B7  } [get_ports {sfp_tx_p[0]}]
# set_property -dict {LOC B6  } [get_ports {sfp_tx_n[0]}]
#
# SFP+ port 1 (GTYE4_CHANNEL_X0Y14)
# set_property -dict {LOC B2  } [get_ports {sfp_rx_p[1]}]
# set_property -dict {LOC B1  } [get_ports {sfp_rx_n[1]}]
# set_property -dict {LOC D7  } [get_ports {sfp_tx_p[1]}]
# set_property -dict {LOC D6  } [get_ports {sfp_tx_n[1]}]
#
# SFP+ control / status (LVCMOS33)
# set_property -dict {LOC D14  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_npres[0]}]
# set_property -dict {LOC E11  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_npres[1]}]
# set_property -dict {LOC B14  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_tx_fault[0]}]
# set_property -dict {LOC F9   IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_tx_fault[1]}]
# set_property -dict {LOC D13  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_los[0]}]
# set_property -dict {LOC E10  IOSTANDARD LVCMOS33 PULLUP true} [get_ports {sfp_los[1]}]

############################################################
# Board reset button (SW1) - optional, unused in Phase 1
############################################################
# set_property -dict {LOC F12  IOSTANDARD LVCMOS33} [get_ports reset_btn_n]

# NOTE: the J5 header GPIO constraints (cross-card time sync) live in the
# Phase 3-only xdc/gpio_phase3.xdc -- NOT here. This pinout.xdc is shared with
# the Phase 1/2 projects, whose tops have no `gpio` port, so a gpio constraint
# here would error (empty get_ports) in those builds.
