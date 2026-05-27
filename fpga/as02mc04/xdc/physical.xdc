# Bitstream / device-wide configuration for AS02MC04.

# Configuration bank voltage (TBD from schematic).
# set_property CFGBVS GND        [current_design]
# set_property CONFIG_VOLTAGE 1.8 [current_design]

# Bitstream encryption / readback disabled (defaults).
# set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# SPI flash configuration (board flash part TBD). Without these set
# correctly the card will fall back to JTAG-only programming, which
# is acceptable for Phase 1 bring-up but breaks unattended boot.
# set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4    [current_design]
# set_property CONFIG_MODE SPIx4                   [current_design]
# set_property BITSTREAM.CONFIG.CONFIGRATE 12.5    [current_design]
# set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES  [current_design]
