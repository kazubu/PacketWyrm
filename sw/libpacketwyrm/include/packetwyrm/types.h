/* PacketWyrm: scalar types and error codes. */
#ifndef PACKETWYRM_TYPES_H
#define PACKETWYRM_TYPES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PW_TEST_HDR_MAGIC 0xA5027E57u
#define PW_NAME_MAX       32
#define PW_PCI_BDF_MAX    16
#define PW_MAX_CARDS      16
#define PW_PORTS_PER_CARD 2
#define PW_PROTO_LIST     "arp,ipv6_nd,lldp,icmp,bgp,ospf,is_is"

typedef enum {
    PW_OK = 0,

    /* config / validation */
    PW_E_INVAL = -1,
    PW_E_PARSE = -2,
    PW_E_DUP_CARD_ID = -3,
    PW_E_DUP_GLOBAL_PORT = -4,
    PW_E_DUP_LOGICAL_IF = -5,
    PW_E_DUP_FLOW_ID = -6,
    PW_E_UNKNOWN_CARD = -7,
    PW_E_UNKNOWN_GLOBAL_PORT = -8,
    PW_E_UNKNOWN_LOGICAL_IF = -9,
    PW_E_CROSS_CARD_LATENCY = -10,
    PW_E_MISSING_FIELD = -11,
    PW_E_OUT_OF_RANGE = -12,

    /* runtime */
    PW_E_NO_CARD = -20,
    PW_E_NO_RESOURCES = -21,
    PW_E_BACKEND = -22,
    PW_E_IO = -23,
    PW_E_OVERFLOW = -24,
    PW_E_DEGRADED = -25,
    PW_E_NOT_IMPLEMENTED = -99
} pw_status;

const char *pw_strerror(pw_status s);

#endif
