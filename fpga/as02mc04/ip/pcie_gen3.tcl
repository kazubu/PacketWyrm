# Generate the PCIe BAR -> AXI4-Lite bridge IP for AS02MC04 Phase 1.
#
# This script is sourced from project.tcl (and from the Makefile
# `make ip` target). It creates a single IP named `pcie_gen3_wrapper`
# so src/pcie_axi_lite_bridge.sv can bind to it by module name.
#
# ---------------------------------------------------------------------------
# WHY xdma (DMA/Bridge Subsystem) AND NOT pcie4_uscale_plus
# ---------------------------------------------------------------------------
# Phase 1 needs a *memory-mapped* BAR0 that the host reads as a 64 KB
# CSR window, i.e. the IP must present an AXI4-Lite **master** that is
# driven by host MMIO to BAR0. src/pcie_axi_lite_bridge.sv and
# src/pcie_gen3_stub.sv are both wired for exactly that interface
# (m_axil_*, axi_aclk/axi_aresetn, user_lnk_up).
#
# The bare "UltraScale+ Integrated Block for PCIe" (pcie4_uscale_plus)
# does NOT provide that. It exposes the transaction-layer AXI-Stream
# (CQ/CC/RQ/RC) and you must write your own completer to turn BAR
# accesses into AXI-Lite. The IP that gives a BAR-mapped AXI-Lite
# master out of the box is the **DMA/Bridge Subsystem for PCIe**
# (module `xdma`) configured in **AXI Bridge** functional mode with the
# AXI-Lite master interface enabled. That is what we generate here.
# (An earlier revision of this file mistakenly created pcie4_uscale_plus;
#  the surrounding RTL never matched that IP's ports.)
#
# ---------------------------------------------------------------------------
# VERSION SENSITIVITY  --  READ BEFORE FIRST BUILD
# ---------------------------------------------------------------------------
# The xdma CONFIG.* property names drift between Vivado releases. The
# set below is the canonical AXI-Bridge-mode configuration, but you
# MUST reconcile it against the Vivado version you actually install:
#
#   1. Run `make ip` once. If Vivado rejects a CONFIG key, open the IP
#      in the GUI (Vivado > IP Catalog > DMA/Bridge Subsystem for PCIe),
#      set the same intent (AXI Bridge, x8 Gen3, BAR0 64K AXI-Lite,
#      the IDs below), then `File > Export > Export IP configuration`
#      (or copy the `set_property -dict` block Vivado prints) back here.
#   2. After generation, open the instantiation template
#        build/<proj>.gen/sources_1/ip/pcie_gen3_wrapper/pcie_gen3_wrapper.veo
#      and reconcile src/pcie_axi_lite_bridge.sv against its exact port
#      list (clock/reset names, m_axil_* prot signals, user_lnk_up,
#      and how the differential refclk is brought in -- see CLOCKING).
#
# CLOCKING: this config requests "shared logic in the core" so the IP
# instantiates its own IBUFDS_GTE4 and takes the differential refclk
# pins directly (sys_clk_p / sys_clk_n), matching the bridge. If your
# Vivado version names these sys_clk/sys_clk_gt and expects an external
# IBUFDS_GTE4, add it in pcie_axi_lite_bridge.sv per the .veo.

set ip_name pcie_gen3_wrapper

create_ip -name xdma \
          -vendor xilinx.com -library ip \
          -module_name $ip_name \
          -dir [get_property IP_OUTPUT_REPO [current_project]]

set_property -dict [list \
    CONFIG.functional_mode                     {AXI_Bridge}           \
    CONFIG.mode_selection                      {Advanced}             \
    CONFIG.pl_link_cap_max_link_speed          {8.0_GT/s}             \
    CONFIG.pl_link_cap_max_link_width          {X8}                   \
    CONFIG.axi_addr_width                       {32}                  \
    CONFIG.axi_data_width                       {256_bit}             \
    CONFIG.axisten_freq                         {250}                 \
    CONFIG.pcie_blk_locn                        {X0Y0}                \
    CONFIG.pf0_bar0_enabled                     {true}                \
    CONFIG.bar0_indicator                       {0}                   \
    CONFIG.pf0_bar0_type_mqdma                  {AXI_Lite_Master}     \
    CONFIG.pf0_bar0_size                        {64}                  \
    CONFIG.pf0_bar0_scale                       {Kilobytes}           \
    CONFIG.pf0_device_id                        {A502}                \
    CONFIG.vendor_id                            {10EE}                \
    CONFIG.pf0_subsystem_vendor_id              {10EE}                \
    CONFIG.pf0_subsystem_id                     {7E57}                \
    CONFIG.pf0_class_code_base                  {02}                  \
    CONFIG.pf0_class_code_sub                   {80}                  \
    CONFIG.pf0_class_code_interface             {00}                  \
    CONFIG.pf0_revision_id                      {01}                  \
    CONFIG.pf0_msi_enabled                      {false}               \
    CONFIG.pf0_msix_enabled                     {false}               \
    CONFIG.cfg_mgmt_if                          {false}               \
    CONFIG.dma_reset_source_sel                 {Phy_Ready}           \
    CONFIG.shared_logic_in_core                 {true}                \
] [get_ips $ip_name]

generate_target {synthesis simulation instantiation_template} [get_ips $ip_name]
catch { synth_ip [get_ips $ip_name] }

puts "INFO: PCIe AXI-Bridge IP generated as $ip_name (xdma, AXI_Bridge mode)"
puts "INFO: Vendor=0x10EE (Xilinx) Device=0xA502 Subsystem=0x10EE:0x7E57 Class=0x028000"
puts "INFO: reconcile src/pcie_axi_lite_bridge.sv against pcie_gen3_wrapper.veo before synth"
puts "INFO: see docs/design/pci-ids.md for rationale; replace with a proper PCI-SIG allocation before production"
