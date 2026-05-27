# Timing constraints for the AS02MC04 Phase 1 bitstream.

# Generated clocks
# The PCIe Gen3 hard IP produces its own 250 MHz user clock; we tell
# the timing engine to treat it as asynchronous to sys_clk.
# (The hard IP exports these as create_generated_clock automatically.)

# False path between sys_clk and the PCIe user clock domain. They are
# physically asynchronous; resets are double-flop-synchronised in
# clock_reset.sv.
# set_false_path -from [get_clocks sys_clk] -to [get_clocks pcie_user_clk]
# set_false_path -from [get_clocks pcie_user_clk] -to [get_clocks sys_clk]

# Asynchronous reset path: sys_rst_n is debounced + synchronised in
# clock_reset.sv.
# set_false_path -from [get_ports sys_rst_n] \
#                -to   [get_clocks {sys_clk pcie_user_clk}]

# Timestamp counter does not feed any combinational reception path
# in Phase 1; no constraint needed yet.
