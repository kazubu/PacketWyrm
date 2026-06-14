# Throwaway probe: does XDMA in DMA mode + axilite_master_en expose an
# m_axil_* AXI-Lite master (matching the existing RTL)? Generate only
# the instantiation template (fast) and dump the master interfaces.
create_project -in_memory -part xcku3p-ffvb676-1-e probe_xdma
create_ip -name xdma -vendor xilinx.com -library ip -module_name probe_dma_axil \
    -dir /tmp/probe_ip
set ip [get_ips probe_dma_axil]
foreach {k v} {
    CONFIG.mode_selection                 Advanced
    CONFIG.functional_mode                DMA
    CONFIG.pl_link_cap_max_link_speed     8.0_GT/s
    CONFIG.pl_link_cap_max_link_width     X8
    CONFIG.axi_data_width                 256_bit
    CONFIG.axisten_freq                   250
    CONFIG.axilite_master_en              true
    CONFIG.axilite_master_scale           Kilobytes
    CONFIG.axilite_master_size            64
    CONFIG.pf0_device_id                  A502
    CONFIG.vendor_id                      10EE
    CONFIG.pf0_msi_enabled                false
    CONFIG.pf0_msix_enabled               false
} {
    if {[catch {set_property $k $v $ip} e]} { puts "FAIL $k -> $v : $e" } else { puts "OK $k=[get_property $k $ip]" }
}
generate_target {instantiation_template} $ip
set veo [glob -nocomplain /tmp/probe_ip/probe_dma_axil/*.veo]
puts "=== veo: $veo ==="
if {$veo ne ""} {
    set fh [open [lindex $veo 0] r]; set txt [read $fh]; close $fh
    foreach line [split $txt "\n"] {
        if {[regexp {\.(m_axil_|m_axi_|c2h_|h2c_|m_axib_)} $line]} { puts $line }
    }
}
puts "=== END ==="
