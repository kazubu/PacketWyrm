/* PacketWyrm: ID system. */
#ifndef PACKETWYRM_IDS_H
#define PACKETWYRM_IDS_H

#include "packetwyrm/types.h"

struct pwfpga_port_ref {
    uint16_t card_id;
    uint8_t  local_port_id;
    uint16_t global_port_id;
};

struct pwfpga_logical_if {
    uint32_t logical_if_id;
    uint16_t global_port_id;
    uint16_t card_id;
    uint8_t  local_port_id;
    uint16_t vlan_id;
    char     if_name[PW_NAME_MAX];
};

/* Format the canonical TAP name into "tap-pw-p<gport>-v<vlan>".
 * Returns the number of bytes written (excluding NUL) on success, or
 * a negative pw_status on failure. */
int pw_tap_name(char *buf, size_t buflen, uint16_t global_port_id, uint16_t vlan_id);

#endif
