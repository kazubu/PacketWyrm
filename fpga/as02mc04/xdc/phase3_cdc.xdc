# Phase 3 board: the MAC<->data-plane async-FIFO crossings are handled
# by Taxi's taxi_axis_async_fifo.tcl (self-scoped). The data plane and
# CSR share axi_aclk, so no further CDC. Only the async LED outputs
# need exclusion.
set_false_path -to [get_ports {sfp_led[*]}]
set_false_path -to [get_ports {led[*]}]
