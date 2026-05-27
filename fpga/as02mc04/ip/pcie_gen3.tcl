# Generate the Xilinx PCIe Gen3 hard IP for AS02MC04 Phase 1.
#
# This script is sourced from project.tcl (and from the Makefile
# `make ip` target). It creates a single IP named `pcie_gen3_wrapper`
# so the top-level RTL (src/pcie_axi_lite_bridge.sv) can bind to it
# without conditional code.
#
# The actual IP name / version depends on the Vivado release. For
# UltraScale+ devices use `pcie4_uscale_plus`. Adjust below for the
# Vivado version actually installed.

set ip_name pcie_gen3_wrapper

create_ip -name pcie4_uscale_plus \
          -vendor xilinx.com -library ip \
          -module_name $ip_name \
          -dir [get_property IP_OUTPUT_REPO [current_project]]

set_property -dict [list \
    CONFIG.PL_LINK_CAP_MAX_LINK_SPEED         {8.0_GT/s}              \
    CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH         {X8}                    \
    CONFIG.AXISTEN_IF_RC_STRADDLE             {false}                 \
    CONFIG.PCIE_BOARD_INTERFACE                {Custom}               \
    CONFIG.axisten_freq                        {250}                  \
    CONFIG.coreclk_freq                        {500}                  \
    CONFIG.PF0_DEVICE_ID                       {0xA502}               \
    CONFIG.PF0_VENDOR_ID                       {0x1AF4}               \
    CONFIG.PF0_SUBSYSTEM_VENDOR_ID             {0x1AF4}               \
    CONFIG.PF0_SUBSYSTEM_ID                    {0x4D43}               \
    CONFIG.PF0_CLASS_CODE                      {0x028000}             \
    CONFIG.PF0_REVISION_ID                     {0x01}                 \
    CONFIG.PF0_BAR0_SIZE                       {64}                   \
    CONFIG.PF0_BAR0_SCALE                      {Kilobytes}            \
    CONFIG.PF0_MSI_ENABLED                     {false}                \
    CONFIG.PF0_MSIX_ENABLED                    {false}                \
] [get_ips $ip_name]

generate_target {synthesis simulation} [get_ips $ip_name]
catch { synth_ip [get_ips $ip_name] }

puts "INFO: PCIe Gen3 IP generated as $ip_name"
puts "INFO: Vendor=0x1AF4 Device=0xA502 (placeholder; finalise with the AS02MC04 PCI ID assignment)"
