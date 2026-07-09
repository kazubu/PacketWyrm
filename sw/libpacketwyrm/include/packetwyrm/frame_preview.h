/* Build the on-wire frame a flow's generator emits, mirroring the RTL layout
 * in rtl/phase3/pw_flow_gen_multi.sv: Ethernet [+VLAN] / [outer IP + IPIP|GRE|
 * EtherIP tunnel + inner Ethernet] / inner IPv4|IPv6 / UDP|TCP / 32-byte
 * PacketWyrm test header, zero-padded to frame_len. Used by the CLI
 * `flow preview` and the daemon `flow.preview` RPC so there is ONE frame
 * builder shared by CLI, GUI and any future consumer. */
#ifndef PACKETWYRM_FRAME_PREVIEW_H
#define PACKETWYRM_FRAME_PREVIEW_H

#include <stddef.h>
#include <stdint.h>
#include "packetwyrm/config.h"

/* Build the frame for packet `seq` of flow `f` into `buf` (capacity `cap`).
 * The departure timestamp is left 0 (hardware stamps it at egress); IPv4 header
 * and L4 checksums are computed over that ts=0 frame so the result is a valid,
 * decodable packet. Returns the total L2 length (pre-FCS), or -1 on an
 * unsupported template / length / overflow. On success `*built` receives the
 * count of header + test-header bytes (the remainder up to the return value is
 * zero payload). */
int pw_flow_build_preview(const struct pw_flow *f, uint32_t seq,
                          uint8_t *buf, size_t cap, size_t *built);

#endif
