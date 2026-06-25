# Phase 3 board: the MAC<->data-plane async-FIFO crossings are handled
# by Taxi's taxi_axis_async_fifo.tcl (self-scoped).
#
# The data plane now runs on dp_clk (156.25 MHz, MMCM CLKOUT1 via BUFG b2),
# while the host BAR stays on axi_aclk (250 MHz PCIe user clock). The two
# domains are bridged by the AXI4-Lite clock converter (u_axil_cc), which
# owns its own crossing; declare the clocks asynchronous so the analyzer
# does not time paths between them as if synchronous.
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins u_axil_cc/s_axi_aclk]] \
    -group [get_clocks dp_clk_u]

# DP_RESET egress-flush single-bit CDC: the stretched flush level (dp_clk,
# pw_mac_axis_cdc flush_cnt) crosses into each MAC tx_clk through a 3-FF
# ASYNC_REG synchroniser (flush_sync). It is a slow control level (asserted for
# tens of cycles on a host soft-reset), so exclude the crossing to the first
# capture FF from timing -- the synchroniser handles metastability. Mirrors the
# link-status / tx_enable single-bit syncs (timing.xdc, phase2_cdc.xdc).
set_false_path -to [get_cells -hier -filter {NAME =~ *flush_sync_reg[0]}]

# Async LED outputs.
set_false_path -to [get_ports {sfp_led[*]}]
set_false_path -to [get_ports {led[*]}]
