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
#include <signal.h>
#include <time.h>

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

/* Parse a contiguous hex string ("0a1bff") into bytes. Returns count or -1. */
static int parse_hex(const char *s, uint8_t *out, size_t max) {
    size_t n = strlen(s);
    if (n == 0 || (n & 1)) return -1;
    if (n / 2 > max) return -1;
    for (size_t i = 0; i < n; i += 2) {
        char c[3] = { s[i], s[i + 1], 0 }; char *end;
        long v = strtol(c, &end, 16);
        if (*end || v < 0 || v > 255) return -1;
        out[i / 2] = (uint8_t)v;
    }
    return (int)(n / 2);
}

static int do_write(struct pw_card_backend *be, int port, int argc, char **argv) {
    /* argv: [write] <addr 0x50|0x51> <offset> <hexbytes> [commit] */
    if (argc < 7) {
        fprintf(stderr, "usage: pw_sfp <bdf> <port> write <0x50|0x51> <offset> <hexbytes> [commit]\n"
                        "  hexbytes = contiguous hex pairs, e.g. 0a1bff. Without 'commit' it is a\n"
                        "  DRY RUN (shows current vs new). 'commit' writes + verifies.\n"
                        "  WARNING: writing 0x50 (base ID) can re-code / brick a module.\n");
        return 2;
    }
    uint8_t addr   = (uint8_t)strtol(argv[4], NULL, 0);
    uint8_t offset = (uint8_t)strtol(argv[5], NULL, 0);
    uint8_t data[128];
    int n = parse_hex(argv[6], data, sizeof(data));
    if (n <= 0) { fprintf(stderr, "bad hexbytes '%s' (need even-length hex)\n", argv[6]); return 2; }
    int commit = (argc > 7 && !strcmp(argv[7], "commit"));
    if (addr != 0x50 && addr != 0x51) {
        fprintf(stderr, "addr must be 0x50 (base ID) or 0x51 (DOM page)\n"); return 2;
    }

    uint8_t cur[128];
    if (pw_sfp_read(be, port, addr, offset, cur, (size_t)n) != PW_OK) {
        fprintf(stderr, "port %d: no I2C ACK on 0x%02x (module absent / write-protected?)\n", port, addr);
        return 1;
    }
    printf("port %d  i2c 0x%02x  offset 0x%02x  %d byte(s)\n", port, addr, offset, n);
    printf("  current:");  for (int i = 0; i < n; i++) printf(" %02x", cur[i]);  printf("\n");
    printf("  new    :");  for (int i = 0; i < n; i++) printf(" %02x", data[i]); printf("\n");
    if (!commit) {
        printf("  DRY RUN -- add 'commit' to write. (writing 0x50 can re-code the module)\n");
        return 0;
    }
    printf("  writing...\n");
    if (pw_sfp_write(be, port, addr, offset, data, (size_t)n) != PW_OK) {
        fprintf(stderr, "  WRITE FAILED (NAK / timeout -- write-protected region?)\n");
        return 1;
    }
    uint8_t rb[128];
    if (pw_sfp_read(be, port, addr, offset, rb, (size_t)n) != PW_OK) {
        fprintf(stderr, "  wrote, but read-back failed\n"); return 1;
    }
    if (memcmp(rb, data, (size_t)n) != 0) {
        printf("  read-back MISMATCH:"); for (int i = 0; i < n; i++) printf(" %02x", rb[i]); printf("\n");
        printf("  (region may be read-only / shadowed)\n");
        return 1;
    }
    printf("  OK -- verified\n");
    return 0;
}

static volatile sig_atomic_t g_stop;
static void on_int(int s) { (void)s; g_stop = 1; }

static double now_s(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

/* Format a duration (seconds) as "Dd Hh Mm Ss", dropping leading zero units
 * (e.g. "5s", "3m 20s", "2d 4h 11m 5s"). Writes into buf. */
static void fmt_dur(double secs, char *buf, size_t n) {
    if (secs < 0) secs = 0;
    unsigned long long s = (unsigned long long)(secs + 0.5);
    unsigned d = (unsigned)(s / 86400); s %= 86400;
    unsigned h = (unsigned)(s / 3600);  s %= 3600;
    unsigned m = (unsigned)(s / 60);    unsigned sec = (unsigned)(s % 60);
    if (d)      snprintf(buf, n, "%ud %uh %um %us", d, h, m, sec);
    else if (h) snprintf(buf, n, "%uh %um %us", h, m, sec);
    else if (m) snprintf(buf, n, "%um %us", m, sec);
    else        snprintf(buf, n, "%us", sec);
}

/* Enter a write password: pw_sfp <bdf> <port> unlock <password_hex> */
static int do_unlock(struct pw_card_backend *be, int port, int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: pw_sfp <bdf> <port> unlock <password_hex>\n"
                        "  writes the 4-byte SFF-8472 password to A2 0x7B (write-only area;\n"
                        "  not verifiable by read-back). Unlock persists until power-cycle.\n");
        return 2;
    }
    uint32_t pw = (uint32_t)strtoul(argv[4], NULL, 0);
    bool ok;
    pw_status s = pw_sfp_try_write_password(be, port, pw, &ok);
    if (s != PW_OK) { fprintf(stderr, "port %d: I2C error / module absent\n", port); return 1; }
    printf("port %d: password 0x%08x entered -- base-ID writes %s\n",
           port, pw, ok ? "UNLOCKED (verified)" : "still LOCKED (wrong password?)");
    return ok ? 0 : 1;
}

/* Search for a write password: pw_sfp <bdf> <port> findpw [start] [end] [stride] */
static int do_findpw(struct pw_card_backend *be, int port, int argc, char **argv) {
    uint32_t start  = (argc > 4) ? (uint32_t)strtoul(argv[4], NULL, 0) : 0u;
    uint32_t end    = (argc > 5) ? (uint32_t)strtoul(argv[5], NULL, 0) : 0xFFFFFFFFu;
    uint32_t stride = (argc > 6) ? (uint32_t)strtoul(argv[6], NULL, 0) : 1u;
    if (stride == 0) stride = 1;

    /* Confirm a module is present (a probe read must ACK). */
    uint8_t tmp;
    if (pw_sfp_read(be, port, 0x50, 0, &tmp, 1) != PW_OK) {
        fprintf(stderr, "port %d: no module / no I2C ACK -- nothing to search\n", port);
        return 1;
    }

    uint64_t total = ((uint64_t)end - start) / stride + 1;
    printf("port %d: searching write password 0x%08x..0x%08x stride %u (%llu candidates)\n",
           port, start, end, stride, (unsigned long long)total);
    printf("  Ctrl-C to stop (prints a resume point). NOTE: bit-bang I2C is ~1-2 ms/candidate,\n"
           "  so a full 2^32 sweep is impractical (~weeks); bound the range or resume.\n");

    signal(SIGINT, on_int);
    double t0 = now_s(), tlast = t0;
    uint64_t done = 0;
    uint32_t last = start;
    for (uint64_t pv = start; pv <= end; pv += stride) {
        last = (uint32_t)pv;
        bool ok;
        pw_status s = pw_sfp_try_write_password(be, port, (uint32_t)pv, &ok);
        if (s != PW_OK) { fprintf(stderr, "\ni2c error at 0x%08x -- aborting\n", (unsigned)pv); return 1; }
        done++;
        if (ok) {
            printf("\nFOUND: password 0x%08x unlocks base-ID writes (after %llu tries)\n",
                   (unsigned)pv, (unsigned long long)done);
            return 0;
        }
        if (g_stop) {
            printf("\nstopped at 0x%08x -- resume with: findpw 0x%08x 0x%08x %u\n",
                   (unsigned)pv, (unsigned)(pv + stride), end, stride);
            return 2;
        }
        double tn = now_s();
        if (tn - tlast >= 2.0) {
            double rate = done / (tn - t0);
            double eta  = rate > 0 ? (double)(total - done) / rate : 0;
            char etabuf[48]; fmt_dur(eta, etabuf, sizeof(etabuf));
            printf("\r  at 0x%08x  %.0f/s  ETA %s  (%.2f%%)          ",
                   (unsigned)pv, rate, etabuf, 100.0 * done / total);
            fflush(stdout);
            tlast = tn;
        }
        if ((uint64_t)pv + stride > end) break;   /* avoid uint32 wrap past end */
    }
    printf("\nno password in the range unlocked writes (last tried 0x%08x)\n", (unsigned)last);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <bdf> [port|both] [raw]\n"
                        "       %s <bdf> <port> write <0x50|0x51> <offset> <hexbytes> [commit]\n"
                        "       %s <bdf> <port> unlock <password_hex>\n"
                        "       %s <bdf> <port> findpw [start_hex] [end_hex] [stride]\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    const char *sub = (argc > 3) ? argv[3] : "";
    int  is_write  = !strcmp(sub, "write");
    int  is_unlock = !strcmp(sub, "unlock");
    int  is_findpw = !strcmp(sub, "findpw");
    int  do_both = (argc > 2 && !strcmp(argv[2], "both"));
    int  port    = (argc > 2 && !do_both) ? atoi(argv[2]) : 0;
    int  raw     = !strcmp(sub, "raw");

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) {
        fprintf(stderr, "open %s failed\n", bdf);
        return 1;
    }

    int rc = 0;
    if (is_write || is_unlock || is_findpw) {
        rc = is_write  ? do_write(&be, port, argc, argv)
           : is_unlock ? do_unlock(&be, port, argc, argv)
           :             do_findpw(&be, port, argc, argv);
        pw_card_backend_close(&be);
        return rc;
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
