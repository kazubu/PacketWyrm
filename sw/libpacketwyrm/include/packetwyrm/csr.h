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
    /* Generic slice classifier (pw_slice_classifier): header-defined flows
     * classified by arbitrary {offset,mask,value} slices + rules over the slice-
     * match bits -- payload-agnostic (unlike the flow-id map). Slice configs are
     * 16 B each (offset@+0, mask@+4, value@+8 -> commit); rules are 8 B each
     * (word0@+0, local_flow_id@+4 -> commit). Both windows sit in the free
     * 0x0200..0x03FF block. */
    PWFPGA_WIN_SLICE_CFG            = 0x0200,  /* 0x0200..0x023F (4 x 16 B) */
    PWFPGA_WIN_SLICE_RULE           = 0x0280,  /* 0x0280..0x02BF (8 x 8 B) */
    PWFPGA_WIN_CLASSIFIER           = 0x2000,  /* 0x2000..0x5FFF */
    PWFPGA_WIN_FLOW_TABLE           = 0x6000,  /* 0x6000..0x9FFF */
    PWFPGA_WIN_HISTOGRAM            = 0xA000,  /* 0xA000..0xBFFF (8 KB) */
    PWFPGA_WIN_STATS_SNAPSHOT       = 0xC000,  /* 0xC000..0xFFFF */
};

/* pw_flowid_map entry: valid bit + local checker slot. */
#define PWFPGA_FLOWID_MAP_DEPTH     256u
#define PWFPGA_FLOWID_MAP_VALID     (1u << 31)
#define PWFPGA_FLOWID_MAP_ENTRY(base, flow_id)  ((base) + (flow_id) * 4u)

/* Generic slice classifier capacity + register layout. NUM_SLICE distinct
 * header matches (each {offset,mask,value}); NUM_SRULE rules over the slice
 * bits. Must match the RTL params (pwfpga_top_phase3 NUM_SLICE/NUM_SRULE). */
#define PWFPGA_NUM_SLICE            4u
#define PWFPGA_NUM_SRULE            8u
/* Slice config: write offset(@+0, low 16b), mask(@+4), value(@+8 commits). */
#define PWFPGA_SLICE_CFG_OFFSET(base, i)  ((base) + (i) * 16u + 0u)
#define PWFPGA_SLICE_CFG_MASK(base, i)    ((base) + (i) * 16u + 4u)
#define PWFPGA_SLICE_CFG_VALUE(base, i)   ((base) + (i) * 16u + 8u)
/* Rule: write word0(@+0), then local_flow_id(@+4 commits). word0 packs the
 * care mask, action, egress, priority + enable: */
#define PWFPGA_SRULE_WORD0(base, i)       ((base) + (i) * 8u + 0u)
#define PWFPGA_SRULE_LFID(base, i)        ((base) + (i) * 8u + 4u)
#define PWFPGA_SRULE_W0(care, action, egress, prio, enable)            \
    (((uint32_t)(care)   & 0xFFu)        |                             \
     (((uint32_t)(action) & 0x7u)  << 8) |                             \
     (((uint32_t)(egress) & 0xFu)  << 11)|                             \
     (((uint32_t)(prio)   & 0xFFu) << 15)|                             \
     ((enable) ? (1u << 31) : 0u))

/* global_control bits */
enum {
    PWFPGA_GCTL_ENABLE          = 1u << 0,
    PWFPGA_GCTL_ARM             = 1u << 1,
    PWFPGA_GCTL_RESET_COUNTERS  = 1u << 2,
};

/* global_status bits */
enum {
    PWFPGA_GSTAT_READY    = 1u << 0,
    PWFPGA_GSTAT_ARMED    = 1u << 1,
    PWFPGA_GSTAT_RUNNING  = 1u << 2,
    PWFPGA_GSTAT_ERROR    = 1u << 3,
    PWFPGA_GSTAT_DEGRADED = 1u << 4,
};

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
} __attribute__((packed));

enum pwfpga_encap_type {
    PWFPGA_ENCAP_NONE    = 0,
    PWFPGA_ENCAP_IPIP    = 1,
    PWFPGA_ENCAP_GRE     = 2,
    PWFPGA_ENCAP_ETHERIP = 3,
};
enum pwfpga_rx_expect { PWFPGA_RX_INNER = 0, PWFPGA_RX_TUNNELED = 1 };

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

/* Slow-path DMA descriptor (Phase 2+). */
struct pwfpga_dma_desc {
    uint64_t addr;
    uint32_t len;
    uint32_t logical_if_id;
    uint16_t flags;
    uint16_t reserved;
} __attribute__((packed));

/* Slow-path DMA completion. */
struct pwfpga_dma_cpl {
    uint32_t desc_index;
    uint32_t actual_len;
    uint64_t timestamp;
    uint32_t status;
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
 * Configuration (classifier / flow tables) is preserved. */
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
 * larger than the buffer (2 KB) are dropped and flagged in STATUS. */
#define PWFPGA_WIN_PUNT_RX                 0x1000u
#define PWFPGA_REG_PUNT_STATUS             (PWFPGA_WIN_PUNT_RX + 0x000u) /* R:[0]frame_valid [1]overflow */
#define PWFPGA_REG_PUNT_INFO               (PWFPGA_WIN_PUNT_RX + 0x004u) /* R:[13:0]byte_len [19:16]ingress_port */
#define PWFPGA_REG_PUNT_LIF                (PWFPGA_WIN_PUNT_RX + 0x008u) /* R: logical_if_id */
#define PWFPGA_REG_PUNT_POP                (PWFPGA_WIN_PUNT_RX + 0x00Cu) /* W:1 -> release current frame */
#define PWFPGA_PUNT_DATA                   (PWFPGA_WIN_PUNT_RX + 0x010u) /* R: frame word i at +i*4, LE */
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
 * 0x0D00 region (below the punt window). */
#define PWFPGA_WIN_INJECT_TX               0x0D00u
#define PWFPGA_REG_INJECT_CTRL             (PWFPGA_WIN_INJECT_TX + 0x000u) /* W:[0]go  R:[0]busy */
#define PWFPGA_REG_INJECT_INFO             (PWFPGA_WIN_INJECT_TX + 0x004u) /* W:[13:0]byte_len [19:16]egress_port */
#define PWFPGA_INJECT_DATA                 (PWFPGA_WIN_INJECT_TX + 0x040u) /* W: frame word i at +i*4, LE */
#define PWFPGA_INJECT_MAX_FRAME            512u
#define PWFPGA_INJECT_CTRL_GO              (1u << 0)
#define PWFPGA_INJECT_STATUS_BUSY          (1u << 0)
#define PWFPGA_INJECT_INFO_EGRESS_SHIFT    16u

/* Magic written to PWFPGA_REG_REBOOT to trigger in-band reconfiguration
 * (ICAP IPROG -> reload bitstream from flash). "RBOT". */
#define PWFPGA_REBOOT_MAGIC                0x52424F54u

#endif
