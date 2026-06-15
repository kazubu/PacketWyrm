# AXI4-Lite clock converter: PCIe BAR (axi_aclk, 250 MHz) -> data-plane
# clock (dp_clk, 156.25 MHz). Lets pwfpga_top_phase3 run single-clock at
# line rate while the host BAR stays in the fixed PCIe user-clock domain.
# The data path (parser/classifier/checker/SAF) does not meet 250 MHz; a
# 64-bit plane only needs 156.25 MHz = 10G line rate.

set ip_name axi_clk_conv

# No -dir: let create_ip drop the IP in the project's default IP sources
# location (.srcs/sources_1/ip), the same place pcie_gen3_wrapper lands.
# (IP_OUTPUT_REPO resolves to a non-existent .cache/ip after the first IP.)
create_ip -name axi_clock_converter \
          -vendor xilinx.com -library ip \
          -module_name $ip_name

set_property -dict [list \
    CONFIG.PROTOCOL    {AXI4LITE} \
    CONFIG.DATA_WIDTH  {32}       \
    CONFIG.ADDR_WIDTH  {16}       \
    CONFIG.ID_WIDTH    {0}        \
] [get_ips $ip_name]

# Project mode: generate targets (synth_ip is unsupported here).
generate_target {synthesis simulation instantiation_template} [get_ips $ip_name]
