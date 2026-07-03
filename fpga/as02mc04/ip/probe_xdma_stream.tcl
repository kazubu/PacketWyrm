# Throwaway probe: can XDMA be configured in AXI-Stream mode (H2C/C2H AXIS)
# while keeping the AXI-Lite master CSR BAR, and does the XDMA control BAR
# become available? Generates only the instantiation template (fast) and dumps
# the resulting master/stream interfaces + relevant CONFIG readbacks.
#
# Run: vivado -mode batch -source ip/probe_xdma_stream.tcl
create_project -in_memory -part xcku3p-ffvb676-1-e probe_xdma_stream
create_ip -name xdma -vendor xilinx.com -library ip -module_name probe_dma_st \
    -dir /tmp/probe_ip_st
set ip [get_ips probe_dma_st]

# Base config identical to the production IP, then flip the DMA interface to
# AXI-Stream and (try to) enable/size the XDMA control BAR.
foreach {k v} {
    CONFIG.mode_selection                 Advanced
    CONFIG.functional_mode                DMA
    CONFIG.pl_link_cap_max_link_speed     8.0_GT/s
    CONFIG.pl_link_cap_max_link_width     X8
    CONFIG.axi_data_width                 256_bit
    CONFIG.axisten_freq                   250
    CONFIG.xdma_axi_intf_mm               AXI_Stream
    CONFIG.axilite_master_en              true
    CONFIG.axilite_master_scale           Kilobytes
    CONFIG.axilite_master_size            64
    CONFIG.xdma_axilite_slave             false
    CONFIG.pf0_device_id                  A502
    CONFIG.vendor_id                      10EE
    CONFIG.pf0_msi_enabled                false
    CONFIG.pf0_msix_enabled               false
} {
    if {[catch {set_property $k $v $ip} e]} { puts "FAIL $k -> $v : $e" } else { puts "OK $k=[get_property $k $ip]" }
}

# Dump some readbacks that tell us the control-BAR / channel layout.
foreach k {CONFIG.xdma_axi_intf_mm CONFIG.functional_mode CONFIG.H2C_XDMA_CHNL \
           CONFIG.C2H_XDMA_CHNL CONFIG.XDMA_APERTURE_SIZE CONFIG.xdma_size \
           CONFIG.xdma_scale CONFIG.axilite_master_en CONFIG.xdma_num_usr_irq \
           CONFIG.pciebar2axibar_xdma CONFIG.pciebar2axibar_axil_master} {
    if {[catch {set val [get_property $k $ip]} e]} { puts "READ-FAIL $k : $e" } else { puts "READBACK $k = $val" }
}

generate_target {instantiation_template} $ip
set veo [glob -nocomplain /tmp/probe_ip_st/probe_dma_st/*.veo]
puts "=== veo: $veo ==="
if {$veo ne ""} {
    set fh [open [lindex $veo 0] r]; set txt [read $fh]; close $fh
    foreach line [split $txt "\n"] {
        if {[regexp {\.(m_axil_|m_axi_|m_axis_h2c|s_axis_c2h|c2h_|h2c_|usr_irq|m_axib_)} $line]} { puts $line }
    }
}
puts "=== END ==="
