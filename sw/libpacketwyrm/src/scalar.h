/* Scalar helpers shared between config parser and other internal users. */
#ifndef PACKETWYRM_SCALAR_H
#define PACKETWYRM_SCALAR_H

#include <stdbool.h>
#include <stdint.h>

#include "packetwyrm/types.h"

bool pw_parse_bool(const char *s, bool *out);
bool pw_parse_u64(const char *s, uint64_t *out);
bool pw_parse_u32(const char *s, uint32_t *out);
bool pw_parse_u16(const char *s, uint16_t *out);
bool pw_parse_u8(const char *s, uint8_t *out);

/* "aa:bb:cc:dd:ee:ff" -> 6 bytes. */
bool pw_parse_mac(const char *s, uint8_t out[6]);

/* "a.b.c.d" -> u32 in network byte order's *host* representation, i.e.
 * the high byte is the first octet. */
bool pw_parse_ipv4(const char *s, uint32_t *out);

/* "2001:db8::1" -> 16 bytes in network order. */
bool pw_parse_ipv6(const char *s, uint8_t out[16]);

#endif
