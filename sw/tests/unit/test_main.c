/* libpacketwyrm Phase 0 unit tests.
 *
 * No external test framework: a tiny xunit-style runner keeps the
 * build dependency surface minimal. Each test is a void function that
 * asserts via PW_ASSERT macros and counts failures. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        int before = g_fail;
        cases[i].fn();
        printf("  %-40s %s\n", cases[i].name, g_fail == before ? "ok" : "FAIL");
    }
    printf("%d/%d assertions passed, %d failed\n", g_total - g_fail, g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
