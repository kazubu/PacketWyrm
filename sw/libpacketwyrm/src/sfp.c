/* PacketWyrm SFP+ module management -- software I2C bit-bang over REG_SFP_I2C,
 * plus SFF-8024/8472 decode. See packetwyrm/sfp.h. */

#include "packetwyrm/sfp.h"
#include "packetwyrm/csr.h"

#include <string.h>
#include <time.h>

/* REG_SFP_I2C line bits: port p -> SCL = p*2, SDA = p*2+1 (write = drive-low
 * enables [3:0]; read = pad-in at [19:16], same order). */
struct i2c_bus {
    const struct pw_card_backend *be;
    unsigned scl, sda;      /* drive-low bit indices for this port */
    uint8_t  drive;         /* shadow of the 4-bit drive-low register */
    int      err;           /* latched: a CSR read/write failed mid-transaction.
                             * The bit-bang helpers can't each return status, so
                             * the first failure is latched here and the public
                             * pw_sfp_read/write turn it into PW_E_BACKEND -- a
                             * HARD error distinct from an I2C NAK (PW_E_IO =
                             * empty cage), so pw_sfp_probe doesn't misreport a
                             * BAR/VFIO fault as "no module". Otherwise the fault
                             * reads as ACK=0/data=0 and looks like a successful
                             * transfer of zeros. */
};

/* ~5 us half-bit; a BAR access is already ~1 us, so the bus runs well under
 * 100 kHz, but the explicit delay adds margin + lets the EEPROM respond. */
static void i2c_delay(void) {
    struct timespec ts = { 0, 5000 };
    nanosleep(&ts, NULL);
}

/* Push the shadow drive register to the CSR. */
static void i2c_apply(struct i2c_bus *b) {
    if (b->be && b->be->ops && b->be->ops->write32) {
        if (b->be->ops->write32(b->be->ctx, PWFPGA_REG_SFP_I2C, b->drive) != PW_OK)
            b->err = 1;
    }
}

/* level=1 releases the line (open-drain -> pull-up = high); level=0 drives low. */
static void set_line(struct i2c_bus *b, unsigned bit, int level) {
    if (level) b->drive &= (uint8_t)~(1u << bit);
    else       b->drive |=  (uint8_t)(1u << bit);
    i2c_apply(b);
    i2c_delay();
}

/* Read a line's pad state (releases nothing; caller releases first). */
static int get_line(struct i2c_bus *b, unsigned bit) {
    uint32_t v = 0;
    if (b->be && b->be->ops && b->be->ops->read32) {
        if (b->be->ops->read32(b->be->ctx, PWFPGA_REG_SFP_I2C, &v) != PW_OK)
            b->err = 1;
    }
    return (int)((v >> (16 + bit)) & 1u);
}

/* Release SCL and wait for it to actually rise (clock-stretch tolerant, bounded). */
static void scl_release_wait(struct i2c_bus *b) {
    set_line(b, b->scl, 1);
    for (int i = 0; i < 100; i++) {
        if (get_line(b, b->scl)) break;   /* slave released the stretch */
        i2c_delay();
    }
}

static void i2c_start(struct i2c_bus *b) {
    set_line(b, b->sda, 1);
    scl_release_wait(b);
    set_line(b, b->sda, 0);   /* SDA falls while SCL high = START */
    set_line(b, b->scl, 0);
}

static void i2c_stop(struct i2c_bus *b) {
    set_line(b, b->sda, 0);
    scl_release_wait(b);
    set_line(b, b->sda, 1);   /* SDA rises while SCL high = STOP */
}

/* Write one byte MSB-first; return 0 if the slave ACKed (pulled SDA low). */
static int i2c_write_byte(struct i2c_bus *b, uint8_t v) {
    for (int i = 7; i >= 0; i--) {
        set_line(b, b->sda, (v >> i) & 1);
        scl_release_wait(b);
        set_line(b, b->scl, 0);
    }
    set_line(b, b->sda, 1);        /* release SDA for the ACK bit */
    scl_release_wait(b);
    int ack = get_line(b, b->sda); /* 0 = ACK */
    set_line(b, b->scl, 0);
    return ack;                    /* 0 = ACKed */
}

/* Read one byte MSB-first; send ACK (ack=1) or NAK (ack=0, for the last byte). */
static uint8_t i2c_read_byte(struct i2c_bus *b, int ack) {
    uint8_t v = 0;
    set_line(b, b->sda, 1);        /* release SDA so the slave drives it */
    for (int i = 7; i >= 0; i--) {
        scl_release_wait(b);
        v = (uint8_t)((v << 1) | (get_line(b, b->sda) & 1));
        set_line(b, b->scl, 0);
    }
    set_line(b, b->sda, ack ? 0 : 1);  /* ACK = drive low */
    scl_release_wait(b);
    set_line(b, b->scl, 0);
    set_line(b, b->sda, 1);
    return v;
}

pw_status pw_sfp_read(const struct pw_card_backend *be, int port,
                      uint8_t i2c_addr, uint8_t offset,
                      uint8_t *buf, size_t len) {
    if (!be || !be->ops || !be->ops->write32 || !be->ops->read32) return PW_E_NOT_IMPLEMENTED;
    if (port < 0 || port > 1 || !buf) return PW_E_INVAL;
    if ((size_t)offset + len > 256) return PW_E_INVAL;   /* single 256-B page (matches write) */

    struct i2c_bus b = { .be = be, .scl = (unsigned)(port * 2),
                         .sda = (unsigned)(port * 2 + 1), .drive = 0, .err = 0 };
    /* idle: both lines released */
    set_line(&b, b.scl, 1);
    set_line(&b, b.sda, 1);

    /* Random read: START, [addr|W], offset, repeated START, [addr|R], data..., STOP.
     * On a NAK-return, a latched CSR fault (b.err) OUTRANKS the apparent NAK ->
     * PW_E_BACKEND (hard), so pw_sfp_probe can't mistake a backend fault whose
     * ACK bit happened to read high for an empty cage (PW_E_IO). */
    i2c_start(&b);
    if (i2c_write_byte(&b, (uint8_t)(i2c_addr << 1))) { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
    if (i2c_write_byte(&b, offset))                    { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
    i2c_start(&b);
    if (i2c_write_byte(&b, (uint8_t)((i2c_addr << 1) | 1))) { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
    for (size_t i = 0; i < len; i++)
        buf[i] = i2c_read_byte(&b, i + 1 < len);   /* ACK all but the last */
    i2c_stop(&b);
    /* Distinguish a CSR/backend fault from an I2C NAK: a NAK (empty cage) returns
     * PW_E_IO above and pw_sfp_probe reads that as "no module". A CSR access
     * failure must NOT be mistaken for an empty cage, so report it as
     * PW_E_BACKEND (a hard error probe/callers propagate). */
    if (b.err) return PW_E_BACKEND;
    return PW_OK;
}

pw_status pw_sfp_write(const struct pw_card_backend *be, int port,
                       uint8_t i2c_addr, uint8_t offset,
                       const uint8_t *buf, size_t len) {
    if (!be || !be->ops || !be->ops->write32 || !be->ops->read32) return PW_E_NOT_IMPLEMENTED;
    if (port < 0 || port > 1 || !buf) return PW_E_INVAL;
    if ((size_t)offset + len > 256) return PW_E_INVAL;   /* single 256-B page */

    struct i2c_bus b = { .be = be, .scl = (unsigned)(port * 2),
                         .sda = (unsigned)(port * 2 + 1), .drive = 0, .err = 0 };
    set_line(&b, b.scl, 1);
    set_line(&b, b.sda, 1);

    /* Single-byte writes: START, [addr|W], offset, data, STOP -- then ACK-poll
     * the device address until it ACKs again (internal write cycle complete).
     * Byte-at-a-time avoids page-size assumptions across module vendors. */
    for (size_t i = 0; i < len; i++) {
        /* b.err (a latched CSR fault) OUTRANKS an apparent NAK at every early
         * return -> PW_E_BACKEND, so a backend fault is never misread as an
         * empty cage (PW_E_IO). */
        i2c_start(&b);
        if (i2c_write_byte(&b, (uint8_t)(i2c_addr << 1)))     { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
        if (i2c_write_byte(&b, (uint8_t)(offset + i)))         { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
        if (i2c_write_byte(&b, buf[i]))                        { i2c_stop(&b); return b.err ? PW_E_BACKEND : PW_E_IO; }
        i2c_stop(&b);

        /* ACK-poll the write cycle (each poll is ~100us of bus time; the SFP
         * EEPROM write completes within a few ms, so ~50 polls is ample). */
        int done = 0;
        for (int t = 0; t < 50; t++) {
            i2c_start(&b);
            int ack = i2c_write_byte(&b, (uint8_t)(i2c_addr << 1));
            i2c_stop(&b);
            if (b.err) break;              /* CSR fault: stop polling, report below */
            if (ack == 0) { done = 1; break; }
        }
        if (b.err) return PW_E_BACKEND;   /* CSR/backend fault OUTRANKS !done (NAK) */
        if (!done) return PW_E_IO;
    }
    return PW_OK;
}

/* SFF-8472 write password entry: 4 bytes at A2 (0x51) offset 0x7B. Write-only
 * (reads back as 0xFF), so pw_sfp_write's read-back verify is not used here. */
#define SFP_PW_ADDR    0x51
#define SFP_PW_OFFSET  0x7B
/* Cosmetic base-ID test byte for the unlock probe: the 4th vendor-revision pad
 * (A0 0x3B), normally a space -- flipped + restored, never left altered. */
#define SFP_PW_TEST_ADDR 0x50
#define SFP_PW_TEST_OFF  0x3B

/* Write the 4-byte password to the SFF-8472 password-entry area (no verify --
 * the area is write-only). Returns PW_OK if the bytes ACKed. */
pw_status pw_sfp_unlock(const struct pw_card_backend *be, int port, uint32_t password) {
    uint8_t pwb[4] = { (uint8_t)(password >> 24), (uint8_t)(password >> 16),
                       (uint8_t)(password >> 8),  (uint8_t)password };
    return pw_sfp_write(be, port, SFP_PW_ADDR, SFP_PW_OFFSET, pwb, sizeof(pwb));
}

pw_status pw_sfp_try_write_password(const struct pw_card_backend *be, int port,
                                    uint32_t password, bool *unlocked) {
    if (!unlocked) return PW_E_INVAL;
    *unlocked = false;

    pw_status s = pw_sfp_unlock(be, port, password);
    if (s != PW_OK) return s;   /* backend fault / module absent (not "locked") */

    uint8_t orig, test, rb;
    if (pw_sfp_read(be, port, SFP_PW_TEST_ADDR, SFP_PW_TEST_OFF, &orig, 1) != PW_OK)
        return PW_E_IO;
    test = (uint8_t)(orig ^ 0xFF);
    /* A locked write ACKs but commits nothing (NAK on some modules); either way
     * the read-back stays == orig and we treat it as "still locked". */
    if (pw_sfp_write(be, port, SFP_PW_TEST_ADDR, SFP_PW_TEST_OFF, &test, 1) != PW_OK)
        return PW_OK;
    if (pw_sfp_read(be, port, SFP_PW_TEST_ADDR, SFP_PW_TEST_OFF, &rb, 1) != PW_OK)
        return PW_E_IO;
    if (rb == test) {
        *unlocked = true;
        (void)pw_sfp_write(be, port, SFP_PW_TEST_ADDR, SFP_PW_TEST_OFF, &orig, 1); /* restore */
    }
    return PW_OK;
}

/* Copy an EEPROM ASCII field, trimming trailing spaces, into a NUL-terminated
 * buffer of size dst_sz (>= n+1). */
static void copy_ascii(char *dst, size_t dst_sz, const uint8_t *src, size_t n) {
    if (n >= dst_sz) n = dst_sz - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
    for (size_t i = n; i > 0 && (dst[i - 1] == ' ' || dst[i - 1] == '\0'); i--)
        dst[i - 1] = '\0';
}

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

pw_status pw_sfp_probe(const struct pw_card_backend *be, int port,
                       struct pw_sfp_info *out) {
    if (!out) return PW_E_INVAL;
    memset(out, 0, sizeof(*out));

    uint8_t a0[96];
    pw_status s = pw_sfp_read(be, port, 0x50, 0, a0, sizeof(a0));
    /* An I2C NAK (PW_E_IO) means no module in the cage -- that's the normal
     * "empty" state, reported as present=false + PW_OK (per the API contract).
     * Only a backend/argument fault (no write32/read32, bad port) is an error. */
    if (s == PW_E_IO)  return PW_OK;   /* empty cage: present stays false */
    if (s != PW_OK)    return s;       /* backend not ready / bad args     */

    out->present    = true;
    out->identifier = a0[0];
    out->connector  = a0[2];
    out->br_nominal = a0[12];
    copy_ascii(out->vendor,    sizeof(out->vendor),    &a0[20], 16);
    copy_ascii(out->part,      sizeof(out->part),      &a0[40], 16);
    copy_ascii(out->revision,  sizeof(out->revision),  &a0[56], 4);
    copy_ascii(out->serial,    sizeof(out->serial),    &a0[68], 16);
    copy_ascii(out->date_code, sizeof(out->date_code), &a0[84], 8);
    out->dom_supported    = (a0[92] & 0x40) != 0;   /* SFF-8472 byte 92 bit 6 */
    out->dom_external_cal = (a0[92] & 0x10) != 0;    /* byte 92 bit 4          */

    /* DOM live values (A2 96..105) use the fixed SFF-8472 scaling below ONLY for
     * INTERNALLY-calibrated modules. An externally-calibrated module needs the
     * A2 56..91 slope/offset constants applied first -- not implemented -- so we
     * leave dom_valid=false rather than misreport temp/Vcc/power. */
    if (out->dom_supported && !out->dom_external_cal) {
        uint8_t a2[10];
        if (pw_sfp_read(be, port, 0x51, 96, a2, sizeof(a2)) == PW_OK) {
            out->dom_valid   = true;
            out->temp_c      = (double)(int16_t)be16(&a2[0]) / 256.0;
            out->vcc_v       = (double)be16(&a2[2]) * 0.0001;   /* 100 uV units */
            out->tx_bias_ma  = (double)be16(&a2[4]) * 0.002;    /* 2 uA units   */
            out->tx_power_mw = (double)be16(&a2[6]) * 0.0001;   /* 0.1 uW units */
            out->rx_power_mw = (double)be16(&a2[8]) * 0.0001;   /* 0.1 uW units */
        }
    }
    return PW_OK;
}
