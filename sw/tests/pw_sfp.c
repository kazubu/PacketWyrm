/* PacketWyrm Phase 3: read + print SFP+ module identifier and DOM diagnostics.
 *
 * Bit-bangs the module I2C EEPROM over the FPGA's REG_SFP_I2C CSR (per-cage
 * open-drain SCL/SDA) and decodes SFF-8024/8472. DOM (temperature / Vcc / TX
 * bias / TX+RX optical power) prints only for DDM-capable optical modules; a
 * passive DAC shows the identifier/vendor/part but reports no DOM.
 *
 *   sudo pw_sfp <bdf> [port]        # port 0 (default) or 1
 *   sudo pw_sfp <bdf> both          # both cages
 *   sudo pw_sfp <bdf> <port> raw    # hex dump of the 0xA0 (+0xA2) pages
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/sfp.h"

static const char *ident_str(uint8_t id) {
    switch (id) {
        case 0x00: return "unknown/unspecified";
        case 0x03: return "SFP/SFP+/SFP28";
        case 0x0B: return "DWDM-SFP";
        case 0x0D: return "QSFP+";
        case 0x11: return "QSFP28";
        default:   return "other";
    }
}

static const char *conn_str(uint8_t c) {
    switch (c) {
        case 0x01: return "SC";
        case 0x07: return "LC";
        case 0x0B: return "optical pigtail";
        case 0x21: return "Copper pigtail (DAC)";
        case 0x22: return "RJ45";
        default:   return "other";
    }
}

static void print_info(int port, const struct pw_sfp_info *s) {
    printf("=== SFP port %d ===\n", port);
    if (!s->present) { printf("  (no module / no I2C ACK)\n"); return; }
    printf("  identifier : 0x%02x (%s)\n", s->identifier, ident_str(s->identifier));
    printf("  connector  : 0x%02x (%s)\n", s->connector, conn_str(s->connector));
    printf("  vendor     : %s\n", s->vendor);
    printf("  part       : %s\n", s->part);
    printf("  revision   : %s\n", s->revision);
    printf("  serial     : %s\n", s->serial);
    printf("  date code  : %s\n", s->date_code);
    printf("  nominal BR : %u00 Mbaud (~%.1f Gb/s)\n",
           s->br_nominal, s->br_nominal / 10.0);
    if (!s->dom_supported) {
        printf("  DOM        : not supported (no DDM -- e.g. passive DAC)\n");
        return;
    }
    if (s->dom_external_cal) {
        printf("  DOM        : externally calibrated -- not decoded "
               "(needs the A2 56..91 cal constants; not implemented)\n");
        return;
    }
    if (!s->dom_valid) {
        printf("  DOM        : supported but 0xA2 read failed\n");
        return;
    }
    printf("  DOM (live) :\n");
    printf("    temperature : %+.2f C\n", s->temp_c);
    printf("    Vcc         : %.3f V\n", s->vcc_v);
    printf("    TX bias     : %.3f mA\n", s->tx_bias_ma);
    printf("    TX power    : %.4f mW (%+.2f dBm)\n", s->tx_power_mw,
           s->tx_power_mw > 0 ? 10.0 * log10(s->tx_power_mw) : -40.0);
    printf("    RX power    : %.4f mW (%+.2f dBm)\n", s->rx_power_mw,
           s->rx_power_mw > 0 ? 10.0 * log10(s->rx_power_mw) : -40.0);
}

static void hexdump(const char *label, const uint8_t *b, size_t n) {
    printf("--- %s ---\n", label);
    for (size_t i = 0; i < n; i += 16) {
        printf("  %02zx:", i);
        for (size_t j = 0; j < 16 && i + j < n; j++) printf(" %02x", b[i + j]);
        printf("\n");
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <bdf> [port|both] [raw]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    int  do_both = (argc > 2 && !strcmp(argv[2], "both"));
    int  port    = (argc > 2 && !do_both) ? atoi(argv[2]) : 0;
    int  raw     = (argc > 3 && !strcmp(argv[3], "raw"));

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "open %s failed\n", bdf);
        return 1;
    }

    int p0 = do_both ? 0 : port;
    int p1 = do_both ? 1 : port;
    for (int p = p0; p <= p1; p++) {
        if (raw) {
            uint8_t a0[128], a2[128];
            if (pw_sfp_read(&be, p, 0x50, 0, a0, sizeof(a0)) == PW_OK)
                hexdump("A0 (0x50) base ID page", a0, sizeof(a0));
            else printf("port %d: no I2C ACK on 0x50\n", p);
            if (pw_sfp_read(&be, p, 0x51, 0, a2, sizeof(a2)) == PW_OK)
                hexdump("A2 (0x51) DOM page", a2, sizeof(a2));
        } else {
            struct pw_sfp_info s;
            if (pw_sfp_probe(&be, p, &s) != PW_OK)
                printf("=== SFP port %d ===\n  (I2C error)\n", p);
            else
                print_info(p, &s);
        }
    }

    pw_card_backend_close(&be);
    return 0;
}
