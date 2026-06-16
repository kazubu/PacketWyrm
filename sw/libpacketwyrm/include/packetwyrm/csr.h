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

    PWFPGA_REG_PORT0_BASE           = 0x0200,
    PWFPGA_REG_PORT1_BASE           = 0x0300,
    PWFPGA_REG_PORT_STRIDE          = 0x0100,

    /* Wide map for 64 flows / 64 classifier rows. Commit-bearing
     * windows are 16 KB apart (8 KB data + commit reg above it); the
     * live-read histogram gets 8 KB. Fills the 64 KB BAR; the former
     * SLOW_RX/TX placeholders (0x8000/0x9000) are reclaimed. */
    PWFPGA_WIN_CLASSIFIER           = 0x2000,  /* 0x2000..0x5FFF */
    PWFPGA_WIN_FLOW_TABLE           = 0x6000,  /* 0x6000..0x9FFF */
    PWFPGA_WIN_HISTOGRAM            = 0xA000,  /* 0xA000..0xBFFF (8 KB) */
    PWFPGA_WIN_STATS_SNAPSHOT       = 0xC000,  /* 0xC000..0xFFFF */
};

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
    struct pwfpga_match_key key;
    struct pwfpga_match_key mask;
    uint32_t logical_if_id;
    uint32_t local_flow_id;
    uint8_t  action;     /* enum pwfpga_action */
    uint8_t  priority;   /* lower numbers win */
    uint16_t flags;      /* PWFPGA_CLS_FLAG_* */
} __attribute__((packed));

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
} __attribute__((packed));

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
#define PWFPGA_FLOW_STRIDE             128u
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

/* Magic written to PWFPGA_REG_REBOOT to trigger in-band reconfiguration
 * (ICAP IPROG -> reload bitstream from flash). "RBOT". */
#define PWFPGA_REBOOT_MAGIC                0x52424F54u

#endif
