/* PacketWyrm TCP SYN generator (slow-path inject).
 *
 * Reuses the existing slow-path TX inject path (slow_path_tx): the host
 * composes a complete Ethernet/IPv4/TCP-SYN frame -- including the IPv4 header
 * checksum and the TCP checksum (over the pseudo-header) computed in software --
 * and the FPGA emits it verbatim out an egress port. No test header, so these
 * frames are not loss/latency-measured; they are raw protocol traffic (e.g. to
 * elicit SYN-ACKs from a DUT, or a low-rate SYN flood with randomized
 * src ip/port + sequence per packet).
 *
 * This is the slow path: one frame per CSR write sequence + GO (tens of k pps,
 * not line rate). A line-rate TCP generator would need the streaming generator
 * (pw_flow_gen_multi) to emit a TCP header -- a separate RTL change.
 *
 *   sudo pw_tcp_syn <bdf> [count] [dst_ip] [dst_port] [egress]
 *     count    packets to send (default 16)
 *     dst_ip   dotted-quad (default 192.0.2.2)
 *     dst_port TCP dst port (default 80)
 *     egress   local egress port (default 1 -> p1, the loopback rig's source)
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>

#include "packetwyrm/backend.h"
#include "packetwyrm/vfio.h"
#include "packetwyrm/csr.h"

static void set_mac(uint8_t *d, uint64_t v) {
    for (int i = 0; i < 6; i++) d[i] = (uint8_t)(v >> (8 * (5 - i)));
}
static void be16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void be32(uint8_t *p, uint32_t v) { p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v; }

/* Standard internet 16-bit ones-complement checksum over a byte range. */
static uint16_t ones_csum(const uint8_t *p, size_t n, uint32_t seed) {
    uint32_t s = seed;
    for (size_t i = 0; i + 1 < n; i += 2) s += (uint32_t)(p[i] << 8) | p[i + 1];
    if (n & 1) s += (uint32_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
    return (uint16_t)~s;
}

/* xorshift32 -- per-packet variation without libc rand() global state. */
static uint32_t xs(uint32_t *st) { uint32_t x=*st; x^=x<<13; x^=x>>17; x^=x<<5; return *st=x; }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <bdf> [count] [dst_ip] [dst_port] [egress]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    /* Validated arg parsing: a misformed IP/port/egress would otherwise wrap or
     * silently send to the wrong target (these frames go on the wire). */
    long count = 16;
    if (argc >= 3) {
        char *e; count = strtol(argv[2], &e, 0);
        if (*e || count < 1 || count > 100000000L) { fprintf(stderr, "bad count\n"); return 2; }
    }
    uint32_t dst_ip = 0xC0000202u;  /* 192.0.2.2 */
    if (argc >= 4) {
        struct in_addr a;
        if (inet_pton(AF_INET, argv[3], &a) != 1) { fprintf(stderr, "bad dst_ip\n"); return 2; }
        dst_ip = ntohl(a.s_addr);
    }
    uint16_t dst_port = 80;
    if (argc >= 5) {
        char *e; unsigned long p = strtoul(argv[4], &e, 0);
        if (*e || p > 65535u) { fprintf(stderr, "bad dst_port (0..65535)\n"); return 2; }
        dst_port = (uint16_t)p;
    }
    uint8_t egress = 1;
    if (argc >= 6) {
        char *e; unsigned long g = strtoul(argv[5], &e, 0);
        if (*e || g > 255u) { fprintf(stderr, "bad egress (0..255)\n"); return 2; }
        egress = (uint8_t)g;
    }

    pw_vfio_bind(bdf);
    struct pw_card_backend be;
    if (pw_bar_backend_open(bdf, &be) != PW_OK) { fprintf(stderr, "backend open failed\n"); return 1; }
    const struct pw_card_backend_ops *o = be.ops;
    if (!o->slow_path_tx) { fprintf(stderr, "backend lacks slow_path_tx\n"); return 1; }

    printf("TCP SYN x%d -> %u.%u.%u.%u:%u out egress %u (slow-path inject)\n",
           count, (dst_ip>>24)&0xff,(dst_ip>>16)&0xff,(dst_ip>>8)&0xff,dst_ip&0xff,
           dst_port, egress);

    uint32_t st = 0x12345678u ^ (uint32_t)dst_ip ^ ((uint32_t)dst_port << 16);
    int sent = 0, failed = 0;
    for (int i = 0; i < count; i++) {
        /* Per-packet variation (SYN-flood realism): random src ip/port + seq. */
        uint32_t src_ip   = 0x0A000000u | (xs(&st) & 0x00FFFFFFu);   /* 10.x.x.x */
        uint16_t src_port = (uint16_t)(1024 + (xs(&st) % 64512u));
        uint32_t seq      = xs(&st);

        uint8_t f[54]; memset(f, 0, sizeof f);
        /* Ethernet */
        set_mac(&f[0], 0x02a50200beefULL);                 /* dst mac (DUT) */
        set_mac(&f[6], 0x02a502000001ULL);                 /* src mac */
        be16(&f[12], 0x0800);                              /* IPv4 */
        /* IPv4 (20 bytes) */
        uint8_t *ip = &f[14];
        ip[0] = 0x45; ip[1] = 0x00;
        be16(&ip[2], 40);                                  /* total len = 20 IP + 20 TCP */
        be16(&ip[4], (uint16_t)(seq & 0xFFFF));            /* id (varies) */
        ip[6] = 0x40; ip[7] = 0x00;                        /* DF */
        ip[8] = 64; ip[9] = 6;                             /* ttl, proto = TCP */
        be32(&ip[12], src_ip);
        be32(&ip[16], dst_ip);
        be16(&ip[10], ones_csum(ip, 20, 0));               /* IPv4 header checksum */
        /* TCP (20 bytes), SYN */
        uint8_t *tcp = &f[34];
        be16(&tcp[0], src_port);
        be16(&tcp[2], dst_port);
        be32(&tcp[4], seq);                                /* seq */
        be32(&tcp[8], 0);                                  /* ack = 0 */
        tcp[12] = 0x50;                                    /* data offset 5 (20B), no opts */
        tcp[13] = 0x02;                                    /* flags = SYN */
        be16(&tcp[14], 64240);                             /* window */
        be16(&tcp[18], 0);                                 /* urgent ptr */
        /* TCP checksum over pseudo-header (src,dst,zero,proto,tcp_len) + TCP. */
        uint8_t pseudo[12];
        be32(&pseudo[0], src_ip); be32(&pseudo[4], dst_ip);
        pseudo[8] = 0; pseudo[9] = 6; be16(&pseudo[10], 20);
        uint32_t seed = 0;
        for (int k = 0; k < 12; k += 2) seed += (uint32_t)(pseudo[k] << 8) | pseudo[k+1];
        be16(&tcp[16], ones_csum(tcp, 20, seed));          /* csum field was 0 */

        pw_status r = o->slow_path_tx(be.ctx, f, sizeof f, 0, egress);
        if (r == PW_OK) sent++; else { failed++;
            if (failed <= 3) fprintf(stderr, "  inject %d failed: %d\n", i, (int)r); }
    }

    printf("RESULT: sent=%d failed=%d\n", sent, failed);
    pw_card_backend_close(&be);
    return failed ? 1 : 0;
}
