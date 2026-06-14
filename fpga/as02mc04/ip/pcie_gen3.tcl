# Generate the PCIe BAR -> AXI4-Lite bridge IP for AS02MC04 Phase 1.
#
# This script is sourced from project.tcl (and from the Makefile
# `make ip` target). It creates a single IP named `pcie_gen3_wrapper`
# so src/pcie_axi_lite_bridge.sv can bind to it by module name.
#
# ---------------------------------------------------------------------------
# WHY xdma DMA mode + AXI-Lite Master (and not pcie4_uscale_plus / AXI_Bridge)
# ---------------------------------------------------------------------------
# Phase 1 needs a *memory-mapped* BAR that the host reads as a 64 KB CSR
# window, i.e. the IP must present an AXI4-Lite **master** (m_axil_*)
# driven by host MMIO. src/pcie_axi_lite_bridge.sv / pcie_gen3_stub.sv
# are wired for exactly that.
#
#   - pcie4_uscale_plus (bare integrated block) exposes only the
#     AXI-Stream transaction layer (CQ/CC/RQ/RC) -- no BAR AXI master.
#   - xdma in AXI_Bridge mode exposes m_axib_* (AXI4 *full* master,
#     256-bit) for the BAR aperture -- would need a SmartConnect to
#     downsize/convert to the 32-bit AXI-Lite CSR slave.
#   - xdma in **DMA mode with axilite_master_en** exposes m_axil_*
#     (AXI4-Lite master, 32-bit) that connects directly to pw_csr_min.
#     Verified on this board's IP: see the .veo port list. The DMA
#     engine (m_axi_*, c2h/h2c) is unused in Phase 1 and tied off; it
#     is also what Phase 2's host punt/inject DMA rings will use.
#
# ---------------------------------------------------------------------------
# VERSION SENSITIVITY
# ---------------------------------------------------------------------------
# The CONFIG.* dict below was validated key-by-key against xdma in
# Vivado 2025.2 (ip/probe_xdma.tcl). On a different release, if Vivado
# rejects a key, set the same intent in the IP GUI and copy its
# set_property block back here. After generation, the bridge is bound
# to the generated wrapper ports (sys_clk/sys_clk_gt/sys_rst_n,
# m_axil_*, user_lnk_up) -- reconcile src/pcie_axi_lite_bridge.sv
# against pcie_gen3_wrapper.veo if the port list differs.
#
# CLOCKING: the IP takes sys_clk (refclk/2 via ODIV2) + sys_clk_gt
# (raw refclk) from an external IBUFDS_GTE4 on the differential refclk
# pins; that buffer lives in pcie_axi_lite_bridge.sv.

set ip_name pcie_gen3_wrapper

create_ip -name xdma \
          -vendor xilinx.com -library ip \
          -module_name $ip_name \
          -dir [get_property IP_OUTPUT_REPO [current_project]]

# Config validated key-by-key against the xdma IP in Vivado 2025.2
# (see ip/probe_xdma.tcl). The BAR0 CSR window is exposed as the IP's
# AXI-Lite *master* (axilite_master_en), 64 KB, not via pf0_bar0_type.
set_property -dict [list \
    CONFIG.mode_selection                      {Advanced}             \
    CONFIG.functional_mode                     {DMA}                  \
    CONFIG.pl_link_cap_max_link_speed          {8.0_GT/s}             \
    CONFIG.pl_link_cap_max_link_width          {X8}                   \
    CONFIG.axi_data_width                       {256_bit}             \
    CONFIG.axisten_freq                         {250}                 \
    CONFIG.axilite_master_en                    {true}                \
    CONFIG.axilite_master_scale                 {Kilobytes}           \
    CONFIG.axilite_master_size                  {64}                  \
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
] [get_ips $ip_name]

# generate_target produces RTL + the .veo instantiation template. The
# IP is synthesised out-of-context automatically by the main synth run,
# so we do NOT call synth_ip here (unsupported in project mode).
generate_target {synthesis simulation instantiation_template} [get_ips $ip_name]

puts "INFO: PCIe IP generated as $ip_name (xdma, DMA mode + AXI-Lite master)"
puts "INFO: Vendor=0x10EE (Xilinx) Device=0xA502 Subsystem=0x10EE:0x7E57 Class=0x028000"
puts "INFO: reconcile src/pcie_axi_lite_bridge.sv against pcie_gen3_wrapper.veo before synth"
puts "INFO: see docs/design/pci-ids.md for rationale; replace with a proper PCI-SIG allocation before production"
