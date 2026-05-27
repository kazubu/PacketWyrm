/* libpacketwyrm Phase 0 unit tests.
 *
 * No external test framework: a tiny xunit-style runner keeps the
 * build dependency surface minimal. Each test is a void function that
 * asserts via PW_ASSERT macros and counts failures. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "packetwyrm/packetwyrm.h"

static int g_fail = 0;
static int g_total = 0;

#define PW_ASSERT(cond) do { \
    g_total++; \
    if (!(cond)) { \
        g_fail++; \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

#define PW_ASSERT_EQ(a, b) do { \
    g_total++; \
    long long _a = (long long)(a), _b = (long long)(b); \
    if (_a != _b) { \
        g_fail++; \
        fprintf(stderr, "FAIL: %s:%d: %s == %s (%lld vs %lld)\n", \
                __FILE__, __LINE__, #a, #b, _a, _b); \
    } \
} while (0)

#define PW_ASSERT_STR_EQ(a, b) do { \
    g_total++; \
    const char *_a = (a), *_b = (b); \
    if (!_a || !_b || strcmp(_a, _b)) { \
        g_fail++; \
        fprintf(stderr, "FAIL: %s:%d: %s == %s (\"%s\" vs \"%s\")\n", \
                __FILE__, __LINE__, #a, #b, _a ? _a : "(null)", _b ? _b : "(null)"); \
    } \
} while (0)

static const char *cfg_single_card =
"system:\n"
"  name: pw-single\n"
"  mode: multi-card\n"
"  default_speed: 10g\n"
"cards:\n"
"  - id: 0\n"
"    pci: \"0000:03:00.0\"\n"
"    ports:\n"
"      - { local_port: 0, global_port: 0 }\n"
"      - { local_port: 1, global_port: 1 }\n"
"logical_interfaces:\n"
"  - id: 1000\n"
"    global_port: 0\n"
"    vlan: 100\n"
"    mac: \"02:a5:02:00:00:64\"\n"
"    punt: { arp: true, icmp: true }\n"
"flows:\n"
"  - id: 1\n"
"    name: same-card\n"
"    tx_global_port: 0\n"
"    rx_global_port: 1\n"
"    logical_if_id: 1000\n"
"    l2:\n"
"      src_mac: \"02:a5:02:00:00:01\"\n"
"      dst_mac: \"02:a5:02:00:00:02\"\n"
"      vlan: 100\n"
"    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
"    udp:  { src_port: 49152, dst_port: 50001 }\n"
"    traffic:\n"
"      frame_len: 512\n"
"      rate_bps: 1000000000\n"
"    measurements: { loss: true, latency: true, jitter: true }\n";

static const char *cfg_dual_cross_card_with_latency =
"system: { name: pw-dual, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - id: 0\n"
"    pci: \"0000:03:00.0\"\n"
"    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
"  - id: 1\n"
"    pci: \"0000:04:00.0\"\n"
"    ports: [ { local_port: 0, global_port: 2 }, { local_port: 1, global_port: 3 } ]\n"
"flows:\n"
"  - id: 7\n"
"    tx_global_port: 0\n"
"    rx_global_port: 2\n"
"    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:02:00:01\" }\n"
"    ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" }\n"
"    udp:  { src_port: 49153, dst_port: 50002 }\n"
"    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
"    measurements: { loss: true, latency: true }\n";

static const char *cfg_dup_card =
"system: { name: pw, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - { id: 0, pci: \"0000:03:00.0\", ports: [ { local_port: 0, global_port: 0 } ] }\n"
"  - { id: 0, pci: \"0000:04:00.0\", ports: [ { local_port: 0, global_port: 1 } ] }\n";

static const char *cfg_dup_gport =
"system: { name: pw, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - id: 0\n"
"    pci: \"0000:03:00.0\"\n"
"    ports: [ { local_port: 0, global_port: 5 }, { local_port: 1, global_port: 5 } ]\n";

static const char *cfg_unknown_gport_in_flow =
"system: { name: pw, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - id: 0\n"
"    pci: \"0000:03:00.0\"\n"
"    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
"flows:\n"
"  - id: 1\n"
"    tx_global_port: 0\n"
"    rx_global_port: 9\n"
"    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
"    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
"    udp:  { src_port: 1, dst_port: 2 }\n"
"    traffic: { frame_len: 64, rate_bps: 1 }\n";

static void test_tap_name(void) {
    char buf[64];
    int n = pw_tap_name(buf, sizeof(buf), 0, 100);
    PW_ASSERT(n > 0);
    PW_ASSERT_STR_EQ(buf, "tap-pw-p0-v100");
    n = pw_tap_name(buf, sizeof(buf), 3, 0);
    PW_ASSERT_STR_EQ(buf, "tap-pw-p3-v0");
}

static void test_parse_single_card(void) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_single_card, strlen(cfg_single_card), cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    PW_ASSERT_EQ(cfg->n_cards, 1);
    PW_ASSERT_EQ(cfg->cards[0].n_ports, 2);
    PW_ASSERT_EQ(cfg->n_logical_if, 1);
    PW_ASSERT_EQ(cfg->logical_if[0].id, 1000);
    PW_ASSERT(cfg->logical_if[0].punt.arp);
    PW_ASSERT(!cfg->logical_if[0].punt.bgp);
    PW_ASSERT_EQ(cfg->n_flows, 1);

    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);

    struct pw_program *prog = pw_program_new();
    r = pw_flow_compile(cfg, prog, &d);
    PW_ASSERT_EQ(r, PW_OK);
    PW_ASSERT_EQ(prog->n_cards, 1);
    PW_ASSERT_EQ(prog->per_card[0].n_flow_rows, 1);
    PW_ASSERT(prog->per_card[0].n_classifier_rows >= 1);
    PW_ASSERT_EQ(prog->flow_meta[0].latency_valid, 1);

    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_reject_cross_card_latency(void) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_dual_cross_card_with_latency,
                                         strlen(cfg_dual_cross_card_with_latency),
                                         cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_E_CROSS_CARD_LATENCY);
    PW_ASSERT(strstr(d.path, "flows[0].measurements.latency") != NULL);
    pw_config_free(cfg);
}

static void test_reject_dup_card(void) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_dup_card, strlen(cfg_dup_card), cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_E_DUP_CARD_ID);
    pw_config_free(cfg);
}

static void test_reject_dup_gport(void) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_dup_gport, strlen(cfg_dup_gport), cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_E_DUP_GLOBAL_PORT);
    pw_config_free(cfg);
}

static void test_reject_unknown_gport_in_flow(void) {
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_unknown_gport_in_flow,
                                         strlen(cfg_unknown_gport_in_flow),
                                         cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_E_UNKNOWN_GLOBAL_PORT);
    pw_config_free(cfg);
}

static void test_resolve_port_multi_card(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "  - id: 1\n"
        "    pci: \"0000:04:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 2 }, { local_port: 1, global_port: 3 } ]\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pwfpga_port_ref ref;
    PW_ASSERT_EQ(pw_config_resolve_port(cfg, 2, &ref), PW_OK);
    PW_ASSERT_EQ(ref.card_id, 1);
    PW_ASSERT_EQ(ref.local_port_id, 0);
    PW_ASSERT_EQ(pw_config_resolve_port(cfg, 99, &ref), PW_E_UNKNOWN_GLOBAL_PORT);
    pw_config_free(cfg);
}

static void test_cross_card_flow_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "  - id: 1\n"
        "    pci: \"0000:04:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 2 }, { local_port: 1, global_port: 3 } ]\n"
        "flows:\n"
        "  - id: 9\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 2\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:02:00:01\" }\n"
        "    ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" }\n"
        "    udp:  { src_port: 49153, dst_port: 50002 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    measurements: { loss: true }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    PW_ASSERT_EQ(prog->n_cards, 2);
    PW_ASSERT_EQ(prog->flow_meta[0].latency_valid, 0);
    /* Both cards should have at least one row for this single flow. */
    PW_ASSERT_EQ(prog->per_card[0].n_flow_rows, 1);
    PW_ASSERT_EQ(prog->per_card[1].n_flow_rows, 1);
    PW_ASSERT(prog->per_card[1].n_classifier_rows >= 1);
    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_fake_backend(void) {
    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);
    struct pw_card_info info = {0};
    PW_ASSERT_EQ(b.ops->card_info(b.ctx, &info), PW_OK);
    PW_ASSERT_EQ(info.device_id, 0xA502BEEF);
    PW_ASSERT(info.num_local_flows > 0);
    struct pwfpga_flow_config f = { .global_flow_id = 42, .local_flow_id = 0, .tx_enable = 1 };
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, 0, &f), PW_OK);
    PW_ASSERT_EQ(b.ops->flow_commit(b.ctx), PW_OK);
    pw_card_backend_close(&b);
}

static void test_bar_backend_path(void) {
    /* Stage a 64K "BAR image" with the identity registers populated
     * exactly as the FPGA would. The path-variant BAR backend mmaps
     * it and the test inspects what card_info() reads back. */
    char path[] = "/tmp/pw_bar_test_XXXXXX";
    int fd = mkstemp(path);
    PW_ASSERT(fd >= 0);
    if (fd < 0) return;
    PW_ASSERT_EQ(ftruncate(fd, 65536), 0);

    uint32_t hdr[10] = {0};
    hdr[0] = 0xA502BEEF;   /* device_id */
    hdr[1] = 0x00010000;   /* version */
    hdr[2] = 0xFACE0001;   /* build_id */
    hdr[3] = 0xDEADBEEF;   /* git_hash */
    hdr[4] = 0x00000004;   /* capabilities = HAS_HISTOGRAM */
    hdr[5] = 2;            /* num_local_ports */
    hdr[6] = 64;           /* num_local_flows */
    hdr[7] = 32;           /* num_logical_ifs */
    hdr[8] = 128;          /* num_classifier */
    hdr[9] = 64;           /* num_hist_bins */
    PW_ASSERT_EQ(pwrite(fd, hdr, sizeof(hdr), 0), (ssize_t)sizeof(hdr));
    close(fd);

    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_bar_backend_open_path(path, &b), PW_OK);
    struct pw_card_info info = {0};
    PW_ASSERT_EQ(b.ops->card_info(b.ctx, &info), PW_OK);
    PW_ASSERT_EQ(info.device_id,    0xA502BEEF);
    PW_ASSERT_EQ(info.version,      0x00010000);
    PW_ASSERT_EQ(info.capabilities, 0x4);
    PW_ASSERT_EQ(info.num_local_ports, 2);
    PW_ASSERT_EQ(info.num_local_flows, 64);

    /* read32 / write32 should round-trip through the mmap. */
    uint32_t v = 0;
    PW_ASSERT_EQ(b.ops->write32(b.ctx, PWFPGA_REG_GLOBAL_CONTROL, 0xC0FFEE01), PW_OK);
    PW_ASSERT_EQ(b.ops->read32 (b.ctx, PWFPGA_REG_GLOBAL_CONTROL, &v), PW_OK);
    PW_ASSERT_EQ(v, 0xC0FFEE01);

    /* Table windows are honest about not being implemented yet. */
    struct pwfpga_flow_config f = {0};
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, 0, &f), PW_E_NOT_IMPLEMENTED);

    pw_card_backend_close(&b);
    unlink(path);
}

static void test_pci_discover_no_match(void) {
    /* Searching for an obviously fake vendor returns 0 cleanly and
     * does not crash whether /sys/bus/pci exists or not. */
    int n = pw_pci_discover(0xBAD1, 0xBAD2, NULL, 0);
    PW_ASSERT(n >= 0);  /* 0 on no match, or PW_E_IO on hosts without sysfs */
    PW_ASSERT(n == 0);
}

static void test_fake_backend_slow_path(void) {
    /* End-to-end punt: inject -> slow_path_rx returns it. */
    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);

    const uint8_t frame[] = { 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe };
    PW_ASSERT_EQ(pw_fake_backend_inject_punt(&b, 1000, frame, sizeof(frame)),
                 PW_OK);

    uint8_t got[64] = {0};
    uint32_t lif = 0;
    int n = b.ops->slow_path_rx(b.ctx, got, sizeof(got), &lif);
    PW_ASSERT_EQ(n, (int)sizeof(frame));
    PW_ASSERT_EQ(lif, 1000);
    PW_ASSERT(memcmp(frame, got, sizeof(frame)) == 0);

    /* End-to-end TX: slow_path_tx pushes, drain_tx pops. */
    const uint8_t tx_frame[] = { 0x01, 0x02, 0x03 };
    PW_ASSERT_EQ(b.ops->slow_path_tx(b.ctx, tx_frame, sizeof(tx_frame), 2000, 1),
                 PW_OK);

    uint8_t drained[64] = {0};
    uint32_t drained_lif = 0;
    uint8_t drained_eg  = 0xff;
    int dn = pw_fake_backend_drain_tx(&b, drained, sizeof(drained),
                                       &drained_lif, &drained_eg);
    PW_ASSERT_EQ(dn, (int)sizeof(tx_frame));
    PW_ASSERT_EQ(drained_lif, 2000);
    PW_ASSERT_EQ(drained_eg, 1);
    PW_ASSERT(memcmp(tx_frame, drained, sizeof(tx_frame)) == 0);

    pw_card_backend_close(&b);
}

static void test_host_plane_socketpair(void) {
    /* Build a host plane on top of the fake backend; use a
     * socketpair as the stand-in TAP fd to verify the bridge
     * works in both directions. */
    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);

    struct pw_host_plane hp;
    PW_ASSERT_EQ(pw_host_plane_init(&hp, &b), PW_OK);

    int sp[2];
    PW_ASSERT(socketpair(AF_UNIX, SOCK_DGRAM, 0, sp) == 0);
    /* sp[0] acts as the "TAP fd" (host plane reads/writes it).
     * sp[1] is the test's "container" end. */

    PW_ASSERT_EQ(pw_host_plane_bind(&hp, /*lif=*/42, sp[0], /*egress=*/0),
                 PW_OK);

    /* Duplicate bind rejected. */
    int dup = -1;
    PW_ASSERT_EQ(pw_host_plane_bind(&hp, 42, dup, 0), PW_E_INVAL);
    /* Same lif on a different fd is also rejected. */
    PW_ASSERT_EQ(pw_host_plane_bind(&hp, 42, sp[0], 0), PW_E_DUP_LOGICAL_IF);

    /* punt: backend -> host plane -> sp[0] -> sp[1] */
    const uint8_t punt_frame[] = "PUNT FRAME";
    PW_ASSERT_EQ(pw_fake_backend_inject_punt(&b, 42, punt_frame,
                                              sizeof(punt_frame)), PW_OK);
    int moved = pw_host_plane_step(&hp, 4);
    PW_ASSERT_EQ(moved, 1);
    PW_ASSERT_EQ(hp.punt_to_tap_ok[0], 1);

    uint8_t rx_buf[64] = {0};
    ssize_t r = read(sp[1], rx_buf, sizeof(rx_buf));
    PW_ASSERT_EQ(r, (ssize_t)sizeof(punt_frame));
    PW_ASSERT(memcmp(punt_frame, rx_buf, sizeof(punt_frame)) == 0);

    /* Punt to an unknown lif is counted, not forwarded. */
    PW_ASSERT_EQ(pw_fake_backend_inject_punt(&b, 99, punt_frame,
                                              sizeof(punt_frame)), PW_OK);
    pw_host_plane_step(&hp, 4);
    PW_ASSERT_EQ(hp.punt_unknown_lif, 1);

    /* tap-inject: sp[1] -> sp[0] -> host plane -> backend TX FIFO */
    const uint8_t inj_frame[] = "INJECT FRAME";
    ssize_t w = write(sp[1], inj_frame, sizeof(inj_frame));
    PW_ASSERT_EQ(w, (ssize_t)sizeof(inj_frame));

    moved = pw_host_plane_step(&hp, 4);
    PW_ASSERT_EQ(moved, 1);
    PW_ASSERT_EQ(hp.tap_to_fpga_ok[0], 1);

    uint8_t drained[64] = {0};
    uint32_t drained_lif = 0;
    uint8_t  drained_eg  = 0;
    int dn = pw_fake_backend_drain_tx(&b, drained, sizeof(drained),
                                       &drained_lif, &drained_eg);
    PW_ASSERT_EQ(dn, (int)sizeof(inj_frame));
    PW_ASSERT_EQ(drained_lif, 42);
    PW_ASSERT(memcmp(inj_frame, drained, sizeof(inj_frame)) == 0);

    close(sp[1]);  /* host plane will close sp[0] when the FD is owned */
    close(sp[0]);
    pw_card_backend_close(&b);
}

static void test_host_plane_with_real_tap(void) {
    /* Combined end-to-end: host_plane bridges a punt frame to a
     * real Linux TAP device (whose fd we hold). The TAP doesn't
     * need to be brought up — write() on the FD always succeeds,
     * the kernel just discards packets if the link is down. The
     * test confirms the bridge writes the bytes and the host
     * plane's per-binding counter advances. */
    int tap_fd = -1;
    char tap_name[PW_TAP_IFNAME_MAX] = {0};
    pw_status r = pw_tap_open("pw-htest-%d", &tap_fd, tap_name);
    if (r != PW_OK) {
        printf("    (host_plane+TAP test skipped: no CAP_NET_ADMIN)\n");
        return;
    }
    /* Bring the device up so write() to its TAP fd is accepted by
     * the kernel; without IFF_UP the kernel returns -1 / EIO. */
    pw_tap_set_up(tap_name, true);

    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);
    struct pw_host_plane hp;
    PW_ASSERT_EQ(pw_host_plane_init(&hp, &b), PW_OK);
    PW_ASSERT_EQ(pw_host_plane_bind(&hp, /*lif=*/7777, tap_fd, /*egress=*/0),
                 PW_OK);

    const uint8_t arp_frame[] = {
        0xff,0xff,0xff,0xff,0xff,0xff,
        0x02,0xa5,0x02,0x00,0x00,0x01,
        0x08,0x06,
        0x00,0x01, 0x08,0x00, 0x06,0x04, 0x00,0x01,
        0x02,0xa5,0x02,0x00,0x00,0x01,
        0xc0,0x00,0x02,0x01,
        0xff,0xff,0xff,0xff,0xff,0xff,
        0xc0,0x00,0x02,0x02
    };
    PW_ASSERT_EQ(pw_fake_backend_inject_punt(&b, 7777, arp_frame,
                                              sizeof(arp_frame)), PW_OK);

    /* `moved` may exceed 1: after IFF_UP the kernel may emit its
     * own packets (IPv6 RS, etc.) which the host plane reads back
     * and counts as TAP->FPGA traffic. We just need the punt
     * direction to have moved one frame. */
    (void)pw_host_plane_step(&hp, 8);
    PW_ASSERT_EQ(hp.punt_to_tap_ok[0], 1);
    PW_ASSERT_EQ(hp.punt_to_tap_dropped[0], 0);

    pw_tap_close(tap_fd);
    pw_card_backend_close(&b);
}

static void test_tap_basic(void) {
    /* Tries to create a real TAP device; requires CAP_NET_ADMIN.
     * If permission is denied, the test logs and passes (so the
     * suite can run on locked-down hosts). */
    int fd = -1;
    char actual_name[PW_TAP_IFNAME_MAX] = {0};
    pw_status r = pw_tap_open("pw-test-%d", &fd, actual_name);
    if (r != PW_OK) {
        printf("    (TAP test skipped: no CAP_NET_ADMIN)\n");
        return;
    }
    PW_ASSERT(fd >= 0);
    PW_ASSERT(actual_name[0] != '\0');

    /* Verify the netdev appeared in sysfs. */
    char sys_path[128];
    snprintf(sys_path, sizeof(sys_path), "/sys/class/net/%s", actual_name);
    struct stat st;
    PW_ASSERT_EQ(stat(sys_path, &st), 0);

    /* Bring it up, set MAC + MTU. */
    uint8_t mac[6] = { 0x02, 0xa5, 0x02, 0xaa, 0xbb, 0xcc };
    PW_ASSERT_EQ(pw_tap_set_mac(actual_name, mac), PW_OK);
    PW_ASSERT_EQ(pw_tap_set_mtu(actual_name, 1500), PW_OK);
    PW_ASSERT_EQ(pw_tap_set_up(actual_name, true), PW_OK);

    pw_tap_close(fd);
    /* After fd close (no persist), the device should be gone. */
    if (stat(sys_path, &st) == 0) {
        printf("    (note: TAP %s still present after close)\n", actual_name);
    }
}

typedef void (*test_fn)(void);
struct test_case { const char *name; test_fn fn; };

int main(void) {
    struct test_case cases[] = {
        { "tap_name", test_tap_name },
        { "parse_single_card", test_parse_single_card },
        { "reject_cross_card_latency", test_reject_cross_card_latency },
        { "reject_dup_card", test_reject_dup_card },
        { "reject_dup_gport", test_reject_dup_gport },
        { "reject_unknown_gport_in_flow", test_reject_unknown_gport_in_flow },
        { "resolve_port_multi_card", test_resolve_port_multi_card },
        { "cross_card_flow_compiles", test_cross_card_flow_compiles },
        { "fake_backend", test_fake_backend },
        { "bar_backend_path", test_bar_backend_path },
        { "pci_discover_no_match", test_pci_discover_no_match },
        { "fake_backend_slow_path", test_fake_backend_slow_path },
        { "host_plane_socketpair", test_host_plane_socketpair },
        { "tap_basic", test_tap_basic },
        { "host_plane_with_real_tap", test_host_plane_with_real_tap },
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        int before = g_fail;
        cases[i].fn();
        printf("  %-40s %s\n", cases[i].name, g_fail == before ? "ok" : "FAIL");
    }
    printf("%d/%d assertions passed, %d failed\n", g_total - g_fail, g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
