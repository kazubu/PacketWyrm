/* PacketWyrm: in-memory configuration model. */
#ifndef PACKETWYRM_CONFIG_H
#define PACKETWYRM_CONFIG_H

#include "packetwyrm/ids.h"
#include "packetwyrm/types.h"

struct pw_system {
    char     name[PW_NAME_MAX];
    char     mode[PW_NAME_MAX];          /* "multi-card" */
    char     default_speed[8];           /* "10g" */
    uint32_t stats_poll_interval_ms;     /* default 100 */
    char     control_socket[128];
};

struct pw_card_port {
    uint8_t  local_port;
    uint16_t global_port;
    char     name[PW_NAME_MAX];          /* e.g. "p0" */
};

struct pw_card {
    uint16_t id;
    char     name[PW_NAME_MAX];          /* e.g. "card0" */
    char     pci[PW_PCI_BDF_MAX];        /* "0000:03:00.0" */
    struct pw_card_port ports[PW_PORTS_PER_CARD];
    size_t   n_ports;
};

struct pw_punt_flags {
    bool arp;
    bool ipv6_nd;
    bool lldp;
    bool icmp;
    bool bgp;
    bool ospf;
    bool is_is;
};

struct pw_logical_if {
    uint32_t id;                         /* logical_if_id */
    char     name[PW_NAME_MAX];
    uint16_t global_port;
    uint16_t vlan;                       /* 0 = untagged */
    uint8_t  mac[6];
    uint16_t mtu;
    char     netns[PW_NAME_MAX];
    struct pw_punt_flags punt;
};

struct pw_flow_l2 {
    uint8_t  src_mac[6];
    uint8_t  dst_mac[6];
    bool     vlan_set;
    uint16_t vlan;
    uint8_t  pcp;
};

struct pw_flow_ipv4 {
    bool     present;
    uint32_t src;
    uint32_t dst;
    uint8_t  ttl;
    uint8_t  dscp;
};

struct pw_flow_ipv6 {
    bool     present;
    uint8_t  src[16];     /* network order */
    uint8_t  dst[16];
    uint8_t  hop_limit;   /* optional, default 64 */
    uint8_t  dscp;        /* optional, 0..63; emitted as the IPv6 traffic class */
};

/* Encapsulation: wrap the flow's inner IP/UDP/test frame in an outer L3 +
 * tunnel header. Matches enum pwfpga_encap_type. IPIP = bare outer-IP (proto
 * 4 v4-in / 41 v6-in); GRE = outer-IP proto 47 + 4-byte GRE; EtherIP = outer-IP
 * proto 97 + 2-byte EtherIP + a full inner Ethernet frame. Outer family is
 * independent of the inner (v4/v6 in v4/v6). */
enum pw_encap_kind { PW_ENCAP_NONE = 0, PW_ENCAP_IPIP = 1,
                     PW_ENCAP_GRE = 2, PW_ENCAP_ETHERIP = 3 };
struct pw_flow_encap {
    bool                present;
    uint8_t             type;        /* enum pw_encap_kind */
    struct pw_flow_ipv4 outer_ipv4;  /* outer L3 -- exactly one of v4/v6 */
    struct pw_flow_ipv6 outer_ipv6;
    /* EtherIP only: MAC of the encapsulated inner Ethernet frame. When unset
     * the inner Ethernet reuses the flow's l2 MAC. */
    bool                inner_mac_set;
    uint8_t             inner_src_mac[6];
    uint8_t             inner_dst_mac[6];
};

/* How the RX side receives a measured tunneled flow:
 *  - inner: the DUT decapsulates; RX gets the bare inner frame (no decap parse)
 *  - tunneled: RX gets the frame with the outer+encap still on it (DUT relayed
 *    it as-is, or added its own encap); the parser must decap to the inner
 *    test header to classify/measure. */
enum pw_rx_expect { PW_RX_INNER = 0, PW_RX_TUNNELED = 1 };

struct pw_flow_udp {
    uint16_t src_port;
    uint16_t dst_port;
};

struct pw_flow_traffic {
    /* Exactly one of frame_len_fixed or the (min,max,step) triple must be
     * set; the validator enforces this. */
    bool     frame_len_fixed_set;
    uint16_t frame_len_fixed;
    uint16_t frame_len_min;
    uint16_t frame_len_max;
    uint16_t frame_len_step;

    /* Exactly one of rate_bps / rate_pps must be set. */
    uint64_t rate_bps;
    uint64_t rate_pps;
    uint32_t burst_size;
    uint32_t burst_gap_ticks;

    uint8_t  payload_mode;               /* enum pwfpga_payload_mode */
    uint32_t payload_seed;
    bool     insert_sequence;
    bool     insert_timestamp;
};

struct pw_flow_meas {
    bool loss;
    bool latency;
    bool jitter;
};

/* Per-field modifier: vary the masked bits of a header field per emitted
 * frame (commercial-gen "field modifier"). mode 0=static, 1=increment,
 * 2=random (matches enum pwfpga_field_mod). mask=0 / mode static = off. */
struct pw_field_mod {
    uint8_t  mode;
    uint64_t mask;     /* up to 48 bits (MAC); IPv4 uses low 32, ports low 16 */
};

struct pw_flow_modifiers {
    struct pw_field_mod src_ipv4;   /* or src_ipv6 (low 32 bits) */
    struct pw_field_mod dst_ipv4;   /* or dst_ipv6 (low 32 bits) */
    struct pw_field_mod udp_src;
    struct pw_field_mod udp_dst;
    struct pw_field_mod src_mac;    /* 48-bit mask */
    struct pw_field_mod dst_mac;    /* 48-bit mask */
    struct pw_field_mod vlan;       /* low 12 bits */
};

struct pw_flow {
    uint32_t id;                         /* global_flow_id */
    char     name[PW_NAME_MAX];
    uint16_t tx_global_port;
    uint16_t rx_global_port;
    uint32_t logical_if_id;              /* 0 means unset */

    struct pw_flow_l2      l2;
    struct pw_flow_ipv4    ipv4;
    struct pw_flow_ipv6    ipv6;        /* set exactly one of ipv4 / ipv6 */
    struct pw_flow_udp     udp;
    struct pw_flow_traffic traffic;
    struct pw_flow_meas    meas;
    struct pw_flow_modifiers mod;

    /* Background (load) traffic: generate TX only, no RX classifier rule and
     * no loss/latency measurement. Lets a config run more generator flows than
     * the classifier capacity (e.g. 32 gen slots, <=16 measured) -- the
     * unmeasured background flows do not consume a classifier entry. */
    bool background;

    /* Encapsulation (optional): wrap the inner frame in an outer L3 + tunnel
     * header. rx_expect says whether the RX side gets the bare inner frame
     * (DUT decapsulated) or the tunneled frame (decap-parsed at RX). */
    struct pw_flow_encap encap;
    uint8_t  rx_expect;              /* enum pw_rx_expect; default inner */

    /* Per-field classifier match masks (BITWISE: a 1 bit means "this bit must
     * match"). The TEST_RX rule defaults to a full match on udp_dst / ipv4_dst;
     * the parser sets these to all-ones and a `match:` block can narrow them so
     * the RX rule matches only part of a field -- letting a modifier rotate the
     * rest, or classifying arbitrary-payload traffic by header bits. A modifier
     * on a matched field also auto-relaxes its mask (mask &= ~modifier_mask).
     * mask 0 = wildcard (field ignored). */
    uint16_t match_udp_dst_mask;     /* default 0xFFFF */
    uint32_t match_ipv4_dst_mask;    /* default 0xFFFFFFFF */

    /* IPv6 match masks for classify:header (hash). A classify:header flow keys
     * on the FULL v6 address by default (the hash key carries all 128 bits); a
     * `match: { ipv6_dst/src: <prefix> }` narrows it. When _set, the bitwise
     * mask (1 = must match) narrows the global hash key words: dst -> w0..3,
     * src -> w4..7. NB: the hash key mask is per-card GLOBAL, so distinct
     * per-flow prefixes fold into one mask (use a forward rule for a private
     * per-flow prefix). */
    bool     match_ipv6_dst_set;
    uint8_t  match_ipv6_dst_mask[16];
    bool     match_ipv6_src_set;
    uint8_t  match_ipv6_src_mask[16];

    /* RX classification mode. Default (false) keys on the test header flow_id
     * via the flow-id map (scales to 256 flows but needs the flow_id at a fixed
     * payload offset). When true ("classify: header"), the flow is classified
     * by the generic slice classifier on its header fields (udp_dst / ipv4_dst,
     * narrowed by the match masks) -- so the payload is free of any
     * classification dependency. Bounded by the slice-classifier capacity
     * (PWFPGA_NUM_SLICE distinct header matches / PWFPGA_NUM_SRULE rules). */
    bool classify_header;
};

/* Store-and-forward rule: relay frames matching the (optional) key from
 * one port to another on the same card. Compiles to a classifier
 * FORWARD_PORT row. ingress/egress are global port ids; match fields are
 * 0 = don't care. */
struct pw_forward_rule {
    char     name[PW_NAME_MAX];
    uint16_t ingress_port;               /* global port id */
    uint16_t egress_port;                /* global port id (same card) */
    uint8_t  priority;                   /* lower wins; default 40 */
    uint16_t ethertype;                  /* 0 = any */
    uint8_t  ip_proto;                   /* 0 = any */
    uint16_t udp_dst;                    /* 0 = any */
    uint16_t vlan;                       /* 0 = any */

    /* IPv6 address match via the field classifier (bitwise mask, 1 = must
     * match). Each non-zero 32-bit word of the mask costs one field comparator
     * (up to 4 per address; a /64 prefix leaves the low 2 words zero -> 2
     * comparators). The 12-comparator-per-card pool is shared across all
     * forward/punt rules; the compiler dedups and returns PW_E_NO_RESOURCES
     * when exhausted. */
    bool     ipv6_dst_set;
    uint8_t  ipv6_dst[16];
    uint8_t  ipv6_dst_mask[16];
    bool     ipv6_src_set;
    uint8_t  ipv6_src[16];
    uint8_t  ipv6_src_mask[16];
};

struct pw_config {
    struct pw_system     system;

    struct pw_card      *cards;
    size_t               n_cards;

    struct pw_logical_if *logical_if;
    size_t                n_logical_if;

    struct pw_flow      *flows;
    size_t               n_flows;

    struct pw_forward_rule *forwards;
    size_t                  n_forwards;
};

/* Diagnostic produced by the parser / validator. */
struct pw_diag {
    pw_status   code;
    char        path[256];               /* e.g. "flows[2].measurements.latency" */
    char        message[256];
};

/* Allocate / free. */
struct pw_config *pw_config_new(void);
void              pw_config_free(struct pw_config *cfg);

/* Parse YAML. The Phase 0 parser supports the subset documented in
 * docs/design/yaml-schema.md; unknown keys are rejected. Returns
 * PW_OK on success and populates *cfg; on failure returns a negative
 * pw_status and fills *diag if non-NULL. */
pw_status pw_config_parse_file(const char *path, struct pw_config *cfg, struct pw_diag *diag);
pw_status pw_config_parse_string(const char *yaml, size_t len, struct pw_config *cfg, struct pw_diag *diag);

/* Static validation: duplicate IDs, missing references, cross-card
 * latency, etc. Does not require any FPGA. */
pw_status pw_config_validate(const struct pw_config *cfg, struct pw_diag *diag);

/* Resolve a global_port to (card, local_port). Returns PW_OK on hit. */
pw_status pw_config_resolve_port(const struct pw_config *cfg, uint16_t global_port, struct pwfpga_port_ref *out);

/* Look up by ID. NULL on miss. */
const struct pw_card        *pw_config_card_by_id(const struct pw_config *cfg, uint16_t card_id);
const struct pw_logical_if  *pw_config_logical_if_by_id(const struct pw_config *cfg, uint32_t lif_id);
const struct pw_flow        *pw_config_flow_by_id(const struct pw_config *cfg, uint32_t flow_id);

#endif
