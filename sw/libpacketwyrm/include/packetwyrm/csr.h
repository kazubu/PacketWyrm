/* PacketWyrm: AS02MC04 CSR / flow / classifier wire structures.
 * These mirror the bit layouts documented in docs/design/csr-map.md.
 * They are the contract between FPGA RTL and the host control software,
 * and as such must change only with a matching version bump. */
#ifndef PACKETWYRM_CSR_H
#define PACKETWYRM_CSR_H

#include "packetwyrm/types.h"

/* Top-level register offsets in BAR0. */
enum {
    PWFPGA_REG_DEVICE_ID            = 0x0000,
    PWFPGA_REG_VERSION              = 0x0004,
    PWFPGA_REG_BUILD_ID             = 0x0008,
    PWFPGA_REG_GIT_HASH             = 0x000c,
    PWFPGA_REG_CAPABILITIES         = 0x0010,
    PWFPGA_REG_NUM_LOCAL_PORTS      = 0x0014,
    PWFPGA_REG_NUM_LOCAL_FLOWS      = 0x0018,
    PWFPGA_REG_NUM_LOGICAL_IFS      = 0x001c,
    PWFPGA_REG_NUM_CLASSIFIER       = 0x0020,
    PWFPGA_REG_NUM_HIST_BINS        = 0x0024,

    PWFPGA_REG_GLOBAL_CONTROL       = 0x0100,
    PWFPGA_REG_GLOBAL_STATUS        = 0x0104,
    PWFPGA_REG_TIMESTAMP_LOW        = 0x0108,
    PWFPGA_REG_TIMESTAMP_HIGH       = 0x010c,
    PWFPGA_REG_ERROR_STATUS         = 0x0110,
    PWFPGA_REG_IRQ_STATUS           = 0x0114,
    PWFPGA_REG_IRQ_MASK             = 0x0118,
    /* Write PWFPGA_REBOOT_MAGIC to trigger ICAP IPROG: the FPGA reloads
     * its bitstream from flash (PCIe drops; host must re-enumerate). */
    PWFPGA_REG_REBOOT               = 0x0120,

    /* On-chip SYSMON (SYSMONE4) telemetry: raw DRP ADC codes (measurement in
     * bits [15:4]). Convert with PWFPGA_SYSMON_TEMP_C / _SUPPLY_V below. */
    PWFPGA_REG_SYSMON_TEMP          = 0x0124, /* [15:0] die temperature code   */
    PWFPGA_REG_SYSMON_SUPPLY        = 0x0128, /* [15:0] VCCINT, [31:16] VCCAUX */

    /* J5 cross-card time-sync (pw_gpio_sync). CTRL bits: [0] enable,
     * [1] master, [2] repeat, [6:4] sync-in pin, [10:8] sync-out pin,
     * [19:16] period_log2 (master pulse every 2^N dp_clk cycles; N<5 is clamped
     * to 5 in HW -> minimum period 32 cycles, so the 16-cycle pulse keeps a low
     * gap and the far card sees a fresh edge each period). TS_LOW/HIGH = card-
     * local counter latched at the last
     * sync edge (read LOW then HIGH). SEQ = edge count (match across cards for
     * the inter-card offset). STATUS[5:0] = raw synchronised pad inputs. */
    PWFPGA_REG_GPIO_SYNC_CTRL       = 0x0130,
    PWFPGA_REG_GPIO_SYNC_TS_LOW     = 0x0134,
    PWFPGA_REG_GPIO_SYNC_TS_HIGH    = 0x0138,
    PWFPGA_REG_GPIO_SYNC_SEQ        = 0x013c,
    PWFPGA_REG_GPIO_SYNC_STATUS     = 0x0140,

    /* Per-SFP I2C management bus (SW bit-bang, open-drain). Write [3:0] =
     * drive-low per line (1 = pull the line low, 0 = release -> external
     * pull-up gives 1). Read [3:0] = the drive register; read [19:16] = the
     * (synchronised) pad-in state, same bit order:
     *   bit 0 SFP0 SCL, bit 1 SFP0 SDA, bit 2 SFP1 SCL, bit 3 SFP1 SDA.
     * Bit-bang I2C over it to read the SFP EEPROM: 0xA0 base ID at i2c addr
     * 0x50 (identifier / vendor / part / connector), 0xA2 DOM at 0x51
     * (temp / Vcc / TX bias / TX power / RX power, if the module is DDM-capable;
     * a passive DAC answers the ID page but has no optical DOM). */
    PWFPGA_REG_SFP_I2C              = 0x0150,

    /* Per-flow cross-card latency correction window. Slot i (= the RX checker
     * local_flow_id) at BASE + i*8: +0 = LO [31:0] (signed), +4 = HI [63:32].
     * Write LO then HI -- LO stages a shadow, HI commits {HI,shadow} atomically
     * to slot i's entry in the data-plane correction table. The RX checker then
     * computes lat = (rx_wire_ts + corr[slot]) - tx_ts PER FLOW, so a single RX
     * card can mix same-card flows (corr 0) and cross-card flows from different
     * TX cards (each its own inter-card offset). The daemon servo writes these.
     * Replaces the Stage-1 single global correction (0x0144/0x0148). */
    PWFPGA_REG_LAT_CORRECTION_BASE  = 0x0180,   /* .. 0x0180 + NUM_FLOWS*8 */

    /* NOTE: 0x0200..0x03FF was an early per-port control/status placeholder
     * that pw_csr_full never implemented (per-port status + stats are surfaced
     * through the stats-snapshot window at 0xC000). The low half (0x0200..
     * 0x02FF) now holds the generic slice-classifier windows (below);
     * 0x0300..0x03FF stays reserved. */

    /* Wide map for 64 flows / 64 classifier rows. Commit-bearing
     * windows are 16 KB apart (8 KB data + commit reg above it); the
     * live-read histogram gets 8 KB. Fills the 64 KB BAR; the former
     * SLOW_RX/TX placeholders (0x8000/0x9000) are reclaimed. */
    /* TEST_RX flow-id map: 256 entries x 4 B = 0x0400..0x07FF (between the
     * identity regs and the SPI window). entry[flow_id] at base + flow_id*4,
     * data = {[31] valid, [15:0] local_flow_id}. A test frame's test_flow_id
     * indexes this directly -> checker slot, so TEST_RX flows need no classifier
     * rule and scale past the classifier's ~16-entry routability limit. */
    PWFPGA_WIN_FLOWID_MAP           = 0x0400,  /* 0x0400..0x07FF */
    /* Unified field+UDF classifier (pw_field_classifier; the legacy classifier
     * is retired). Comparators source the parser's canonical fields (field
     * comparators) or a raw inner-frame window (UDF comparators); rules combine
     * the comparator bits into {action,egress,lfid,lif}. Occupies the old
     * classifier window region. 16 B/entry, last sub-word commits:
     *   cmp  (0x2000): src@+0, mask@+4, value@+8
     *   udf  (0x2100): offset@+0, mask@+4, value@+8
     *   rule (0x2200): word0@+0, lfid@+4, lif@+8 */
    PWFPGA_WIN_FC_CMP               = 0x2000,  /* NCMP x 16 B */
    PWFPGA_WIN_FC_UDF               = 0x2100,  /* NUDF x 16 B */
    PWFPGA_WIN_FC_RULE              = 0x2200,  /* NRULE x 16 B */
    /* Hash exact table (pw_hash_classifier): header-keyed high-count TEST_RX.
     * 32 B/entry: key words @+0x0..+0x14, control {[31]valid,[lfw-1:0]lfid}
     * @+0x18 (commit). Indexed by the SW-computed bucket. seed reg just below. */
    PWFPGA_WIN_HASH_MASK            = 0x2F00,  /* 11 words: global key mask */
    PWFPGA_REG_HASH_SEED            = 0x2FFC,
    PWFPGA_WIN_FC_HASH              = 0x3000,  /* HASH_DEPTH x 64 B (0x3000..0x4FFF) */
    PWFPGA_WIN_FLOW_TABLE           = 0x6000,  /* 0x6000..0x9FFF */
    PWFPGA_WIN_HISTOGRAM            = 0xA000,  /* 0xA000..0xBFFF (8 KB) */
    PWFPGA_WIN_STATS_SNAPSHOT       = 0xC000,  /* 0xC000..0xFFFF */
};

/* LEGACY alias: the parallel pw_classifier is retired (replaced by the field+UDF
 * classifier, which now owns 0x2000). Kept only so the legacy classifier_write
 * backend op + the standalone pw_phase3_{punt,forward,modgen,inject,ipv6gen}
 * tools (which target the old bitstream) still compile. Those tools must be
 * migrated to the field-classifier programming (PWFPGA_WIN_FC_*) to run on the
 * new bitstream; the daemon + pw_phase3_loopback already use it. */
#define PWFPGA_WIN_CLASSIFIER          0x2000u

/* pw_flowid_map entry: valid bit + local checker slot. */
#define PWFPGA_FLOWID_MAP_DEPTH     256u
#define PWFPGA_FLOWID_MAP_VALID     (1u << 31)
#define PWFPGA_FLOWID_MAP_ENTRY(base, flow_id)  ((base) + (flow_id) * 4u)

/* Unified field+UDF classifier capacity + register layout. Must match the RTL
 * params (pwfpga_top_phase3 NUM_CMP/NUM_UDF/NUM_RULE). NCMP field comparators
 * (each sources one canonical key field), NUDF UDF comparators (raw window),
 * NRULE rules over the NCMP+NUDF comparator bits. */
#define PWFPGA_NUM_CMP              12u
#define PWFPGA_NUM_UDF              2u
#define PWFPGA_NUM_RULE             32u
/* Hash exact table: HASH_DEPTH buckets, 64 B/entry. The key is 11 field-aligned
 * 32-bit words: l3_dst (w0..3, IPv4 dst in w0), l3_src (w4..7), {l4_src,l4_dst}
 * (w8), {vlan,ethertype} (w9), {0,proto} (w10). Key word w @+w*4 (w=0..10);
 * control word @+0x2C {[31] valid, [lfw-1:0] local_flow_id} commits. A GLOBAL
 * key mask (PWFPGA_WIN_HASH_MASK, 11 words) is ANDed in before hashing + verify
 * -- mask out a field/bits the generator randomizes so the flow still classes. */
#define PWFPGA_HASH_DEPTH          128u
#define PWFPGA_HASH_KEY_WORDS      11u
#define PWFPGA_HASH_KEY_WORD(base, i, w) ((base) + (i) * 64u + (w) * 4u)
#define PWFPGA_HASH_CTRL(base, i)        ((base) + (i) * 64u + 0x2Cu)
#define PWFPGA_HASH_CTRL_VALID           (1u << 31)
#define PWFPGA_HASH_MASK_WORD(base, w)   ((base) + (w) * 4u)
/* Comparator source selectors (pw_field_classifier src_lane). 32-bit lanes. */
enum pwfpga_fc_src {
    PWFPGA_FC_SRC_L4_DST     = 0,   /* udp/tcp dst port (low 16b)             */
    PWFPGA_FC_SRC_L4_SRC     = 1,
    PWFPGA_FC_SRC_IPV4_DST   = 2,
    PWFPGA_FC_SRC_IPV4_SRC   = 3,
    PWFPGA_FC_SRC_IPV6_DST_3 = 4,   /* ipv6_dst[127:96]                       */
    PWFPGA_FC_SRC_IPV6_DST_2 = 5,   /* ipv6_dst[95:64]                        */
    PWFPGA_FC_SRC_IPV6_DST_1 = 6,   /* ipv6_dst[63:32]                        */
    PWFPGA_FC_SRC_IPV6_DST_0 = 7,   /* ipv6_dst[31:0]                         */
    PWFPGA_FC_SRC_ETHERTYPE  = 8,   /* (low 16b)                              */
    PWFPGA_FC_SRC_L3_PROTO   = 9,   /* (low 8b)                               */
    PWFPGA_FC_SRC_VLAN       = 10,  /* [11:0] vlan_id, [12] inner-vlan present*/
    PWFPGA_FC_SRC_FLOW_ID    = 11,  /* test_flow_id                           */
    PWFPGA_FC_SRC_FLAGS      = 12,  /* see PWFPGA_FC_FLAG_* below             */
    PWFPGA_FC_SRC_INGRESS    = 13,  /* ingress_port (low 4b)                  */
    PWFPGA_FC_SRC_IPV6_SRC_0 = 14,  /* ipv6_src[31:0]                         */
    PWFPGA_FC_SRC_IPV6_SRC_3 = 15,  /* ipv6_src[127:96]                       */
    PWFPGA_FC_SRC_IPV6_SRC_1 = 16,  /* ipv6_src[63:32]                        */
    PWFPGA_FC_SRC_IPV6_SRC_2 = 17,  /* ipv6_src[95:64] -> all 4 src words     */
};
/* Bit positions in the FLAGS source lane. */
enum {
    PWFPGA_FC_FLAG_IS_TEST   = 1u << 0,
    PWFPGA_FC_FLAG_IS_ARP    = 1u << 1,
    PWFPGA_FC_FLAG_IS_IPV4   = 1u << 2,
    PWFPGA_FC_FLAG_IS_IPV6   = 1u << 3,
    PWFPGA_FC_FLAG_IS_TCP    = 1u << 4,
    PWFPGA_FC_FLAG_IS_UDP    = 1u << 5,
    PWFPGA_FC_FLAG_IS_ICMP   = 1u << 6,
    PWFPGA_FC_FLAG_IS_ICMP6  = 1u << 7,
    PWFPGA_FC_FLAG_IS_OSPF   = 1u << 8,
    PWFPGA_FC_FLAG_VLAN_VLD  = 1u << 9,
    PWFPGA_FC_FLAG_VALID     = 1u << 10,
};
/* Comparator: write src(@+0), mask(@+4), value(@+8 commits). UDF replaces src
 * with the byte offset (relative to the inner-frame base). */
#define PWFPGA_FC_CMP_SRC(base, i)    ((base) + (i) * 16u + 0u)
#define PWFPGA_FC_CMP_MASK(base, i)   ((base) + (i) * 16u + 4u)
#define PWFPGA_FC_CMP_VALUE(base, i)  ((base) + (i) * 16u + 8u)
#define PWFPGA_FC_UDF_OFFSET(base, i) ((base) + (i) * 16u + 0u)
#define PWFPGA_FC_UDF_MASK(base, i)   ((base) + (i) * 16u + 4u)
#define PWFPGA_FC_UDF_VALUE(base, i)  ((base) + (i) * 16u + 8u)
/* Rule: write word0(@+0), local_flow_id(@+4), logical_if_id(@+8 commits).
 * word0 packs {[13:0] care, [16:14] action, [20:17] egress, [28:21] prio,
 * [31] enable}. care bit i = field comparator i (0..NCMP-1); UDF comparator j
 * = bit NCMP+j. */
#define PWFPGA_FC_RULE_WORD0(base, i) ((base) + (i) * 16u + 0u)
#define PWFPGA_FC_RULE_LFID(base, i)  ((base) + (i) * 16u + 4u)
#define PWFPGA_FC_RULE_LIF(base, i)   ((base) + (i) * 16u + 8u)
#define PWFPGA_FC_RULE_W0(care, action, egress, prio, enable)          \
    (((uint32_t)(care)    & 0x3FFFu)        |                          \
     (((uint32_t)(action) & 0x7u)   << 14)  |                          \
     (((uint32_t)(egress) & 0xFu)   << 17)  |                          \
     (((uint32_t)(prio)   & 0xFFu)  << 21)  |                          \
     ((enable) ? (1u << 31) : 0u))

/* global_control bits */
enum {
    PWFPGA_GCTL_ENABLE          = 1u << 0,
    PWFPGA_GCTL_ARM             = 1u << 1,
    PWFPGA_GCTL_RESET_COUNTERS  = 1u << 2,
};

/* global_status bits. ERROR is the live err_sticky that drives the front-panel
 * R/G LED (set on any lost/decode error since the last stats-clear); ACTIVITY
 * is recent data-plane traffic. ARMED/RUNNING/DEGRADED are reserved (0). */
enum {
    PWFPGA_GSTAT_READY    = 1u << 0,
    PWFPGA_GSTAT_ARMED    = 1u << 1,
    PWFPGA_GSTAT_RUNNING  = 1u << 2,
    PWFPGA_GSTAT_ERROR    = 1u << 3,   /* err_sticky (LED red) */
    PWFPGA_GSTAT_DEGRADED = 1u << 4,
    PWFPGA_GSTAT_ACTIVITY = 1u << 5,   /* traffic seen recently */
};

/* SYSMON conversions (UltraScale+ SYSMONE4, on-chip measurements). The DRP
 * returns a 16-bit word with the 10-bit result left-justified in [15:4] ->
 * use the top 12 bits as a 12-bit code (0..4095). */
#define PWFPGA_SYSMON_CODE(raw)   (((raw) >> 4) & 0xFFFu)
/* Temperature (°C) from the on-chip temperature sensor. */
#define PWFPGA_SYSMON_TEMP_C(raw) \
    (((double)PWFPGA_SYSMON_CODE(raw) * 509.3140064 / 4096.0) - 280.23087870)
/* Supply voltage (V): full-scale 3 V across the 12-bit code. */
#define PWFPGA_SYSMON_SUPPLY_V(raw) \
    ((double)PWFPGA_SYSMON_CODE(raw) * 3.0 / 4096.0)

/* capability bits */
enum {
    PWFPGA_CAP_HAS_DMA            = 1u << 0,
    PWFPGA_CAP_HAS_MSIX           = 1u << 1,
    PWFPGA_CAP_HAS_HISTOGRAM      = 1u << 2,
    PWFPGA_CAP_HAS_QINQ_PARSER    = 1u << 3,
    PWFPGA_CAP_HAS_TIMESTAMP_SYNC = 1u << 4,
    PWFPGA_CAP_HAS_MIRROR         = 1u << 5,
    PWFPGA_CAP_HAS_PUNT           = 1u << 6,  /* slow-path RX/TX windows */
};

/* Classifier actions. */
enum pwfpga_action {
    PWFPGA_ACT_DROP             = 0,
    PWFPGA_ACT_TEST_RX          = 1,
    PWFPGA_ACT_PUNT_TO_HOST     = 2,
    PWFPGA_ACT_MIRROR_TO_HOST   = 3,
    PWFPGA_ACT_FORWARD_PORT     = 4,
};

/* Match key fields the classifier evaluates. Mask of equal layout.
 * Packed to give the host + the RTL the same byte-for-byte view. */
struct pwfpga_match_key {
    uint16_t ethertype;
    uint16_t vlan_id;
    uint8_t  pcp;
    uint8_t  l3_proto;       /* IP proto for v4, next-header for v6 */
    uint8_t  ingress_local_port;
    uint8_t  ip_version;     /* 4 or 6, 0 means don't care via mask */
    uint16_t udp_src_port;
    uint16_t udp_dst_port;
    uint32_t ipv4_src;
    uint32_t ipv4_dst;
    uint8_t  mac_src[6];
    uint8_t  mac_dst[6];
    uint32_t test_magic;
    uint32_t global_flow_id; /* matched against decoded test header */
} __attribute__((packed));

/* `flags` bits in pwfpga_classifier_entry. Bit 0 (ENABLE) gates the
 * row entirely; the RTL ignores any row whose ENABLE bit is clear,
 * regardless of action / key / mask. */
enum {
    PWFPGA_CLS_FLAG_ENABLE = 1u << 0,
};

struct pwfpga_classifier_entry {
    struct pwfpga_match_key key;       /* bytes  0..39 */
    struct pwfpga_match_key mask;      /* bytes 40..79 */
    uint32_t logical_if_id;            /* bytes 80..83 */
    uint32_t local_flow_id;            /* bytes 84..87 */
    uint8_t  action;     /* enum pwfpga_action       byte 88 */
    uint8_t  priority;   /* lower numbers win        byte 89 */
    uint16_t flags;      /* PWFPGA_CLS_FLAG_*    bytes 90..91 */
    uint8_t  egress_local_port; /* FORWARD_PORT target port  byte 92 */
    uint8_t  _reserved[3];      /* pad to a 32-bit word      bytes 93..95 */
    /* IPv6 dst-address match. The 40-byte pwfpga_match_key has no room for a
     * 128-bit address, so the inner IPv6 dst key + mask live in the row tail
     * (the 40B key only covers v4). Network byte order (byte 0 first), matching
     * pw_parser_axis. mask all-ones = exact match; all-zero = don't care. The
     * match is exact (==), not bitwise. */
    uint8_t  ipv6_dst[16];      /* bytes  96..111 */
    uint8_t  ipv6_dst_mask[16]; /* bytes 112..127 */
} __attribute__((packed));

_Static_assert(sizeof(struct pwfpga_classifier_entry) == 128,
               "pwfpga_classifier_entry must be exactly 128 bytes (fills the row)");

enum pwfpga_payload_mode {
    PWFPGA_PAYLOAD_ZERO      = 0,
    PWFPGA_PAYLOAD_INCREMENT = 1,
    PWFPGA_PAYLOAD_PRBS      = 2,
    PWFPGA_PAYLOAD_RANDOM    = 3,
};

/* Default FPGA data-plane clock used for host-side tokens/cycle
 * computation. The Phase 3 streaming data plane on the AS02MC04 runs at
 * 156.25 MHz (= 10G line rate; the BAR crosses in from the 250 MHz PCIe
 * user clock via an AXI4-Lite clock converter). The token-bucket rate
 * (tokens_per_tick_fp) is derived from this, so it must match the RTL
 * dp_clk or the generated line rate will be off by the ratio. */
#define PWFPGA_DATA_PLANE_CLOCK_HZ  156250000u

struct pwfpga_flow_config {
    uint8_t  enable;
    uint8_t  egress_local_port;

    uint32_t global_flow_id;
    uint32_t local_flow_id;
    uint32_t logical_if_id;

    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];

    uint8_t  vlan_enable;
    uint16_t vlan_id;
    uint8_t  pcp;

    uint8_t  ip_version;
    uint32_t src_ipv4;
    uint32_t dst_ipv4;
    uint8_t  dscp;
    uint8_t  ttl;

    uint16_t udp_src_port;
    uint16_t udp_dst_port;

    uint16_t frame_len_min;
    uint16_t frame_len_max;
    uint16_t frame_len_step;

    uint64_t rate_bps;
    uint64_t rate_pps;
    uint32_t burst_size;
    uint32_t burst_gap_ticks;

    /* Host-computed for the RTL token bucket; derived from rate_bps,
     * burst_size, and PWFPGA_DATA_PLANE_CLOCK_HZ. Saves a divider
     * in the FPGA. tokens_per_tick_fp is Q16.16 bytes/cycle. */
    uint32_t tokens_per_tick_fp;
    uint16_t burst_bytes;
    uint16_t reserved0;

    uint8_t  payload_mode;       /* enum pwfpga_payload_mode */
    uint32_t payload_seed;

    uint8_t  insert_sequence;
    uint8_t  insert_timestamp;

    /* RX side knobs (used when this row is programmed on the RX card
     * of a cross-card flow). */
    uint8_t  tx_enable;
    uint8_t  rx_check_enable;

    /* Per-field modifiers (commercial-gen "field modifier"): vary the
     * masked bits of a header field per emitted frame so one slot looks
     * like many flows to the DUT. mode = enum pwfpga_field_mod; mask
     * selects which bits rotate (e.g. 0x000003FF = low 10 bits = 1024
     * apparent flows). The test header (magic/flow_id/seq/ts) is never
     * modified, so RX loss/latency measurement is unaffected, and the IPv4
     * header checksum is recomputed in hardware from the modified address.
     * (MAC/VLAN modifiers are a mechanical extension of the same scheme.) */
    uint8_t  src_ipv4_mod;       /* byte 92 */
    uint32_t src_ipv4_mask;      /* bytes 93..96 */
    uint8_t  dst_ipv4_mod;       /* byte 97 */
    uint32_t dst_ipv4_mask;      /* bytes 98..101 */
    uint8_t  udp_src_mod;        /* byte 102 */
    uint16_t udp_src_mask;       /* bytes 103..104 */
    uint8_t  udp_dst_mod;        /* byte 105 */
    uint16_t udp_dst_mask;       /* bytes 106..107 */

    /* IPv6 addresses (used when ip_version == 6; the row is then emitted as
     * an IPv6/UDP frame with a correct UDP checksum). Network byte order.
     * These push the row past 128 B, so PWFPGA_FLOW_STRIDE is 256. */
    uint8_t  ipv6_src[16];       /* bytes 108..123 */
    uint8_t  ipv6_dst[16];       /* bytes 124..139 */

    /* MAC / VLAN field modifiers (same scheme as the address/port modifiers
     * above). MAC masks are 6 bytes, MSB-first (byte 0 = address bits 47..40),
     * matching src_mac/dst_mac. VLAN mask is the low 12 bits. These fields are
     * not in any checksum, so the generator just rewrites the header bytes. */
    uint8_t  src_mac_mod;        /* byte 140 */
    uint8_t  src_mac_mask[6];    /* bytes 141..146 */
    uint8_t  dst_mac_mod;        /* byte 147 */
    uint8_t  dst_mac_mask[6];    /* bytes 148..153 */
    uint8_t  vlan_mod;           /* byte 154 */
    uint16_t vlan_mask;          /* bytes 155..156 (low 12 bits) */

    /* Encapsulation (optional): wrap the inner IP/UDP/test frame in an outer
     * L3 + tunnel header. encap_type = enum pwfpga_encap_type; outer_ip_version
     * 4 or 6 (0 = no encap). For EtherIP/GRE-transparent the inner Ethernet
     * frame is emitted too. rx_expect = enum pwfpga_rx_expect. The outer
     * address is read per outer_ip_version (v4 from outer_src/dst_ipv4, v6 from
     * outer_ipv6_src/dst). These extend the 256-byte row (ends at byte 201). */
    uint8_t  encap_type;         /* byte 157 */
    uint8_t  outer_ip_version;   /* byte 158 (0 none / 4 / 6) */
    uint8_t  rx_expect;          /* byte 159 */
    uint8_t  outer_ttl;          /* byte 160 */
    uint8_t  outer_dscp;         /* byte 161 */
    uint32_t outer_src_ipv4;     /* bytes 162..165 */
    uint32_t outer_dst_ipv4;     /* bytes 166..169 */
    uint8_t  outer_ipv6_src[16]; /* bytes 170..185 */
    uint8_t  outer_ipv6_dst[16]; /* bytes 186..201 */
    /* EtherIP inner-Ethernet MAC (compiler fills from encap.inner_l2, or the
     * flow l2 MAC when unset). dst then src, matching the main MAC fields. */
    uint8_t  inner_dst_mac[6];   /* bytes 202..207 */
    uint8_t  inner_src_mac[6];   /* bytes 208..213 */

    /* Full 128-bit IPv6 address-modifier mask: src_ipv4_mask / dst_ipv4_mask
     * hold address bits [31:0]; these hold bits [127:32], little-endian by byte
     * (index 0 = address bits [39:32], index 11 = [127:120]). Zero (default) =
     * low-32-only rotation (back-compatible). Only used when ip_version == 6. */
    uint8_t  src_ipv6_mask_hi[12]; /* bytes 214..225 */
    uint8_t  dst_ipv6_mask_hi[12]; /* bytes 226..237 */

    /* L4 protocol selector: 17 = UDP (default), 6 = TCP (stateless segment
     * generation -- no handshake/ACK/retransmit). tcp_flags is the fixed flags
     * byte (default 0x02 = SYN), applied by the generator; ignored for UDP. */
    uint8_t  l4_proto;             /* byte 238 */
    uint8_t  tcp_flags;            /* byte 239 */

    /* Frame template selector: which layers the generator emits.
     *   TEST  (0) = full Eth/IP/L4 + 32-byte PacketWyrm test header (default).
     *   L4RAW (1) = full Eth/IP/L4 but a raw (zero) payload, no test header
     *               (enables a true 64-byte frame with real L2/L3/L4 headers).
     *   L3RAW (2) = Eth[+vlan] + IP + raw payload (no L4, no test header).
     *   L2RAW (3) = Eth[+vlan] + ethertype + raw payload (no L3/L4/test header).
     * Raw templates carry no test header, so RX loss/latency/seq measurement is
     * meaningless for them (the compiler forces measurements off and requires
     * classify: header). The generator always zero-pads the payload, so an RX
     * header-classifier sees zeros for any L3/L4 it attempts to parse. */
    uint8_t  frame_template;       /* byte 240: enum pwfpga_frame_template */
    uint8_t  reserved_ft;          /* byte 241: reserved / word align */
    uint16_t l2_ethertype;         /* bytes 242..243: L2RAW ethertype (0 => IP-family
                                    * default: 0x0800 v4 / 0x86DD v6, per ip_version) */
} __attribute__((packed));

_Static_assert(sizeof(struct pwfpga_flow_config) == 244,
               "pwfpga_flow_config wire layout drifted (expected 244 bytes)");
_Static_assert(offsetof(struct pwfpga_flow_config, src_ipv6_mask_hi) == 214,
               "src_ipv6_mask_hi must be at wire byte 214");
_Static_assert(offsetof(struct pwfpga_flow_config, dst_ipv6_mask_hi) == 226,
               "dst_ipv6_mask_hi must be at wire byte 226");
_Static_assert(offsetof(struct pwfpga_flow_config, l4_proto) == 238,
               "l4_proto must be at wire byte 238");
_Static_assert(offsetof(struct pwfpga_flow_config, frame_template) == 240,
               "frame_template must be at wire byte 240");
_Static_assert(offsetof(struct pwfpga_flow_config, l2_ethertype) == 242,
               "l2_ethertype must be at wire byte 242");

enum pwfpga_encap_type {
    PWFPGA_ENCAP_NONE    = 0,
    PWFPGA_ENCAP_IPIP    = 1,
    PWFPGA_ENCAP_GRE     = 2,
    PWFPGA_ENCAP_ETHERIP = 3,
};
enum pwfpga_rx_expect { PWFPGA_RX_INNER = 0, PWFPGA_RX_TUNNELED = 1 };

enum pwfpga_frame_template {
    PWFPGA_FRAME_TEMPLATE_TEST  = 0,   /* full headers + 32B test header (default) */
    PWFPGA_FRAME_TEMPLATE_L4RAW = 1,   /* full Eth/IP/L4, raw payload, no test hdr */
    PWFPGA_FRAME_TEMPLATE_L3RAW = 2,   /* Eth[+vlan] + IP + raw payload */
    PWFPGA_FRAME_TEMPLATE_L2RAW = 3,   /* Eth[+vlan] + ethertype + raw payload */
};

enum pwfpga_field_mod {
    PWFPGA_FIELD_STATIC    = 0,
    PWFPGA_FIELD_INCREMENT = 1,
    PWFPGA_FIELD_RANDOM    = 2,
};

/* On-wire test packet header (carried inside the UDP payload). */
struct pwfpga_test_hdr {
    uint32_t magic;          /* PW_TEST_HDR_MAGIC */
    uint16_t version;
    uint16_t reserved;
    uint32_t global_flow_id;
    uint64_t sequence;
    uint64_t tx_timestamp;
    uint32_t payload_crc_or_prbs_state;
} __attribute__((packed));

/* ==================================================================
 * XDMA AXI-Stream slow path (Phase 3 DMA build, CAP_HAS_DMA)
 * ==================================================================
 * The slow path is the Xilinx XDMA IP in AXI-Stream mode (pw_dma_slowpath
 * bridges its H2C/C2H streams to the data-plane inject/punt AXIS). The host
 * drives the XDMA descriptor engine directly over vfio (no xdma.ko). Layout,
 * descriptor format and register offsets are from Xilinx PG195.
 *
 * BAR layout on the DMA build (VERIFIED on silicon 2026-07-04, not the .xci's
 * apparent 128 KB split-BAR0): the IP exposes TWO 64 KB BARs --
 *   BAR0  AXI-Lite-master CSR window (the register map above), at offset 0
 *         -- UNCHANGED from the legacy (non-DMA) build; the CSR did NOT move.
 *   BAR1  XDMA DMA/SGDMA control registers (this block).
 * So the backend maps BAR0 for CSR (offset 0, csr_off=0) and BAR1 for the XDMA
 * engine. PWFPGA_CSR_DMA_OFFSET below is retained only as a fallback for a
 * hypothetical future single-big-BAR build (the backend probes DEVICE_ID at 0
 * and at that offset and self-selects); on THIS build it is unused (csr_off=0).
 *
 * NB (HW bring-up, done): the XDMA control-register bit positions + completion
 * semantics were confirmed on silicon -- the single-descriptor completed-count
 * RESETS to 0 on RUN (so for H2C/single-desc just wait for count != 0 -- reading
 * a baseline races either way), the C2H
 * received length is NOT written to desc.bytes -- so the punt in-band header
 * carries a byte_len field (bytes 5-6, LE), SAF-measured in the FPGA, which the
 * host reads directly (the frame-own L2/L3 parse is retained only as a
 * byte_len==0 fallback); and a per-frame stop/re-arm wedges the engine (C2H uses
 * a continuously-running circular ring). Register/target OFFSETS + the 32-byte
 * descriptor FORMAT are PG195-stable.
 *
 * Punt in-band header (8 B, prepended by pw_dma_slowpath ahead of each frame):
 *   bytes 0-3  lif_id   (LE)
 *   byte  4    ingress  (low nibble)
 *   bytes 5-6  byte_len (LE) -- frame length, SAF-measured in the dp domain
 *   byte  7    reserved (0)
 * Inject header (host->card): byte 0 = egress port; the engine strips it. */

/* CSR-window offset for a hypothetical future single-big-BAR layout where the
 * CSR sits in the upper half (the backend probes + self-selects). On the current
 * two-BAR DMA build the CSR is BAR0 offset 0, so this is unused (csr_off=0). */
#define PWFPGA_CSR_DMA_OFFSET   0x10000u

/* XDMA register targets (each block is 0x1000; PG195 Table "PCIe DMA reg space").
 * Single H2C + single C2H channel on this build (H2C/C2H_XDMA_CHNL=0x0F). */
enum pwfpga_xdma_target {
    PWFPGA_XDMA_H2C_CHANNEL   = 0x0000u,  /* host->card channel 0 (inject) */
    PWFPGA_XDMA_C2H_CHANNEL   = 0x1000u,  /* card->host channel 0 (punt)   */
    PWFPGA_XDMA_IRQ_BLOCK     = 0x2000u,
    PWFPGA_XDMA_CONFIG_BLOCK  = 0x3000u,
    PWFPGA_XDMA_H2C_SGDMA     = 0x4000u,  /* H2C descriptor engine */
    PWFPGA_XDMA_C2H_SGDMA     = 0x5000u,  /* C2H descriptor engine */
    PWFPGA_XDMA_SGDMA_COMMON  = 0x6000u,
};

/* Channel register offsets (relative to an H2C/C2H channel block). */
enum pwfpga_xdma_channel_reg {
    PWFPGA_XDMA_CH_IDENTIFIER      = 0x00u,  /* RO: 0x1fc0<target> subsystem id */
    PWFPGA_XDMA_CH_CONTROL         = 0x04u,  /* RW  */
    PWFPGA_XDMA_CH_CONTROL_W1S     = 0x08u,  /* write-1-to-set   */
    PWFPGA_XDMA_CH_CONTROL_W1C     = 0x0Cu,  /* write-1-to-clear */
    PWFPGA_XDMA_CH_STATUS          = 0x40u,  /* RW  */
    PWFPGA_XDMA_CH_STATUS_RC       = 0x44u,  /* read-clear */
    PWFPGA_XDMA_CH_COMPLETED_COUNT = 0x48u,  /* RO: completed descriptor count */
    PWFPGA_XDMA_CH_ALIGNMENTS      = 0x4Cu,  /* RO: addr/len alignment reqs */
    PWFPGA_XDMA_CH_POLL_WB_LO      = 0x88u,  /* poll-mode writeback addr lo */
    PWFPGA_XDMA_CH_POLL_WB_HI      = 0x8Cu,
};

/* SGDMA register offsets (relative to an H2C/C2H SGDMA block). The engine
 * fetches the descriptor at {DESC_ADDR_HI:DESC_ADDR_LO} when the channel runs. */
enum pwfpga_xdma_sgdma_reg {
    PWFPGA_XDMA_SG_DESC_ADDR_LO = 0x80u,
    PWFPGA_XDMA_SG_DESC_ADDR_HI = 0x84u,
    PWFPGA_XDMA_SG_DESC_ADJ     = 0x88u,  /* # of adjacent descriptors - 1 */
    PWFPGA_XDMA_SG_DESC_CREDITS = 0x8Cu,
};

/* Channel Control register bits (VERIFY on HW against PG195). */
enum {
    PWFPGA_XDMA_CTRL_RUN            = 1u << 0,  /* start descriptor fetch/run */
    PWFPGA_XDMA_CTRL_IE_DESC_STOP   = 1u << 1,  /* int-enable: desc stopped */
    PWFPGA_XDMA_CTRL_IE_DESC_CMPL   = 1u << 2,  /* int-enable: desc completed */
    PWFPGA_XDMA_CTRL_IE_ALIGN_ERR   = 1u << 3,
    PWFPGA_XDMA_CTRL_IE_MAGIC_STOP  = 1u << 4,
    PWFPGA_XDMA_CTRL_IE_READ_ERR    = 0x1fu << 9,
    PWFPGA_XDMA_CTRL_IE_DESC_ERR    = 0x1fu << 19,
};
/* Channel Status register bits (VERIFY on HW). The error bits share the bit
 * positions of the control register's interrupt-enable error masks (PG195):
 * align (bit 3), read errors (bits 9-13), descriptor errors (bits 19-23). On a
 * clean completion they read 0, so PWFPGA_XDMA_STAT_ERR is a safe abort signal
 * for the H2C completion poll (the primary success signal stays the
 * completed-descriptor count). */
enum {
    PWFPGA_XDMA_STAT_BUSY          = 1u << 0,
    PWFPGA_XDMA_STAT_DESC_STOPPED  = 1u << 1,
    PWFPGA_XDMA_STAT_DESC_COMPLETED= 1u << 2,
    PWFPGA_XDMA_STAT_ERR           = (1u << 3) | (0x1Fu << 9) | (0x1Fu << 19),
};

/* XDMA hardware scatter-gather descriptor (PG195, 32 bytes, little-endian).
 * In AXI-Stream mode: H2C uses src_addr (host IOVA of the frame) + len, dst is
 * ignored (data goes to the AXIS); C2H uses dst_addr (host IOVA of the receive
 * buffer) + len (buffer capacity), src is ignored (data comes from the AXIS)
 * and the actual received length comes back via the completion/writeback. */
struct pwfpga_xdma_desc {
    uint32_t control;      /* [31:16]=magic 0xAD4B, [13:8]=nxt_adj, low bits below */
    uint32_t bytes;        /* transfer length, max 0x0FFFFFFF (28-bit)  */
    uint32_t src_addr_lo;
    uint32_t src_addr_hi;
    uint32_t dst_addr_lo;
    uint32_t dst_addr_hi;
    uint32_t next_lo;      /* next descriptor address (0 if single) */
    uint32_t next_hi;
} __attribute__((packed));

#define PWFPGA_XDMA_DESC_MAGIC     0xAD4B0000u   /* control[31:16] */
#define PWFPGA_XDMA_DESC_STOP      (1u << 0)     /* stop after this descriptor */
#define PWFPGA_XDMA_DESC_COMPLETED (1u << 1)     /* report completion (writeback) */
#define PWFPGA_XDMA_DESC_EOP       (1u << 4)     /* end-of-packet (H2C AXI-Stream) */

/* Poll-mode writeback the engine stores after a descriptor completes (PG195).
 * completed count in [30:0]; bit31 = "sts_err". We poll this in host memory
 * instead of the completed-count register to avoid an MMIO read per poll. */
struct pwfpga_xdma_poll_wb {
    uint32_t completed_desc_count;   /* [30:0] count, [31] error */
    uint32_t reserved;
} __attribute__((packed));

/* ------------- Window layout for the BAR backend --------------------
 *
 * Each table window owns a small region (4 KB). Rows have a fixed
 * power-of-two stride large enough for the packed struct above; a
 * write-1-to-commit register lives at the *last* dword of each
 * window so the row table fits below it without colliding.
 *
 *   classifier window 0x1000..0x1FFF
 *     row N data:     PWFPGA_WIN_CLASSIFIER + N * PWFPGA_CLASSIFIER_STRIDE
 *     commit:         PWFPGA_REG_CLASSIFIER_COMMIT
 *
 *   flow window 0x2000..0x2FFF
 *     row N data:     PWFPGA_WIN_FLOW_TABLE + N * PWFPGA_FLOW_STRIDE
 *     commit:         PWFPGA_REG_FLOW_COMMIT
 *
 *   stats snapshot window 0x3000..0x3FFF
 *     trigger:        PWFPGA_REG_STATS_SNAPSHOT_TRIGGER (write 1)
 *     port[N] block:  PWFPGA_WIN_STATS_SNAPSHOT + N * PWFPGA_PORT_STATS_STRIDE
 *     flow[N] block:  PWFPGA_WIN_STATS_SNAPSHOT + PWFPGA_FLOW_STATS_BASE +
 *                                                 N * PWFPGA_FLOW_STATS_STRIDE
 *
 *   histogram window 0x4000..0x4FFF
 *     flow[N] base:   PWFPGA_WIN_HISTOGRAM + N * PWFPGA_FLOW_HIST_STRIDE
 */
#define PWFPGA_CLASSIFIER_STRIDE       128u
#define PWFPGA_FLOW_STRIDE             256u   /* 256 (was 128): IPv6 addrs push the row past 128 B */
#define PWFPGA_PORT_STATS_STRIDE       128u
#define PWFPGA_FLOW_STATS_STRIDE       128u
#define PWFPGA_FLOW_HIST_STRIDE        128u   /* 16 * 8 bytes = 16 buckets */
/* Per-flow stats sit above the per-port stats area inside the
 * snapshot window. Two 128-byte port blocks = 0x100 bytes. */
#define PWFPGA_FLOW_STATS_BASE         0x100u

/* Per-window index capacities: how many rows/slots a windowed accessor may
 * address before its stride would carry the access OUT of its own window and
 * alias the neighbouring one (which is still inside the BAR, so a bare
 * "within BAR" bound would not catch it). Derived from the window map above:
 *  - flow-table rows fill the window up to the histogram window (0xA000): 64
 *    stride slots. The flow-commit register sits in the UNUSED tail of the
 *    last slot (row 63 data is sizeof(pwfpga_flow_config)=244 B, ending at
 *    0x9FF4, before commit at 0x9FFC), so all 64 rows are usable -- bounding
 *    by the commit register would wrongly reject row 63. bar_flow_write()
 *    additionally checks the actual 244-B extent vs the commit register, so a
 *    future struct growth can't silently overrun it.
 *  - histogram slots end where the stats-snapshot window begins (0xC000);
 *  - flow-stats slots (inside the snapshot window, above the port blocks) end
 *    at the window's control registers (DP_RESET at window + 0x3FF4).
 * These are defensive ceilings; the operational count is card_info's
 * num_local_flows (<= these). */
#define PWFPGA_FLOW_TABLE_ROWS \
    ((PWFPGA_WIN_HISTOGRAM - PWFPGA_WIN_FLOW_TABLE) / PWFPGA_FLOW_STRIDE)
#define PWFPGA_FLOW_HIST_SLOTS \
    ((PWFPGA_WIN_STATS_SNAPSHOT - PWFPGA_WIN_HISTOGRAM) / PWFPGA_FLOW_HIST_STRIDE)
#define PWFPGA_FLOW_STATS_SLOTS \
    ((PWFPGA_REG_DP_RESET - (PWFPGA_WIN_STATS_SNAPSHOT + PWFPGA_FLOW_STATS_BASE)) \
     / PWFPGA_FLOW_STATS_STRIDE)

/* Commit/trigger/clear registers sit above each window's 8 KB data
 * region (64 rows * 128 B), at window + 0x3FFC / 0x3FF8. */
#define PWFPGA_REG_CLASSIFIER_COMMIT       (PWFPGA_WIN_CLASSIFIER + 0x3FFCu)
#define PWFPGA_REG_FLOW_COMMIT             (PWFPGA_WIN_FLOW_TABLE + 0x3FFCu)
#define PWFPGA_REG_STATS_SNAPSHOT_TRIGGER  (PWFPGA_WIN_STATS_SNAPSHOT + 0x3FFCu)
/* Write 1: soft-clear all RX checker counters + re-baseline sequence
 * tracking (no rst_n). `test arm` uses this so a measurement run starts
 * from zero. */
#define PWFPGA_REG_STATS_CLEAR             (PWFPGA_WIN_STATS_SNAPSHOT + 0x3FF8u)
/* Write 1: data-plane soft reset -- clears the wedge-prone datapath
 * state machines (generators, store-and-forward FIFOs, egress/punt
 * arbiters) so a wedged data plane recovers without a JTAG reconfig.
 * The pulse is also stretched and CDC'd into each MAC TX clock to flush
 * the per-port MAC-TX CDC FIFO (both sides) and reset pw_ts_insert, so a
 * frame stuck in the egress FIFO (MAC-TX clock domain) is discarded and
 * TX recovers in-system. Re-initialises TX-CDC state while the TX clock
 * runs; does NOT cover the MAC/PCS/GT, the RX CDC, or a stopped TX clock
 * (those still need an ICAP reboot / power cycle). Configuration
 * (classifier / flow tables) is preserved. */
#define PWFPGA_REG_DP_RESET                (PWFPGA_WIN_STATS_SNAPSHOT + 0x3FF4u)

/* In-system SPI flash master (pw_spi_flash) -- lives in the free reg
 * region. Lets the host erase/program/read the config flash live over
 * PCIe (no JTAG, no reconfiguration). A raw x1 SPI byte engine: software
 * composes the flash commands and verifies by read-back. */
#define PWFPGA_WIN_SPI_FLASH               0x0800u
#define PWFPGA_REG_SPI_CTRL                (PWFPGA_WIN_SPI_FLASH + 0x000u) /* W:[0]go [1]cs_hold  R:[0]busy */
#define PWFPGA_REG_SPI_LEN                 (PWFPGA_WIN_SPI_FLASH + 0x004u) /* bytes to shift */
#define PWFPGA_SPI_TXBUF                   (PWFPGA_WIN_SPI_FLASH + 0x100u) /* 512 B */
#define PWFPGA_SPI_RXBUF                   (PWFPGA_WIN_SPI_FLASH + 0x300u) /* 512 B */
#define PWFPGA_SPI_BUF_BYTES               512u
#define PWFPGA_SPI_CTRL_GO                 (1u << 0)
#define PWFPGA_SPI_CTRL_CS_HOLD            (1u << 1)
#define PWFPGA_SPI_STATUS_BUSY             (1u << 0)

/* Punt / slow-path RX window (pw_punt_rx_window) -- FPGA -> host delivery
 * of classifier PUNT_TO_HOST / MIRROR_TO_HOST frames, BAR-polled (no DMA).
 * Lives in the free 0x1000 region. One frame at a time: poll STATUS, read
 * INFO + LIF + the DATA words, then write POP to release the slot. Frames
 * larger than the buffer (2 KB) are dropped and flagged in STATUS.
 *
 * ⚠️ LEGACY (non-DMA bitstream ONLY). The production Phase-3 DMA bitstream
 * (CAP_HAS_DMA) replaces this CSR window with the PCIe-DMA slow path
 * (pw_dma_slowpath; see the XDMA section above) and does NOT instantiate
 * pw_punt_rx_window at all -- HAS_DMA attach uses the DMA path exclusively
 * (no CSR-window fallback). This block is retained only for the older
 * non-DMA bitstream; do NOT treat it as a production fallback. */
#define PWFPGA_WIN_PUNT_RX                 0x1000u
#define PWFPGA_REG_PUNT_STATUS             (PWFPGA_WIN_PUNT_RX + 0x000u) /* R:[0]frame_valid [1]overflow */
#define PWFPGA_REG_PUNT_INFO               (PWFPGA_WIN_PUNT_RX + 0x004u) /* R:[13:0]byte_len [19:16]ingress_port */
#define PWFPGA_REG_PUNT_LIF                (PWFPGA_WIN_PUNT_RX + 0x008u) /* R: logical_if_id */
#define PWFPGA_REG_PUNT_POP                (PWFPGA_WIN_PUNT_RX + 0x00Cu) /* W:1 -> release current frame */
#define PWFPGA_REG_PUNT_RX_TS_LOW          (PWFPGA_WIN_PUNT_RX + 0x010u) /* R: RX wire timestamp [31:0] */
#define PWFPGA_REG_PUNT_RX_TS_HIGH         (PWFPGA_WIN_PUNT_RX + 0x014u) /* R: RX wire timestamp [63:32] */
#define PWFPGA_PUNT_DATA                   (PWFPGA_WIN_PUNT_RX + 0x020u) /* R: frame word i at +i*4, LE */
#define PWFPGA_PUNT_MAX_FRAME              2048u
#define PWFPGA_PUNT_STATUS_VALID           (1u << 0)
#define PWFPGA_PUNT_STATUS_OVERFLOW        (1u << 1)
#define PWFPGA_PUNT_INFO_LEN_MASK          0x3FFFu
#define PWFPGA_PUNT_INFO_INGRESS_SHIFT     16u

/* Slow-path TX inject window (host -> FPGA; pw_inject_tx_window). The host
 * composes a frame in DATA (little-endian 32-bit words, in order), sets
 * INFO (byte_len + egress_port), then writes CTRL.go=1; the window emits it
 * into the chosen egress port's TX arbiter. Poll CTRL.busy for completion.
 * Slow-path control traffic only -> 512 B max frame. Lives in the free
 * 0x0D00 region (below the punt window).
 *
 * ⚠️ LEGACY (non-DMA bitstream ONLY) -- same as the punt window above: the
 * DMA bitstream (CAP_HAS_DMA) injects via pw_dma_slowpath, not this window. */
#define PWFPGA_WIN_INJECT_TX               0x0D00u
#define PWFPGA_REG_INJECT_CTRL             (PWFPGA_WIN_INJECT_TX + 0x000u) /* W:[0]go  R:[0]busy */
#define PWFPGA_REG_INJECT_INFO             (PWFPGA_WIN_INJECT_TX + 0x004u) /* W:[13:0]byte_len [19:16]egress_port */
#define PWFPGA_REG_INJECT_TX_TS_LOW        (PWFPGA_WIN_INJECT_TX + 0x008u) /* R: egress wire timestamp [31:0] */
#define PWFPGA_REG_INJECT_TX_TS_HIGH       (PWFPGA_WIN_INJECT_TX + 0x00Cu) /* R: egress wire timestamp [63:32] */
#define PWFPGA_INJECT_DATA                 (PWFPGA_WIN_INJECT_TX + 0x040u) /* W: frame word i at +i*4, LE */
#define PWFPGA_INJECT_MAX_FRAME            512u
#define PWFPGA_INJECT_CTRL_GO              (1u << 0)
#define PWFPGA_INJECT_STATUS_BUSY          (1u << 0)
#define PWFPGA_INJECT_INFO_EGRESS_SHIFT    16u

/* Magic written to PWFPGA_REG_REBOOT to trigger in-band reconfiguration
 * (ICAP IPROG -> reload bitstream from flash). "RBOT". */
#define PWFPGA_REBOOT_MAGIC                0x52424F54u

#endif
