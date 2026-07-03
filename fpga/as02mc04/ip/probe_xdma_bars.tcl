# Throwaway probe (#2 review): enumerate the XDMA PCIe BARs for the PRODUCTION
# AXI-Stream config, and separately test whether enabling the XDMA control BAR
# (pciebar2axibar_xdma) succeeds. Goal: confirm the DMA descriptor/SGDMA control
# register block has a reachable PCIe BAR under vfio before committing to P2.
#
# Run: vivado -mode batch -source ip/probe_xdma_bars.tcl
create_project -in_memory -part xcku3p-ffvb676-1-e probe_xdma_bars
file mkdir /tmp/probe_bars

proc dump_bars {ip tag} {
    puts "==== BAR enumeration ($tag) ===="
    foreach k [list \
        CONFIG.bar0_size CONFIG.bar0_scale CONFIG.bar0_type CONFIG.bar0_64bit \
        CONFIG.bar1_size CONFIG.bar1_scale CONFIG.bar1_type \
        CONFIG.bar2_size CONFIG.bar2_scale CONFIG.bar2_type \
        CONFIG.pf0_bar0_scale CONFIG.pf0_bar0_size CONFIG.pf0_bar0_type CONFIG.pf0_bar0_enabled \
        CONFIG.pf0_bar1_enabled CONFIG.pf0_bar2_enabled CONFIG.pf0_bar2_scale CONFIG.pf0_bar2_size \
        CONFIG.pf0_bar4_enabled CONFIG.pf0_bar4_scale CONFIG.pf0_bar4_size \
        CONFIG.xdma_pcie_64bit_en CONFIG.xdma_rnum_chnl \
        CONFIG.pciebar2axibar_xdma CONFIG.pciebar2axibar_axil_master \
        CONFIG.axilite_master_en CONFIG.XDMA_APERTURE_SIZE \
        CONFIG.AXILITE_MASTER_APERTURE_SIZE CONFIG.AXILITE_MASTER_CONTROL] {
        if {[catch {set v [get_property $k $ip]} e]} {
            puts "  READ-FAIL $k"
        } else { puts "  $k = $v" }
    }
}

# --- production config (what pcie_gen3.tcl generates today) ---
create_ip -name xdma -vendor xilinx.com -library ip -module_name probe_prod -dir /tmp/probe_bars
set ip [get_ips probe_prod]
set_property -dict [list \
    CONFIG.mode_selection Advanced CONFIG.functional_mode DMA \
    CONFIG.pl_link_cap_max_link_speed 8.0_GT/s CONFIG.pl_link_cap_max_link_width X8 \
    CONFIG.axi_data_width 256_bit CONFIG.axisten_freq 250 \
    CONFIG.xdma_axi_intf_mm AXI_Stream CONFIG.xdma_axilite_slave false \
    CONFIG.axilite_master_en true CONFIG.axilite_master_scale Kilobytes CONFIG.axilite_master_size 64 \
    CONFIG.pf0_msi_enabled false CONFIG.pf0_msix_enabled false] $ip
dump_bars $ip "PRODUCTION AXI_Stream, control BAR NOT explicitly enabled"

# --- try to explicitly enable the XDMA control BAR ---
if {[catch {set_property CONFIG.pciebar2axibar_xdma {true} $ip} e]} {
    puts "ENABLE-TRY pciebar2axibar_xdma=true FAILED: $e"
    # some releases key the control-BAR enable differently; probe candidates
    foreach {k v} {CONFIG.xdma_bar_en true CONFIG.dma_bar_en true CONFIG.xdma_control_bar_en true} {
        if {[catch {set_property $k $v $ip} e2]} { puts "  cand $k=$v FAILED: $e2" } \
        else { puts "  cand $k=$v OK -> [get_property $k $ip]" }
    }
} else {
    puts "ENABLE-TRY pciebar2axibar_xdma=true OK -> [get_property CONFIG.pciebar2axibar_xdma $ip]"
}
dump_bars $ip "AFTER control-BAR enable attempt"
puts "=== END PROBE ==="
