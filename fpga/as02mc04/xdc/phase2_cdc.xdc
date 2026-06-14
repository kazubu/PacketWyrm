# Phase 2 clock-domain-crossing constraints for pw_sfp_traffic and the
# top-level SFP status synchroniser. The GT rx/tx user clocks are
# asynchronous to axi_aclk; these crossings are Gray-coded (counters) or
# 2-FF synchronised (single bits), so exclude them from normal timing.
# Source GT user clock period ~6.4 ns; axi_aclk 4.0 ns.

# --- Gray-coded RX/TX frame counters: src-domain gray reg -> axi 1st FF ---
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].rx_gray_tx_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].rx_g1_reg[*]}] 6.400
set_bus_skew \
    -from [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].rx_gray_tx_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].rx_g1_reg[*]}] 4.000

set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].tx_gray_tx_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].tx_g1_reg[*]}] 6.400
set_bus_skew \
    -from [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].tx_gray_tx_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].tx_g1_reg[*]}] 4.000

# --- single-bit synchronisers (false paths to the first capture FF) ------
# tx_enable (axi) -> txen_sync (tx_clk)
set_false_path -to [get_cells -hier -filter {NAME =~ *u_traffic/g_port[*].txen_sync_reg[0]}]
# SFP status bits (rx/ctrl) -> sfp_stat_s1 (axi)
set_false_path -to [get_cells -hier -filter {NAME =~ *sfp_stat_s1_reg[*]}]
