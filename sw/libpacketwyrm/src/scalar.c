#include "scalar.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <arpa/inet.h>

bool pw_parse_bool(const char *s, bool *out) {
    if (!s) return false;
    if (!strcasecmp(s, "true") || !strcasecmp(s, "yes") || !strcmp(s, "1") || !strcasecmp(s, "on")) {
        *out = true; return true;
    }
    if (!strcasecmp(s, "false") || !strcasecmp(s, "no") || !strcmp(s, "0") || !strcasecmp(s, "off")) {
        *out = false; return true;
    }
    return false;
}

bool pw_parse_u64(const char *s, uint64_t *out) {
    if (!s || !*s) return false;
    /* Allow underscores as thousands separators ("1_000_000"). */
    char buf[64];
    size_t bi = 0;
    for (const char *p = s; *p; p++) {
        if (*p == '_') continue;
        if (bi >= sizeof(buf) - 1) return false;
        buf[bi++] = *p;
    }
    buf[bi] = '\0';
    if (bi == 0) return false;               /* empty / underscores only */
    /* Reject a signed literal: strtoull() would silently WRAP "-1" to a huge
     * unsigned (an unbounded rate/count), and "+1" is not a value we accept. */
    const char *q = buf;
    while (*q == ' ' || *q == '\t') q++;
    if (*q == '-' || *q == '+') return false;
    errno = 0;
    char *end = NULL;
    /* Base: an explicit 0x/0X prefix is hex; everything else is DECIMAL.
     * strtoull's base-0 auto-detection would parse a leading-zero literal
     * ("010") as OCTAL -- surprising in configs, where rates/ids/ports are
     * decimal unless deliberately written as hex. */
    int base = (q[0] == '0' && (q[1] == 'x' || q[1] == 'X')) ? 16 : 10;
    unsigned long long v = strtoull(buf, &end, base);
    if (end == buf || !end || *end != '\0') return false;  /* no digits / trailing junk */
    if (errno == ERANGE) return false;                     /* overflow */
    *out = (uint64_t)v;
    return true;
}

bool pw_parse_u32(const char *s, uint32_t *out) {
    uint64_t v;
    if (!pw_parse_u64(s, &v) || v > 0xFFFFFFFFull) return false;
    *out = (uint32_t)v;
    return true;
}

bool pw_parse_u16(const char *s, uint16_t *out) {
    uint64_t v;
    if (!pw_parse_u64(s, &v) || v > 0xFFFFu) return false;
    *out = (uint16_t)v;
    return true;
}

bool pw_parse_u8(const char *s, uint8_t *out) {
    uint64_t v;
    if (!pw_parse_u64(s, &v) || v > 0xFFu) return false;
    *out = (uint8_t)v;
    return true;
}

bool pw_parse_mac(const char *s, uint8_t out[6]) {
    if (!s) return false;
    unsigned o[6];
    int end = -1;
    /* %n captures the consumed length; requiring s[end]=='\0' rejects trailing
     * junk ("...:01xx") and extra octets that sscanf's field count alone lets
     * through. */
    int n = sscanf(s, "%x:%x:%x:%x:%x:%x%n",
                   &o[0], &o[1], &o[2], &o[3], &o[4], &o[5], &end);
    if (n != 6 || end < 0 || s[end] != '\0') return false;
    for (int i = 0; i < 6; i++) {
        if (o[i] > 0xFF) return false;
        out[i] = (uint8_t)o[i];
    }
    return true;
}

bool pw_parse_ipv4(const char *s, uint32_t *out) {
    if (!s) return false;
    struct in_addr a;
    if (inet_pton(AF_INET, s, &a) != 1) return false;
    *out = ntohl(a.s_addr);
    return true;
}

bool pw_parse_ipv6(const char *s, uint8_t out[16]) {
    if (!s) return false;
    struct in6_addr a;
    if (inet_pton(AF_INET6, s, &a) != 1) return false;
    for (int i = 0; i < 16; i++) out[i] = a.s6_addr[i];   /* network order */
    return true;
}
