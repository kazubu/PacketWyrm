#include "scalar.h"

#include <ctype.h>
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
    char *end = NULL;
    unsigned long long v = strtoull(buf, &end, 0);
    if (!end || *end != '\0') return false;
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
    int n = sscanf(s, "%x:%x:%x:%x:%x:%x", &o[0], &o[1], &o[2], &o[3], &o[4], &o[5]);
    if (n != 6) return false;
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
