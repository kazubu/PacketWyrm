# Phase 3 board: the MAC<->data-plane async-FIFO crossings are handled
# by Taxi's taxi_axis_async_fifo.tcl (self-scoped).
#
# The data plane runs on dp_clk (156.25 MHz, MMCM CLKOUT1 via BUFG b2), while
# the host BAR stays on axi_aclk (250 MHz PCIe user clock). The two domains are
# bridged by the AXI4-Lite clock converter (u_axil_cc), which ships its own
# point-to-point CDC constraints (XPM handshake set_max_delay -datapath_only).
# Do NOT add a broad `set_clock_groups -asynchronous` between axi_aclk and
# dp_clk here: it OVERRIDES those IP constraints (Vivado TIMING-24) and leaves
# the handshake datapaths effectively unconstrained. The IP's own constraints
# cover the only axi_aclk<->dp_clk crossing (u_axil_cc); rely on them.

# DP_RESET egress-flush single-bit CDC: the stretched flush level (dp_clk,
# pw_mac_axis_cdc flush_cnt) crosses into each MAC tx_clk through a 3-FF
# ASYNC_REG synchroniser (flush_sync). It is a slow control level (asserted for
# tens of cycles on a host soft-reset), so exclude the crossing to the first
# capture FF from timing -- the synchroniser handles metastability. Mirrors the
# link-status / tx_enable single-bit syncs (timing.xdc, phase2_cdc.xdc).
set_false_path -to [get_cells -hier -filter {NAME =~ *flush_sync_reg[0]}]

# Egress timestamp Gray CDC (pw_ts_gray_cdc, one per port): the Gray-coded
# counter crosses dp_clk -> each MAC tx_clk. Bound the source-reg -> first-sync
# delay (datapath-only) and the inter-bit skew so a sample mid-increment
# resolves to N or N+1 (Gray guarantees one bit changes), never a far value.
# Both domains ~6.4 ns; constrain to one period. Without these the crossing is
# (incorrectly) timed as synchronous between unrelated clocks (TIMING-6/7).
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *u_tscdc/gray_src_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_tscdc/sync1_reg[*]}] 6.400
set_bus_skew \
    -from [get_cells -hier -filter {NAME =~ *u_tscdc/gray_src_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *u_tscdc/sync1_reg[*]}] 6.400

# Reset-synchroniser async-assert crossings. With the broad axi<->dp clock_groups
# removed (above), the async-reset (CLR) inputs of these reset synchronisers are
# otherwise timed across unrelated clocks (e.g. PCIe user_reset -> dp_rstn_sync,
# a long reset-distribution net -> huge negative slack). The assert is async by
# design and the 2-FF synchroniser handles deassert metastability, so exclude the
# assert path. (The AXI clk-converter DATA handshake is NOT excluded here -- it
# keeps the IP's own set_max_delay -datapath_only, which the clock_groups used to
# override, TIMING-24.)
set_false_path -to [get_pins -hier -filter {NAME =~ *dp_rstn_sync_reg[*]/CLR}]

# --- CDC-10 methodology waivers: intentional reset-source merges ------------
# These two reset paths combine async reset SOURCES with a gate before a reset
# synchroniser (CDC-10 "combinational logic before a synchronizer"). The merge
# is REQUIRED and correct, not a hazard: an MMCM lock loss must assert reset
# IMMEDIATELY (async), but the dependent clock is the MMCM's own output and
# stops on lock loss -- so the assert cannot be synchronised. The gate drives
# only the synchroniser's async-ASSERT input; the DEASSERT is 2-FF synchronised.
# A glitch on the merge can only over-assert reset (safe). Waived with rationale
# per review -- NOT silently "resolved".
create_waiver -type CDC -id {CDC-10} \
    -to [get_pins -hier -filter {NAME =~ *dp_rstn_sync_reg[*]/CLR}] \
    -user pw \
    -description {Intentional reset merge axi_aresetn & mmcm_lock -> dp_clk reset synchroniser async-assert. Async assert required for MMCM lock-loss (dp_clk = MMCM output, stops on lock loss); deassert is 2-FF synchronised.}
create_waiver -type CDC -id {CDC-10} \
    -to [get_pins -hier -filter {NAME =~ *u_sfp_sync_reset/sync_reg_reg[*]/PRE}] \
    -user pw \
    -description {Intentional reset merge !rst_n_100 || !mmcm_lock -> SFP control reset synchroniser async-assert. Same rationale: lock-loss must assert even when the MMCM-derived clk_125mhz stops; deassert synchronised in pw_sfp_10g.}

# NOTE: 2 further CDC-10 remain inside the Taxi GT vendor IP (pw_sfp_10g:
# gt_rx_reset_inst rx_reset_done -> rx_reset_sync). They are vendor-owned,
# pre-existing, and unmodified by this work -- left unwaived here (waiving
# third-party IP internals would assert a safety claim we haven't vetted).

# Async LED outputs.
set_false_path -to [get_ports {sfp_led[*]}]
set_false_path -to [get_ports {led[*]}]
