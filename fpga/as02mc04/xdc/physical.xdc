# Bitstream and device-wide configuration for the AS02MC04.
# Values match the Taxi board support (FPGA Ninja, LLC, CERN-OHL-S-2.0;
# see top-level LICENSE) so the resulting bitstream can boot from the
# onboard SPI flash in the same SPIx4 mode the board ships with.

set_property CFGBVS GND                                      [current_design]
set_property CONFIG_VOLTAGE 1.8                              [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true                 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup               [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 72.9                [current_design]
set_property CONFIG_MODE SPIx4                               [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4                 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes              [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable        [current_design]
