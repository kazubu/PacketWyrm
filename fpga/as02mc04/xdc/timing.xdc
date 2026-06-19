# AS02MC04 timing constraints.

# 100 MHz LVDS housekeeping clock (E18/D18 -> clk_100mhz_p)
create_clock -period 10.000 -name clk_100mhz [get_ports clk_100mhz_p]

# 100 MHz PCIe MGT reference clock (T7/T6 -> pcie_refclk_p)
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# clk_100mhz and the PCIe user clock (250 MHz, generated inside the
# PCIe Gen3 hard IP) are asynchronous. Reset is double-flop
# synchronised in clock_reset.sv; data paths between the two are
# absent in Phase 1.
set_false_path -from [get_clocks clk_100mhz] -to [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *u_pcie/*/USERCLK*}]] -quiet
set_false_path -from [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *u_pcie/*/USERCLK*}]] -to [get_clocks clk_100mhz] -quiet

# Phase 2 adds the 156.25 MHz SFP MGT refclk; left commented for now.
# create_clock -period 6.400 -name sfp_mgt_refclk [get_ports sfp_mgt_refclk_p]

# --- Quasi-static flow/classifier table commit (pw_csr_window) -------------
# The host stages a shadow table, pulses a commit register, and the data plane
# only relies on the promoted "live" table after the commit settles (the BRAM
# flow table even walks it in over many cycles). These shadow->live promotion
# paths are therefore quasi-static and need not meet a single dp_clk period;
# relaxing them frees the placer/router from a large, scattered FF->FF transfer
# that was on the dp_clk critical floor.
set_multicycle_path -setup 4 -from [get_cells -hier -filter {NAME =~ *u_win/shadow_reg*}] -to [get_cells -hier -filter {NAME =~ *u_win/live_reg*}] -quiet
set_multicycle_path -hold  3 -from [get_cells -hier -filter {NAME =~ *u_win/shadow_reg*}] -to [get_cells -hier -filter {NAME =~ *u_win/live_reg*}] -quiet
