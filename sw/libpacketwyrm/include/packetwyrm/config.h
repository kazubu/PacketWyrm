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
    uint32_t mask;
};

struct pw_flow_modifiers {
    struct pw_field_mod src_ipv4;
    struct pw_field_mod dst_ipv4;
    struct pw_field_mod udp_src;
    struct pw_field_mod udp_dst;
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
