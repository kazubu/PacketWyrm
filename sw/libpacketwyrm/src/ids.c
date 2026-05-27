#include "packetwyrm/ids.h"

#include <stdio.h>

int pw_tap_name(char *buf, size_t buflen, uint16_t global_port_id, uint16_t vlan_id) {
    if (!buf || buflen == 0) return PW_E_INVAL;
    int n = snprintf(buf, buflen, "tap-pw-p%u-v%u",
                     (unsigned)global_port_id, (unsigned)vlan_id);
    if (n < 0 || (size_t)n >= buflen) return PW_E_OUT_OF_RANGE;
    return n;
}
