# Phase 2 — SFP+ 10G MAC / PCS data path

Phase 2 brings up the two SFP+ ports as 10GBASE-R links and bridges
their 64-bit AXI-Stream user interface to the Phase 3 data plane
(`pw_axis_serializer` / `pw_axis_deserializer`).

## 10G MAC / PCS / GTY: Taxi submodule

The MAC, 10GBASE-R PCS and GTYE4 transceiver logic are **not**
re-implemented; they come from the Taxi library as a git submodule:

    rtl/phase2/vendor/taxi   ->  https://github.com/fpganinja/taxi
    pinned commit            ->  6e1e9c905f3b43e62c185c92fa688e1a2216696d

Taxi already ships an AS02MC04 10G example, so the transceiver settings
match this exact board. Initialise the submodule after cloning:

    git submodule update --init rtl/phase2/vendor/taxi

### What the build consumes

Taxi's own `.f` filelists resolve the dependency closure (the per-area
`lib/taxi` symlinks point back to the submodule root, so the relative
paths inside the `.f` files work in place). The AS02MC04 10G data path is:

- `src/eth/rtl/us/taxi_eth_mac_25g_us.f` — 10G/25G MAC + 10GBASE-R PCS +
  GTYE4 channel logic (runs at 10G on this board).
- `src/axis/rtl/taxi_axis_async_fifo.f` — AXIS async FIFO (clock-domain
  crossing into/out of the GT user clock).
- `src/sync/rtl/taxi_sync_reset.sv`, `taxi_sync_signal.sv`.

GTY IP + Vivado timing constraints used by the example build:

- `src/eth/rtl/us/taxi_eth_phy_10g_us_gty_156.tcl` — GTY IP, 156.25 MHz
  reference clock, 10.3125 Gbps line rate.
- `src/eth/syn/vivado/taxi_eth_mac_fifo.tcl`,
  `src/axis/syn/vivado/taxi_axis_async_fifo.tcl`,
  `src/sync/syn/vivado/taxi_sync_reset.tcl`, `taxi_sync_signal.tcl`.

The combined-PCS core (`taxi_eth_phy_10g` and below, no GT primitives)
parses clean under Verilator 5.032; the GT-wrapping modules are
validated at Vivado synthesis (they instantiate GTYE4 primitives).

Reference integration: `src/eth/example/AS02MC04/fpga/rtl/fpga{,_core}.sv`
shows the IBUFDS_GTE4 + BUFG_GT refclk path, the `taxi_axis_if`
interfaces, and the `taxi_eth_mac_25g_us` instantiation. PacketWyrm's
glue (next) adapts that `taxi_axis_if` user interface to the flat
64-bit AXIS the Phase 3 data plane already speaks.

## Licensing

Taxi is **CERN-OHL-S-2.0** (strongly reciprocal). Incorporating it makes
the PacketWyrm hardware design subject to CERN-OHL-S source-availability
and same-license terms on distribution — see the top-level `LICENSE`.
