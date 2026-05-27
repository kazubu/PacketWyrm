# MMCM-based housekeeping clock generator: sys_clk -> clk_100mhz.
# Phase 1 only needs a stable 100 MHz domain for the heartbeat. The
# 250 MHz PCIe user clock comes from the PCIe IP itself.

set ip_name clk_wiz_100

create_ip -name clk_wiz \
          -vendor xilinx.com -library ip \
          -module_name $ip_name \
          -dir [get_property IP_OUTPUT_REPO [current_project]]

# Update PRIM_IN_FREQ to match the actual board sysclk frequency
# (from the AS02MC04 schematic). 100 MHz is a placeholder.
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ             {100.000}            \
    CONFIG.CLK_OUT1_PORT            {clk_out_100mhz}     \
    CONFIG.CLK_OUT1_REQUESTED_OUT_FREQ {100.000}         \
    CONFIG.RESET_TYPE               {ACTIVE_LOW}         \
    CONFIG.RESET_PORT               {resetn}             \
    CONFIG.USE_LOCKED               {true}               \
] [get_ips $ip_name]

generate_target {synthesis simulation} [get_ips $ip_name]
catch { synth_ip [get_ips $ip_name] }
