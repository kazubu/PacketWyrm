/* PacketWyrm SFP+ module management: read the module's I2C EEPROM (identifier /
 * vendor / part) and, for DDM-capable optical modules, the DOM diagnostics
 * (temperature, Vcc, TX bias, TX/RX optical power).
 *
 * The FPGA exposes a per-SFP open-drain 2-wire bus via the REG_SFP_I2C CSR
 * (one drive-low bit + one pad-in bit per line, per cage). This module
 * bit-bangs I2C over that register from software (the reads are on-demand and
 * low-rate, so a HW I2C controller isn't warranted). Standard SFP I2C map:
 *   0xA0 (7-bit addr 0x50): SFF-8024/8472 base ID page (identifier, vendor,
 *                           part, connector, DDM-capable flag at byte 92).
 *   0xA2 (7-bit addr 0x51): SFF-8472 DDM page (live diagnostics), present only
 *                           when the module reports DDM support. A passive DAC
 *                           answers 0xA0 (identifier) but has no 0xA2 optics.
 */
#ifndef PACKETWYRM_SFP_H
#define PACKETWYRM_SFP_H

#include <stdint.h>
#include <stdbool.h>
#include "packetwyrm/backend.h"

/* Decoded, human-facing view of one SFP module. Strings are NUL-terminated and
 * trailing-space-trimmed. dom_valid is false for modules without DDM (e.g. a
 * passive DAC) -- the temp/vcc/power fields are then meaningless. */
struct pw_sfp_info {
    bool     present;            /* the module ACKed its I2C address        */
    uint8_t  identifier;         /* SFF-8024 byte 0 (0x03 = SFP/SFP+)        */
    uint8_t  connector;          /* SFF-8024 connector code (byte 2)         */
    char     vendor[17];         /* A0 bytes 20..35                          */
    char     part[17];           /* A0 bytes 40..55                          */
    char     revision[5];        /* A0 bytes 56..59                          */
    char     serial[17];         /* A0 bytes 68..83                          */
    char     date_code[9];       /* A0 bytes 84..91 (YYMMDD[lot])            */
    uint8_t  br_nominal;         /* A0 byte 12, nominal bit rate / 100 Mbaud */
    bool     dom_supported;      /* A0 byte 92 bit 6                         */
    bool     dom_external_cal;   /* A0 byte 92 bit 4: externally calibrated  */
    bool     dom_valid;          /* dom_supported, internally calibrated, AND
                                  * the 0xA2 read succeeded. false for an
                                  * externally-calibrated module (the fixed
                                  * scaling below would misreport it -- the A2
                                  * 56..91 cal constants aren't applied yet). */
    /* DDM live values (valid only when dom_valid). SFF-8472 fixed scaling. */
    double   temp_c;             /* module temperature, deg C                */
    double   vcc_v;              /* supply voltage, V                        */
    double   tx_bias_ma;         /* laser bias current, mA                   */
    double   tx_power_mw;        /* TX optical power, mW                     */
    double   rx_power_mw;        /* RX optical power, mW                     */
};

/* Raw dump helpers: read `len` bytes from a page (i2c_addr = 0x50 for the base
 * ID page, 0x51 for DOM) starting at `offset`, on SFP port 0 or 1, bit-banged
 * over the REG_SFP_I2C CSR. Returns PW_OK, or PW_E_* on NAK / no backend. */
pw_status pw_sfp_read(const struct pw_card_backend *be, int port,
                      uint8_t i2c_addr, uint8_t offset,
                      uint8_t *buf, size_t len);

/* Read + decode the base ID page and (if DDM-capable) the DOM page for one
 * SFP port. Fills *out (all-zero + present=false if the module doesn't ACK). */
pw_status pw_sfp_probe(const struct pw_card_backend *be, int port,
                       struct pw_sfp_info *out);

#endif /* PACKETWYRM_SFP_H */
