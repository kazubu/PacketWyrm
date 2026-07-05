/* libpacketwyrm Phase 0 unit tests.
 *
 * No external test framework: a tiny xunit-style runner keeps the
 * build dependency surface minimal. Each test is a void function that
 * asserts via PW_ASSERT macros and counts failures. */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <json-c/json.h>

#include "packetwyrm/packetwyrm.h"
#include "packetwyrm/vfio.h"

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

/* Environment-only config (no flows) with a secret. */
static const char *cfg_env_only =
"system:\n"
"  name: pw-env\n"
"  mode: multi-card\n"
"  default_speed: 10g\n"
"  secret: s3cr3t\n"
"cards:\n"
"  - id: 0\n"
"    pci: \"0000:03:00.0\"\n"
"    ports:\n"
"      - { local_port: 0, global_port: 0 }\n"
"      - { local_port: 1, global_port: 1 }\n"
"logical_interfaces:\n"
"  - { id: 1000, global_port: 0, vlan: 100, mac: \"02:a5:02:00:00:64\", punt: { arp: true } }\n";

/* Test-only config (flows, no system/cards) -- references env ports/lif. */
static const char *cfg_test_only =
"flows:\n"
"  - id: 1\n"
"    name: t\n"
"    tx_global_port: 0\n"
"    rx_global_port: 1\n"
"    logical_if_id: 1000\n"
"    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\", vlan: 100 }\n"
"    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
"    udp:  { src_port: 49152, dst_port: 50001 }\n"
"    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
"    measurements: { loss: true, latency: true }\n";

static void test_config_split_env_test(void) {
    struct pw_diag d = {0};
    struct pw_config *env = pw_config_new();
    PW_ASSERT_EQ(pw_config_parse_string(cfg_env_only, strlen(cfg_env_only), env, &d), PW_OK);
    PW_ASSERT_EQ(env->n_cards, 1);
    PW_ASSERT_EQ(env->n_flows, 0);
    PW_ASSERT_STR_EQ(env->system.secret, "s3cr3t");

    /* test-only fails the default (env) parse (system/cards required) ... */
    struct pw_config *t0 = pw_config_new();
    PW_ASSERT(pw_config_parse_string(cfg_test_only, strlen(cfg_test_only), t0, &d) != PW_OK);
    pw_config_free(t0);

    /* ... but parses with PW_CFG_TEST_ONLY */
    struct pw_config *t = pw_config_new();
    PW_ASSERT_EQ(pw_config_parse_string_ex(cfg_test_only, strlen(cfg_test_only),
                                           PW_CFG_TEST_ONLY, t, &d), PW_OK);
    PW_ASSERT_EQ(t->n_cards, 0);
    PW_ASSERT_EQ(t->n_flows, 1);

    /* clone_env + attach test flows -> a valid, compilable merged config */
    struct pw_config *merged = pw_config_clone_env(env);
    PW_ASSERT(merged != NULL);
    PW_ASSERT_EQ(merged->n_cards, 1);
    PW_ASSERT_STR_EQ(merged->system.secret, "s3cr3t");
    merged->flows = t->flows; merged->n_flows = t->n_flows; t->flows = NULL; t->n_flows = 0;
    PW_ASSERT_EQ(pw_config_validate(merged, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(merged, prog, &d), PW_OK);
    PW_ASSERT(prog->per_card[0].n_flow_rows >= 1);

    pw_program_free(prog);
    pw_config_free(merged);
    pw_config_free(t);
    pw_config_free(env);
}

/* Two logical_ifs sharing an explicit name -- must be rejected (each maps to a
 * distinct TAP netdev). */
static const char *cfg_dup_lif_name =
"system:\n  name: e\n  mode: multi-card\n  default_speed: 10g\n"
"cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n    ports:\n"
"      - { local_port: 0, global_port: 0 }\n"
"      - { local_port: 1, global_port: 1 }\n"
"logical_interfaces:\n"
"  - { id: 1000, global_port: 0, name: eth0, mac: \"02:a5:02:00:00:64\" }\n"
"  - { id: 1001, global_port: 1, name: eth0, mac: \"02:a5:02:00:00:65\" }\n";

/* A logical_if name too long for a TAP netdev (>= IFNAMSIZ) -- must be rejected. */
static const char *cfg_long_lif_name =
"system:\n  name: e\n  mode: multi-card\n  default_speed: 10g\n"
"cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n    ports:\n"
"      - { local_port: 0, global_port: 0 }\n"
"logical_interfaces:\n"
"  - { id: 1000, global_port: 0, name: this-name-is-way-too-long, mac: \"02:a5:02:00:00:64\" }\n";

static void test_validate_lif_name_rules(void) {
    struct pw_diag d = {0};
    /* duplicate name -> rejected */
    struct pw_config *c1 = pw_config_new();
    pw_status r1 = pw_config_parse_string(cfg_dup_lif_name, strlen(cfg_dup_lif_name), c1, &d);
    if (r1 == PW_OK) r1 = pw_config_validate(c1, &d);
    PW_ASSERT(r1 != PW_OK);
    pw_config_free(c1);
    /* over-length name -> rejected */
    struct pw_config *c2 = pw_config_new();
    pw_status r2 = pw_config_parse_string(cfg_long_lif_name, strlen(cfg_long_lif_name), c2, &d);
    if (r2 == PW_OK) r2 = pw_config_validate(c2, &d);
    PW_ASSERT(r2 != PW_OK);
    pw_config_free(c2);
}

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

/* card1 receives flow 7 (cross-card, from card0) AND flow 8 (same-card,
 * card1->card1). Stage 2 per-flow lat_correction supports this (slot 7 gets the
 * offset, slot 8 stays 0). */
static const char *cfg_xcard_mixed_same_card =
"system: { name: pw-dual, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - { id: 0, pci: \"0000:03:00.0\", ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ] }\n"
"  - { id: 1, pci: \"0000:04:00.0\", ports: [ { local_port: 0, global_port: 2 }, { local_port: 1, global_port: 3 } ] }\n"
"flows:\n"
"  - { id: 7, tx_global_port: 0, rx_global_port: 2,\n"
"      l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:02:00:01\" },\n"
"      ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" },\n"
"      udp:  { src_port: 49153, dst_port: 50002 },\n"
"      traffic: { frame_len: 512, rate_bps: 1000000000 }, measurements: { latency: true } }\n"
"  - { id: 8, tx_global_port: 3, rx_global_port: 2,\n"
"      l2: { src_mac: \"02:a5:02:02:00:02\", dst_mac: \"02:a5:02:02:00:01\" },\n"
"      ipv4: { src: \"198.51.100.3\", dst: \"198.51.100.2\" },\n"
"      udp:  { src_port: 49154, dst_port: 50003 },\n"
"      traffic: { frame_len: 512, rate_bps: 1000000000 }, measurements: { latency: true } }\n";

/* card1 receives flow 7 from card0 and flow 8 from card2. Stage 2 per-flow
 * lat_correction supports this (each cross-card flow's slot gets its source
 * card's inter-card offset). */
static const char *cfg_xcard_two_tx_sources =
"system: { name: pw-tri, mode: multi-card, default_speed: 10g }\n"
"cards:\n"
"  - { id: 0, pci: \"0000:03:00.0\", ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ] }\n"
"  - { id: 1, pci: \"0000:04:00.0\", ports: [ { local_port: 0, global_port: 2 }, { local_port: 1, global_port: 3 } ] }\n"
"  - { id: 2, pci: \"0000:05:00.0\", ports: [ { local_port: 0, global_port: 4 }, { local_port: 1, global_port: 5 } ] }\n"
"flows:\n"
"  - { id: 7, tx_global_port: 0, rx_global_port: 2,\n"
"      l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:02:00:01\" },\n"
"      ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" },\n"
"      udp:  { src_port: 49153, dst_port: 50002 },\n"
"      traffic: { frame_len: 512, rate_bps: 1000000000 }, measurements: { latency: true } }\n"
"  - { id: 8, tx_global_port: 4, rx_global_port: 3,\n"
"      l2: { src_mac: \"02:a5:02:04:00:01\", dst_mac: \"02:a5:02:02:00:02\" },\n"
"      ipv4: { src: \"198.51.100.4\", dst: \"198.51.100.5\" },\n"
"      udp:  { src_port: 49155, dst_port: 50004 },\n"
"      traffic: { frame_len: 512, rate_bps: 1000000000 }, measurements: { latency: true } }\n";

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

/* pw_parse_u64 lives in the library's private scalar.c (not a public header);
 * declare it here to regression-test its input hardening (reject negatives /
 * overflow / empty), so a config like `rate_bps: -1` can't become a huge rate. */
bool pw_parse_u64(const char *s, uint64_t *out);

static void test_parse_u64_hardening(void) {
    uint64_t v = 0;
    PW_ASSERT(pw_parse_u64("1000", &v) && v == 1000);
    PW_ASSERT(pw_parse_u64("1_000_000", &v) && v == 1000000);
    PW_ASSERT(pw_parse_u64("0x10", &v) && v == 16);
    PW_ASSERT(!pw_parse_u64("-1", &v));      /* negative -> reject (no silent wrap) */
    PW_ASSERT(!pw_parse_u64("+5", &v));      /* leading + -> reject */
    PW_ASSERT(!pw_parse_u64("", &v));        /* empty -> reject */
    PW_ASSERT(!pw_parse_u64("___", &v));     /* underscores only -> reject */
    PW_ASSERT(!pw_parse_u64("12x", &v));     /* trailing junk -> reject */
    PW_ASSERT(!pw_parse_u64("99999999999999999999999999", &v)); /* ERANGE overflow */
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
    PW_ASSERT(prog->per_card[0].n_map_entries >= 1);   /* test flow -> flow-id map */
    PW_ASSERT_EQ(prog->flow_meta[0].latency_valid, 1);

    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_accept_cross_card_latency(void) {
    /* Cross-card latency/jitter is now accepted: the daemon offset-corrects it
     * via the J5 GPIO time-sync (jitter cancels the inter-card offset). Validation
     * must pass; the J5 wiring is a hardware concern outside the config. */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_dual_cross_card_with_latency,
                                         strlen(cfg_dual_cross_card_with_latency),
                                         cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    pw_config_free(cfg);
}

static void test_accept_xcard_mixed_same_card(void) {
    /* Stage 2 per-flow lat_correction: same-card + cross-card on one RX card is
     * now supported (each flow's slot gets its own correction). */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_xcard_mixed_same_card,
                                         strlen(cfg_xcard_mixed_same_card), cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    pw_config_free(cfg);
}

static void test_accept_xcard_two_tx_sources(void) {
    /* Stage 2 per-flow lat_correction: one RX card fed by two TX cards is now
     * supported (each cross-card flow's slot gets its source's offset). */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(cfg_xcard_two_tx_sources,
                                         strlen(cfg_xcard_two_tx_sources), cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
    r = pw_config_validate(cfg, &d);
    PW_ASSERT_EQ(r, PW_OK);
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

/* Parse a single-flow config whose `traffic:` block is the given line; return
 * the parse status. Used by the frame-length / rate validation tests. */
static pw_status parse_with_traffic(const char *traffic_line) {
    char yaml[768];
    snprintf(yaml, sizeof(yaml),
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n  - id: 1\n    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 1, dst_port: 2 }\n"
        "    traffic: { %s }\n", traffic_line);
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    pw_status r = pw_config_parse_string(yaml, strlen(yaml), cfg, &d);
    pw_config_free(cfg);
    return r;
}

static void test_traffic_validation(void) {
    /* Valid: fixed size + rate_bps; range + rate_pps. */
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, rate_bps: 1000000000"), PW_OK);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, rate_pps: 100000"), PW_OK);
    PW_ASSERT_EQ(parse_with_traffic("frame_len_min: 64, frame_len_max: 1518, rate_bps: 1"), PW_OK);
    /* rate: neither and both are rejected. */
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, rate_bps: 1, rate_pps: 1"), PW_E_INVAL);
    /* frame length: fixed+range exclusivity, range ordering, out-of-range. */
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, frame_len_min: 64, frame_len_max: 128, rate_bps: 1"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, frame_len_max: 1518, rate_bps: 1"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 512, frame_len_step: 4, rate_bps: 1"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len_min: 1000, frame_len_max: 128, rate_bps: 1"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 9000, rate_bps: 1"), PW_E_INVAL);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 32, rate_bps: 1"), PW_E_INVAL);
    /* 60 = smallest pre-FCS L2 frame (60 + 4 FCS = 64 B on the wire, the 64-byte
     * line-rate point); 59 is below the Ethernet minimum. */
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 60, rate_bps: 1"), PW_OK);
    PW_ASSERT_EQ(parse_with_traffic("frame_len: 59, rate_bps: 1"), PW_E_INVAL);
}

/* rate_pps must compile to a non-zero token rate (else the flow never TX). */
static void test_rate_pps_compiles_nonzero(void) {
    char yaml[768];
    snprintf(yaml, sizeof(yaml),
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n  - id: 1\n    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 1, dst_port: 2 }\n"
        "    traffic: { frame_len: 512, rate_pps: 100000 }\n");
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    /* TX row 0 must have a non-zero token rate (pps x frame bytes). */
    PW_ASSERT(prog->per_card[0].n_flow_rows > 0);
    PW_ASSERT(prog->per_card[0].flow_rows[0].tokens_per_tick_fp != 0);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* A sub-minimum frame length is clamped to the legal minimum for the token
 * bucket: IPv4/UDP min = 14+20+8+32 = 74 B. A 64 B request must yield a 74 B
 * bucket cap (else cap < frame cost and the flow never transmits). */
static void test_min_legal_frame_clamp(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n  - id: 1\n    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 1, dst_port: 2 }\n"
        "    traffic: { frame_len: 64, rate_pps: 100000 }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *fr = &prog->per_card[0].flow_rows[0];
    /* cap clamped up to the 74 B min legal (not the configured 64); no 2-frame
     * floor -- the generator primes the active slot's pipeline through its own
     * emit, so a cap=1 (burst=1) small-frame flow still sustains line rate. */
    PW_ASSERT_EQ(fr->burst_bytes, 74);
    PW_ASSERT(fr->tokens_per_tick_fp != 0);   /* pps metered against >= 74 B */
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Punt narrowing: BGP -> TCP/179 (two rules, dst+src), IS-IS -> LLC UDF
 * (not a catch-all). Regression for "slow path swallows normal TCP". */
static void test_punt_narrowing(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 } ]\n"
        "logical_interfaces:\n  - id: 1000\n    global_port: 0\n"
        "    mac: \"02:a5:02:00:00:64\"\n"
        "    punt: { bgp: true, is_is: true }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pw_card_program *cp = &prog->per_card[0];
    /* BGP emits two PUNT rules (dst:179 and src:179); IS-IS one. */
    PW_ASSERT_EQ(cp->n_fc_rules, 3);
    /* A TCP dst-port-179 and a src-port-179 comparator must exist. */
    int have_dst179 = 0, have_src179 = 0;
    for (size_t i = 0; i < cp->n_fc_cmps; i++) {
        if (cp->fc_cmps[i].src == PWFPGA_FC_SRC_L4_DST && cp->fc_cmps[i].value == 179) have_dst179 = 1;
        if (cp->fc_cmps[i].src == PWFPGA_FC_SRC_L4_SRC && cp->fc_cmps[i].value == 179) have_src179 = 1;
    }
    PW_ASSERT(have_dst179 && have_src179);
    /* IS-IS uses an LLC DSAP/SSAP (0xFEFE) UDF, not a bare-ingress catch-all. */
    int have_isis_udf = 0;
    for (size_t i = 0; i < cp->n_fc_udfs; i++)
        if (cp->fc_udfs[i].value == 0xFEFE0000u && cp->fc_udfs[i].mask == 0xFFFF0000u) have_isis_udf = 1;
    PW_ASSERT(have_isis_udf);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Find the field-comparator index for a {src,value} (mask ignored); -1 if none. */
static int fc_cmp_bit(const struct pw_card_program *cp, uint8_t src, uint32_t value) {
    for (size_t i = 0; i < cp->n_fc_cmps; i++)
        if (cp->fc_cmps[i].src == src && cp->fc_cmps[i].value == value) return (int)i;
    return -1;
}
/* True if some PUNT rule's care-mask includes ALL the given comparator bits. */
static int fc_rule_has_bits(const struct pw_card_program *cp, uint16_t bits) {
    for (size_t i = 0; i < cp->n_fc_rules; i++)
        if ((cp->fc_rules[i].care & bits) == bits) return 1;
    return 0;
}

/* ipv6_nd=true enables the IPv6 control plane: it must punt ICMPv6 ND AND the
 * IPv6 variants of ospf/bgp (OSPFv3 = 0x86DD+proto89, BGP-v6 = 0x86DD+TCP/179),
 * sharing the 0x86DD ethertype + proto/L4 comparators with the IPv4 rules. With
 * ipv6_nd=false, none of the IPv6 rules (nor a 0x86DD/proto58 comparator) appear. */
static void test_punt_ipv6(void) {
    const char *yaml6 =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 } ]\n"
        "logical_interfaces:\n  - id: 1000\n    global_port: 0\n"
        "    mac: \"02:a5:02:00:00:64\"\n"
        "    punt: { ipv6_nd: true, ospf: true, bgp: true }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml6, strlen(yaml6), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pw_card_program *cp = &prog->per_card[0];
    /* rules: ND(1) + OSPFv2(1)+OSPFv3(1) + BGPv4(2)+BGPv6(2) = 7 */
    PW_ASSERT_EQ(cp->n_fc_rules, 7);
    int eth6 = fc_cmp_bit(cp, PWFPGA_FC_SRC_ETHERTYPE, 0x86DD);
    int p89  = fc_cmp_bit(cp, PWFPGA_FC_SRC_L3_PROTO, 89);
    int p6   = fc_cmp_bit(cp, PWFPGA_FC_SRC_L3_PROTO, 6);
    int p58  = fc_cmp_bit(cp, PWFPGA_FC_SRC_L3_PROTO, 58);
    int d179 = fc_cmp_bit(cp, PWFPGA_FC_SRC_L4_DST, 179);
    PW_ASSERT(eth6 >= 0 && p89 >= 0 && p6 >= 0 && p58 >= 0 && d179 >= 0);
    /* OSPFv3 rule (0x86DD & proto89), BGP-v6 rule (0x86DD & proto6 & dst179),
     * ICMPv6 ND rule (0x86DD & proto58). */
    PW_ASSERT(fc_rule_has_bits(cp, (uint16_t)((1u<<eth6)|(1u<<p89))));
    PW_ASSERT(fc_rule_has_bits(cp, (uint16_t)((1u<<eth6)|(1u<<p6)|(1u<<d179))));
    PW_ASSERT(fc_rule_has_bits(cp, (uint16_t)((1u<<eth6)|(1u<<p58))));
    pw_program_free(prog);
    pw_config_free(cfg);

    /* Negative: ipv6_nd=false -> no IPv6 punt, only IPv4 ospf(1)+bgp(2) = 3 rules,
     * and no 0x86DD ethertype / proto58 comparator. */
    const char *yaml4 =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 } ]\n"
        "logical_interfaces:\n  - id: 1000\n    global_port: 0\n"
        "    mac: \"02:a5:02:00:00:64\"\n"
        "    punt: { ipv6_nd: false, ospf: true, bgp: true }\n";
    cfg = pw_config_new();
    struct pw_diag d2 = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml4, strlen(yaml4), cfg, &d2), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d2), PW_OK);
    prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d2), PW_OK);
    cp = &prog->per_card[0];
    PW_ASSERT_EQ(cp->n_fc_rules, 3);
    PW_ASSERT(fc_cmp_bit(cp, PWFPGA_FC_SRC_ETHERTYPE, 0x86DD) < 0);
    PW_ASSERT(fc_cmp_bit(cp, PWFPGA_FC_SRC_L3_PROTO, 58) < 0);
    pw_program_free(prog);
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
    /* RX classification is via the flow-id map now, not a classifier rule. */
    PW_ASSERT(prog->per_card[1].n_map_entries >= 1);
    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_forward_rule_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "forwards:\n"
        "  - name: relay\n"
        "    ingress_port: 0\n"
        "    egress_port: 1\n"
        "    ethertype: 0x0800\n"
        "    udp_dst: 5000\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(cfg->n_forwards, 1);
    PW_ASSERT_EQ(cfg->forwards[0].ingress_port, 0);
    PW_ASSERT_EQ(cfg->forwards[0].egress_port, 1);
    PW_ASSERT_EQ(cfg->forwards[0].ethertype, 0x0800);
    PW_ASSERT_EQ(cfg->forwards[0].udp_dst, 5000);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    /* find the FORWARD_PORT rule + verify its comparators */
    bool found = false;
    const struct pw_card_program *cp = &prog->per_card[0];
    for (size_t i = 0; i < cp->n_fc_rules; i++) {
        const struct pw_fc_rule *rl = &cp->fc_rules[i];
        if (rl->action == PWFPGA_ACT_FORWARD_PORT) {
            found = true;
            PW_ASSERT_EQ(rl->egress, 1);
        }
    }
    PW_ASSERT(found);
    /* comparators for ingress==0, ethertype==0x0800, udp_dst==5000 exist */
    bool have_eth = false, have_udp = false, have_ing = false;
    for (size_t i = 0; i < cp->n_fc_cmps; i++) {
        const struct pw_fc_cmp *c = &cp->fc_cmps[i];
        if (c->src == PWFPGA_FC_SRC_ETHERTYPE && c->value == 0x0800) have_eth = true;
        if (c->src == PWFPGA_FC_SRC_L4_DST    && c->value == 5000)   have_udp = true;
        if (c->src == PWFPGA_FC_SRC_INGRESS   && c->value == 0)      have_ing = true;
    }
    PW_ASSERT(have_eth); PW_ASSERT(have_udp); PW_ASSERT(have_ing);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Forward rule matching IPv6 dst (/128 -> 4 comparators) + src (/32 -> 1). */
static void test_forward_ipv6_match_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "forwards:\n"
        "  - ingress_port: 0\n"
        "    egress_port: 1\n"
        "    ipv6_dst: \"2001:db8::1\"\n"
        "    ipv6_src: \"2001:db8::/32\"\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(cfg->forwards[0].ipv6_dst_set);
    PW_ASSERT(cfg->forwards[0].ipv6_src_set);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pw_card_program *cp = &prog->per_card[0];
    /* dst /128: all four words. value of the [127:96] word = 0x20010db8. */
    int n_dst = 0, n_src = 0; bool dst3 = false, dst0 = false, src3 = false;
    for (size_t i = 0; i < cp->n_fc_cmps; i++) {
        const struct pw_fc_cmp *c = &cp->fc_cmps[i];
        if (c->src == PWFPGA_FC_SRC_IPV6_DST_3) { n_dst++; dst3 = (c->value == 0x20010db8u && c->mask == 0xFFFFFFFFu); }
        if (c->src == PWFPGA_FC_SRC_IPV6_DST_2 || c->src == PWFPGA_FC_SRC_IPV6_DST_1) n_dst++;
        if (c->src == PWFPGA_FC_SRC_IPV6_DST_0) { n_dst++; dst0 = (c->value == 0x00000001u); }
        if (c->src == PWFPGA_FC_SRC_IPV6_SRC_3) { n_src++; src3 = (c->value == 0x20010db8u); }
        if (c->src == PWFPGA_FC_SRC_IPV6_SRC_2 || c->src == PWFPGA_FC_SRC_IPV6_SRC_1
            || c->src == PWFPGA_FC_SRC_IPV6_SRC_0) n_src++;
    }
    PW_ASSERT_EQ(n_dst, 4);    /* /128 -> all four dst words */
    PW_ASSERT_EQ(n_src, 1);    /* /32  -> only the top src word */
    PW_ASSERT(dst3); PW_ASSERT(dst0); PW_ASSERT(src3);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* A forward rule needing >12 field comparators must fail PW_E_NO_RESOURCES,
 * not silently drop conditions. ingress(1)+eth(1)+proto(1)+udp(1)+vlan(1) +
 * v6 dst /128 (4) + v6 src /128 (4) = 13 > NCMP(12). */
static void test_forward_comparator_exhaustion(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "forwards:\n"
        "  - ingress_port: 0\n"
        "    egress_port: 1\n"
        "    ethertype: 0x86dd\n"
        "    ip_proto: 17\n"
        "    udp_dst: 5000\n"
        "    vlan: 100\n"
        "    ipv6_dst: \"2001:db8::1\"\n"
        "    ipv6_src: \"2001:db8::2\"\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_E_NO_RESOURCES);
    /* diagnostic names the comparator pool + the rule class (not just a code) */
    PW_ASSERT_EQ(d.code, PW_E_NO_RESOURCES);
    PW_ASSERT(strstr(d.message, "comparator") != NULL);
    PW_ASSERT(strstr(d.path, "forward") != NULL);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* classify:header IPv6 flow with a /64 dst match -> hash key mask narrows the
 * low 64 bits of the dst (words w0,w1 cleared; w2,w3 kept). */
static void test_header_classify_ipv6_prefix(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv6: { src: \"2001:db8::1\", dst: \"2001:db8:dead:beef::2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    classify: header\n"
        "    match: { ipv6_dst_prefix: 64 }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(cfg->flows[0].match_ipv6_dst_set);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pw_card_program *cp = &prog->per_card[0];
    PW_ASSERT_EQ(cp->n_hash_entries, 1);
    PW_ASSERT_EQ(cp->hash_mask[0], 0u);            /* dst [31:0]  masked out */
    PW_ASSERT_EQ(cp->hash_mask[1], 0u);            /* dst [63:32] masked out */
    PW_ASSERT_EQ(cp->hash_mask[2], 0xFFFFFFFFu);   /* dst [95:64] kept */
    PW_ASSERT_EQ(cp->hash_mask[3], 0xFFFFFFFFu);   /* dst [127:96] kept */
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* protocol: tcp -> l4_proto 6 + flags packed; hash key proto = 6. */
static void test_tcp_flow_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" }\n"
        "    tcp:  { src_port: 40000, dst_port: 80, flags: 0x12 }\n"
        "    traffic: { frame_len: 128, rate_bps: 1000000000 }\n"
        "    classify: header\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(cfg->flows[0].udp.l4_proto, 6);
    PW_ASSERT_EQ(cfg->flows[0].udp.tcp_flags, 0x12);
    PW_ASSERT_EQ(cfg->flows[0].udp.dst_port, 80);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *fr = &prog->per_card[0].flow_rows[0];
    PW_ASSERT_EQ(fr->l4_proto, 6);
    PW_ASSERT_EQ(fr->tcp_flags, 0x12);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* udp and tcp blocks are mutually exclusive. */
static void test_udp_tcp_mutually_exclusive(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" }\n"
        "    udp:  { src_port: 1, dst_port: 2 }\n"
        "    tcp:  { src_port: 3, dst_port: 4 }\n"
        "    traffic: { frame_len: 128, rate_bps: 1000000000 }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_E_INVAL);
    pw_config_free(cfg);
}

static void test_flow_field_modifiers(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"198.51.100.1\", dst: \"198.51.100.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    modifiers:\n"
        "      dst_ipv4: { mode: increment, mask: 0x000003ff }\n"
        "      udp_src:  { mode: random,    mask: 0xffff }\n"
        "      src_mac:  { mode: increment, mask: 0x0000000000ff }\n"
        "      vlan:     { mode: random,    mask: 0x0ff }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mode, 1);
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mask, 0x3ff);
    PW_ASSERT_EQ(cfg->flows[0].mod.udp_src.mode, 2);
    PW_ASSERT_EQ(cfg->flows[0].mod.src_ipv4.mode, 0);   /* absent -> static */
    PW_ASSERT_EQ(cfg->flows[0].mod.src_mac.mode, 1);
    PW_ASSERT_EQ(cfg->flows[0].mod.vlan.mode, 2);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *fr = &prog->per_card[0].flow_rows[0];
    PW_ASSERT_EQ(fr->dst_ipv4_mod, 1);
    PW_ASSERT_EQ(fr->dst_ipv4_mask, 0x3ff);
    PW_ASSERT_EQ(fr->udp_src_mod, 2);
    PW_ASSERT_EQ(fr->udp_src_mask, 0xffff);
    PW_ASSERT_EQ(fr->src_ipv4_mod, 0);
    /* MAC mask is MSB-first: low byte (bits 7..0) lands in mask[5] */
    PW_ASSERT_EQ(fr->src_mac_mod, 1);
    PW_ASSERT_EQ(fr->src_mac_mask[5], 0xff);
    PW_ASSERT_EQ(fr->src_mac_mask[0], 0x00);
    PW_ASSERT_EQ(fr->vlan_mod, 2);
    PW_ASSERT_EQ(fr->vlan_mask, 0x0ff);
    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_ipv6_flow_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv6: { src: \"2001:db8::1\", dst: \"2001:db8::2\", hop_limit: 64, dscp: 46 }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    modifiers: { dst_ipv6: { mode: increment, mask: 0x000000ff } }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(cfg->flows[0].ipv6.present);
    PW_ASSERT(!cfg->flows[0].ipv4.present);
    PW_ASSERT_EQ(cfg->flows[0].ipv6.src[0], 0x20);
    PW_ASSERT_EQ(cfg->flows[0].ipv6.src[1], 0x01);
    PW_ASSERT_EQ(cfg->flows[0].ipv6.dst[15], 0x02);
    PW_ASSERT_EQ(cfg->flows[0].ipv6.hop_limit, 64);
    PW_ASSERT_EQ(cfg->flows[0].ipv6.dscp, 46);
    /* dst_ipv6 modifier populates the generic address-modifier slot */
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mode, PWFPGA_FIELD_INCREMENT);
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mask, 0xffu);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *fr = &prog->per_card[0].flow_rows[0];
    PW_ASSERT_EQ(fr->ip_version, 6);
    PW_ASSERT_EQ(fr->ipv6_src[0], 0x20);
    PW_ASSERT_EQ(fr->ipv6_dst[15], 0x02);
    PW_ASSERT_EQ(fr->dscp, 46);                       /* IPv6 traffic class */
    PW_ASSERT_EQ(fr->dst_ipv4_mod, PWFPGA_FIELD_INCREMENT);
    PW_ASSERT_EQ(fr->dst_ipv4_mask, 0xffu);           /* applied to v6 low 32b */
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Full 128-bit IPv6 modifier: a v6-literal mask rotates the upper words. The
 * low 32 bits land in dst_ipv4_mask; the high 96 in dst_ipv6_mask_hi (wire
 * little-endian, hi[i]=mask[11-i]). mask ffff:ffff:: = bits[127:96] only. */
static void test_ipv6_modifier_128(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv6: { src: \"2001:db8::1\", dst: \"2001:db8::2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    modifiers: { dst_ipv6: { mode: random, mask: \"ffff:ffff::\" } }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mode, PWFPGA_FIELD_RANDOM);
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv4.mask, 0u);          /* low 32 untouched */
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv6_mask[0], 0xff);     /* MSB-first bits[127:120] */
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv6_mask[3], 0xff);     /* bits[103:96] */
    PW_ASSERT_EQ(cfg->flows[0].mod.dst_ipv6_mask[4], 0x00);     /* bits[95:88] */
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *fr = &prog->per_card[0].flow_rows[0];
    PW_ASSERT_EQ(fr->dst_ipv4_mask, 0u);                        /* low word not masked */
    /* high 96: only the top word (bits[127:96]) set -> hi[8..11]=0xFF, hi[0..7]=0 */
    PW_ASSERT_EQ(fr->dst_ipv6_mask_hi[11], 0xff);
    PW_ASSERT_EQ(fr->dst_ipv6_mask_hi[8],  0xff);
    PW_ASSERT_EQ(fr->dst_ipv6_mask_hi[7],  0x00);
    PW_ASSERT_EQ(fr->dst_ipv6_mask_hi[0],  0x00);
    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_background_and_match_mask(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"                       /* measured + udp_dst modifier -> auto-relax */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    modifiers: { udp_dst: { mode: increment, mask: 0x00ff } }\n"
        "  - id: 2\n"                       /* explicit partial match mask */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:03\", dst_mac: \"02:a5:02:00:00:04\" }\n"
        "    ipv4: { src: \"192.0.2.3\", dst: \"192.0.2.4\" }\n"
        "    udp:  { src_port: 49152, dst_port: 6000 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    match: { udp_dst: 0xff00 }\n"
        "  - id: 3\n"                       /* background: TX only, no classifier */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:05\", dst_mac: \"02:a5:02:00:00:06\" }\n"
        "    ipv4: { src: \"192.0.2.5\", dst: \"192.0.2.6\" }\n"
        "    udp:  { src_port: 49152, dst_port: 7000 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    background: true\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(cfg->flows[2].background);
    PW_ASSERT_EQ(cfg->flows[1].match_udp_dst_mask, 0xff00);
    PW_ASSERT_EQ(cfg->flows[0].match_udp_dst_mask, 0xffff);   /* default full */
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    /* 3 TX flow rows. TEST_RX flows are now classified by the flow-id map, not
     * the classifier, so there are 0 classifier rows and 2 map entries (the 2
     * non-background test flows; the background flow has neither). Keying on the
     * stable test_flow_id makes udp_dst modifiers/masks irrelevant to RX
     * classification -- the old per-flow classifier bitwise-mask relax is moot. */
    PW_ASSERT_EQ(prog->per_card[0].n_flow_rows, 3);
    PW_ASSERT_EQ(prog->per_card[0].n_fc_rules, 0);   /* test flows use the map */
    PW_ASSERT_EQ(prog->per_card[0].n_map_entries, 2);
    /* flow_id -> local checker slot (rx_lfid assigned 0,1 in order). */
    PW_ASSERT_EQ(prog->per_card[0].map_entries[0].flow_id, 1);
    PW_ASSERT_EQ(prog->per_card[0].map_entries[0].local_flow_id, 0);
    PW_ASSERT_EQ(prog->per_card[0].map_entries[1].flow_id, 2);
    PW_ASSERT_EQ(prog->per_card[0].map_entries[1].local_flow_id, 1);
    /* flow_meta must be 1:1 with cfg->flows even for the background flow (index
     * 2, id 3) -- the daemon indexes flow.stats / test.start-stop / quiesce by
     * flow_index, so a zero-initialized meta there reads flow_id 0 / card 0 /
     * slot 0. It is TX-only, so its TX row is the 3rd (local slot 2) and latency
     * is not valid. */
    PW_ASSERT_EQ(prog->flow_meta[2].global_flow_id, 3);
    PW_ASSERT_EQ(prog->flow_meta[2].tx_local_flow_id, 2);
    PW_ASSERT(!prog->flow_meta[2].latency_valid);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* A flow with `classify: header` is lowered to generic slice-classifier configs
 * + a rule (NOT a flow-id map entry), so it is classified by its header fields
 * with no dependency on the payload. */
static void test_header_classify_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:07:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    classify: header\n"
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50007 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n";  /* full tuple */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(cfg->flows[0].classify_header);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    /* header-classified -> hash exact table (no map entry, no field comparator/
     * rule -- those carry punt/forward only). One hash entry, slot 0. */
    PW_ASSERT_EQ(prog->per_card[0].n_map_entries, 0);
    PW_ASSERT_EQ(prog->per_card[0].n_fc_cmps, 0);
    PW_ASSERT_EQ(prog->per_card[0].n_fc_rules, 0);
    PW_ASSERT_EQ(prog->per_card[0].n_hash_entries, 1);
    PW_ASSERT_EQ(prog->per_card[0].hash_entries[0].local_flow_id, 0);
    PW_ASSERT(prog->per_card[0].hash_seed != 0);   /* a collision-free seed found */
    /* no modifiers / full match -> key mask is all-ones (key everything). */
    PW_ASSERT_EQ(prog->per_card[0].hash_mask[0], 0xFFFFFFFFu);
    /* wide field-aligned key words: w0 = l3_dst (192.0.2.2), w4 = l3_src
     * (192.0.2.1), w8 = {l4_src 49152, l4_dst 50007}, w10 = proto 17. */
    PW_ASSERT_EQ(prog->per_card[0].hash_entries[0].key_word[0], 0xC0000202u);
    PW_ASSERT_EQ(prog->per_card[0].hash_entries[0].key_word[4], 0xC0000201u);
    PW_ASSERT_EQ(prog->per_card[0].hash_entries[0].key_word[8], ((uint32_t)49152u << 16) | 50007u);
    PW_ASSERT_EQ(prog->per_card[0].hash_entries[0].key_word[10], 17u);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Two header-classify flows that differ ONLY in a field they both randomize
 * (src port) collapse to the same masked hash key -> the compiler must reject
 * the config with a clear diagnostic, not silently misclassify. */
static void test_header_classify_mask_collision(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:07:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    classify: header\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"198.51.100.1\" }\n"
        "    udp:  { src_port: 1000, dst_port: 50001 }\n"
        "    traffic: { frame_len: 256, rate_bps: 100000000 }\n"
        "    modifiers: { udp_src: { mode: random, mask: 0xffff } }\n"
        "  - id: 2\n"
        "    classify: header\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"198.51.100.1\" }\n"
        "    udp:  { src_port: 2000, dst_port: 50001 }\n"     /* differs only in src port */
        "    traffic: { frame_len: 256, rate_bps: 100000000 }\n"
        "    modifiers: { udp_src: { mode: random, mask: 0xffff } }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    /* both flows differ only in src port, which is randomized + masked out ->
     * identical masked keys -> compile rejects with PW_E_INVAL. */
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_E_INVAL);
    pw_program_free(prog);
    pw_config_free(cfg);
}

static void test_encap_flow_compiles(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"                       /* IPIP: v4 inner in v4 outer */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    encap: { type: ipip, outer: { ipv4: { src: \"10.0.0.1\", dst: \"10.0.0.2\", ttl: 32, dscp: 8 } } }\n"
        "    rx_expect: tunneled\n"
        "  - id: 2\n"                       /* GRE: v4 inner in v6 outer */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:03\", dst_mac: \"02:a5:02:00:00:04\" }\n"
        "    ipv4: { src: \"192.0.2.3\", dst: \"192.0.2.4\" }\n"
        "    udp:  { src_port: 49152, dst_port: 6000 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    encap: { type: gre, outer: { ipv6: { src: \"2001:db8::1\", dst: \"2001:db8::2\" } } }\n"
        "  - id: 3\n"                       /* EtherIP: explicit inner-Ethernet MAC */
        "    tx_global_port: 0\n"
        "    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:05\", dst_mac: \"02:a5:02:00:00:06\" }\n"
        "    ipv4: { src: \"192.0.2.5\", dst: \"192.0.2.6\" }\n"
        "    udp:  { src_port: 49152, dst_port: 7000 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "    encap: { type: etherip, outer: { ipv4: { src: \"10.0.0.5\", dst: \"10.0.0.6\" } },\n"
        "             inner_l2: { src_mac: \"02:bb:00:00:00:01\", dst_mac: \"02:bb:00:00:00:02\" } }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    /* config model */
    PW_ASSERT(cfg->flows[0].encap.present);
    PW_ASSERT_EQ(cfg->flows[0].encap.type, PW_ENCAP_IPIP);
    PW_ASSERT(cfg->flows[0].encap.outer_ipv4.present);
    PW_ASSERT_EQ(cfg->flows[0].encap.outer_ipv4.ttl, 32);
    PW_ASSERT_EQ(cfg->flows[0].encap.outer_ipv4.dscp, 8);
    PW_ASSERT_EQ(cfg->flows[0].rx_expect, PW_RX_TUNNELED);
    PW_ASSERT(cfg->flows[1].encap.present);
    PW_ASSERT_EQ(cfg->flows[1].encap.type, PW_ENCAP_GRE);
    PW_ASSERT(cfg->flows[1].encap.outer_ipv6.present);
    PW_ASSERT_EQ(cfg->flows[1].rx_expect, PW_RX_INNER);   /* default */
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    /* compiled wire */
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pwfpga_flow_config *r0 = &prog->per_card[0].flow_rows[0];
    PW_ASSERT_EQ(r0->encap_type, PWFPGA_ENCAP_IPIP);
    PW_ASSERT_EQ(r0->outer_ip_version, 4);
    PW_ASSERT_EQ(r0->rx_expect, PWFPGA_RX_TUNNELED);
    PW_ASSERT_EQ(r0->outer_ttl, 32);
    PW_ASSERT_EQ(r0->outer_dscp, 8);
    PW_ASSERT_EQ(r0->outer_src_ipv4, 0x0a000001u);
    PW_ASSERT_EQ(r0->outer_dst_ipv4, 0x0a000002u);
    const struct pwfpga_flow_config *r1 = &prog->per_card[0].flow_rows[1];
    PW_ASSERT_EQ(r1->encap_type, PWFPGA_ENCAP_GRE);
    PW_ASSERT_EQ(r1->outer_ip_version, 6);
    PW_ASSERT_EQ(r1->outer_ipv6_src[0], 0x20);   /* 2001:db8::1, MSB first */
    PW_ASSERT_EQ(r1->outer_ipv6_src[1], 0x01);
    PW_ASSERT_EQ(r1->outer_ipv6_dst[15], 0x02);
    /* IPIP flow has no inner_l2 -> inner MAC falls back to the flow l2 MAC. */
    PW_ASSERT(cfg->flows[0].encap.inner_mac_set == false);
    PW_ASSERT_EQ(r0->inner_src_mac[0], 0x02); PW_ASSERT_EQ(r0->inner_src_mac[1], 0xa5);
    PW_ASSERT_EQ(r0->inner_src_mac[5], 0x01);
    /* EtherIP flow with explicit inner_l2 -> distinct inner MAC on the wire. */
    const struct pwfpga_flow_config *r2 = &prog->per_card[0].flow_rows[2];
    PW_ASSERT_EQ(r2->encap_type, PWFPGA_ENCAP_ETHERIP);
    PW_ASSERT(cfg->flows[2].encap.inner_mac_set);
    PW_ASSERT_EQ(r2->inner_dst_mac[0], 0x02); PW_ASSERT_EQ(r2->inner_dst_mac[1], 0xbb);
    PW_ASSERT_EQ(r2->inner_dst_mac[5], 0x02);
    PW_ASSERT_EQ(r2->inner_src_mac[1], 0xbb); PW_ASSERT_EQ(r2->inner_src_mac[5], 0x01);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Frame templates: raw payload (true 64B) + IP-only / Eth-only frames. Verify
 * the config model, the compiled wire row's frame_template/ethertype, the
 * template-aware hash key (absent layers zeroed), and true 64-byte acceptance. */
static void test_frame_templates(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:07:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"                       /* L4RAW: true 64B, full headers, no test hdr */
        "    classify: header\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n"
        "    traffic: { frame_len: 64, rate_bps: 10000000000, frame_template: raw }\n"
        "  - id: 2\n"                       /* L3RAW: Eth+IP+payload */
        "    classify: header\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:03\", dst_mac: \"02:a5:02:00:00:04\" }\n"
        "    ipv4: { src: \"192.0.2.3\", dst: \"192.0.2.4\" }\n"
        "    udp:  { src_port: 1000, dst_port: 2000 }\n"
        "    traffic: { frame_len: 64, rate_bps: 10000000000, frame_template: ip }\n"
        "  - id: 3\n"                       /* L2RAW: Eth+ethertype+payload */
        "    classify: header\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:05\", dst_mac: \"02:a5:02:00:00:06\", ethertype: 0x88b5, vlan: 100 }\n"
        "    ipv4: { src: \"192.0.2.5\", dst: \"192.0.2.6\" }\n"
        "    udp:  { src_port: 3000, dst_port: 4000 }\n"
        "    traffic: { frame_len: 64, rate_bps: 10000000000, frame_template: eth }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(cfg->flows[0].traffic.frame_template, PW_FRAME_TEMPLATE_L4RAW);
    PW_ASSERT_EQ(cfg->flows[1].traffic.frame_template, PW_FRAME_TEMPLATE_L3RAW);
    PW_ASSERT_EQ(cfg->flows[2].traffic.frame_template, PW_FRAME_TEMPLATE_L2RAW);
    PW_ASSERT_EQ(cfg->flows[2].l2.ethertype, 0x88b5);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    /* Compiled wire rows carry the template + ethertype. */
    PW_ASSERT_EQ(prog->per_card[0].flow_rows[0].frame_template, PWFPGA_FRAME_TEMPLATE_L4RAW);
    PW_ASSERT_EQ(prog->per_card[0].flow_rows[1].frame_template, PWFPGA_FRAME_TEMPLATE_L3RAW);
    PW_ASSERT_EQ(prog->per_card[0].flow_rows[2].frame_template, PWFPGA_FRAME_TEMPLATE_L2RAW);
    PW_ASSERT_EQ(prog->per_card[0].flow_rows[2].l2_ethertype, 0x88b5);
    /* Three header-classify flows -> three hash entries, collision-free. */
    PW_ASSERT_EQ(prog->per_card[0].n_hash_entries, 3);
    PW_ASSERT(prog->per_card[0].hash_seed != 0);
    /* Hash keys: L4RAW keys on the full tuple (real L4 ports); L3RAW zeroes the
     * L4 word (no L4 header); L2RAW zeroes L3+L4, keying on {vlan,ethertype}. */
    const struct pw_fc_hash_entry *he = prog->per_card[0].hash_entries;
    /* entries are appended in flow order: [0]=L4RAW [1]=L3RAW [2]=L2RAW */
    PW_ASSERT_EQ(he[0].key_word[8], ((uint32_t)49152u << 16) | 50001u);  /* L4RAW ports */
    PW_ASSERT_EQ(he[1].key_word[0], 0xC0000204u);                        /* L3RAW l3_dst */
    PW_ASSERT_EQ(he[1].key_word[8], 0u);                                 /* L3RAW no L4 */
    PW_ASSERT_EQ(he[1].key_word[10], 17u);                               /* L3RAW proto */
    PW_ASSERT_EQ(he[2].key_word[0], 0u);                                 /* L2RAW no L3 */
    PW_ASSERT_EQ(he[2].key_word[8], 0u);                                 /* L2RAW no L4 */
    PW_ASSERT_EQ(he[2].key_word[9], (100u << 16) | 0x88b5u);             /* {vlan,ethertype} */
    PW_ASSERT_EQ(he[2].key_word[10], 0u);
    pw_program_free(prog);
    pw_config_free(cfg);
}

/* Raw templates require classify:header and forbid measurements/encap. */
static void test_frame_template_rejects(void) {
    const char *base_hdr =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:07:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "flows:\n"
        "  - id: 1\n"
        "    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n"
        "    udp:  { src_port: 49152, dst_port: 50001 }\n";
    /* raw template + measurements -> reject */
    {
        char yaml[1400];
        snprintf(yaml, sizeof yaml, "%s%s", base_hdr,
            "    classify: header\n"
            "    traffic: { frame_len: 64, rate_bps: 1000000000, frame_template: raw }\n"
            "    measurements: { loss: true }\n");
        struct pw_config *cfg = pw_config_new(); struct pw_diag d = {0};
        PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
        PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_E_INVAL);
        pw_config_free(cfg);
    }
    /* raw template WITHOUT classify:header -> reject */
    {
        char yaml[1400];
        snprintf(yaml, sizeof yaml, "%s%s", base_hdr,
            "    traffic: { frame_len: 64, rate_bps: 1000000000, frame_template: ip }\n");
        struct pw_config *cfg = pw_config_new(); struct pw_diag d = {0};
        PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
        PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_E_INVAL);
        pw_config_free(cfg);
    }
}

static void test_reject_cross_card_forward(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n"
        "  - id: 0\n"
        "    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 } ]\n"
        "  - id: 1\n"
        "    pci: \"0000:04:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 2 } ]\n"
        "forwards:\n"
        "  - { ingress_port: 0, egress_port: 2 }\n";   /* different cards */
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT(pw_config_validate(cfg, &d) != PW_OK);   /* same-card rule */
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

/* The fake backend records CSR writes per classification window so daemon-
 * programming can be checked in CI. Verify each window's address macros land in
 * the intended window (a forgotten/misaddressed write would miss its counter). */
static void test_fake_csr_window_recording(void) {
    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);
    b.ops->write32(b.ctx, PWFPGA_WIN_FLOWID_MAP + 7u * 4u, PWFPGA_FLOWID_MAP_VALID | 3u);
    b.ops->write32(b.ctx, PWFPGA_FC_CMP_SRC(PWFPGA_WIN_FC_CMP, 0), 13u);
    b.ops->write32(b.ctx, PWFPGA_FC_CMP_MASK(PWFPGA_WIN_FC_CMP, 0), 0xFu);
    b.ops->write32(b.ctx, PWFPGA_FC_UDF_OFFSET(PWFPGA_WIN_FC_UDF, 0), 14u);
    b.ops->write32(b.ctx, PWFPGA_FC_RULE_LFID(PWFPGA_WIN_FC_RULE, 0), 0u);
    b.ops->write32(b.ctx, PWFPGA_HASH_MASK_WORD(PWFPGA_WIN_HASH_MASK, 0), 0xFFFFFFFFu);
    b.ops->write32(b.ctx, PWFPGA_REG_HASH_SEED, 0x9E3779B1u);
    b.ops->write32(b.ctx, PWFPGA_HASH_KEY_WORD(PWFPGA_WIN_FC_HASH, 0, 0), 0u);
    struct pw_fake_wr_counts wc;
    pw_fake_backend_wr_counts(b.ctx, &wc);
    PW_ASSERT_EQ(wc.flowid_map, 1);
    PW_ASSERT_EQ(wc.fc_cmp, 2);     /* SRC + MASK */
    PW_ASSERT_EQ(wc.fc_udf, 1);
    PW_ASSERT_EQ(wc.fc_rule, 1);
    PW_ASSERT_EQ(wc.hash, 3);       /* mask word + seed + key word */
    pw_card_backend_close(&b);
}

/* pw_program_card_tables (shared by the daemon's program_backends) must write
 * each classification window the right number of times -- caught via the fake
 * backend's per-window write recording. A forgotten/misaddressed window would
 * make the recorded count diverge from the compiled program's content. */
static void test_program_card_tables(void) {
    const char *yaml =
        "system: { name: pw, mode: multi-card, default_speed: 10g }\n"
        "cards:\n  - id: 0\n    pci: \"0000:03:00.0\"\n"
        "    ports: [ { local_port: 0, global_port: 0 }, { local_port: 1, global_port: 1 } ]\n"
        "logical_interfaces:\n  - id: 1000\n    global_port: 0\n"
        "    mac: \"02:a5:02:00:00:64\"\n    punt: { arp: true, bgp: true }\n"
        "flows:\n"
        "  - id: 1\n    tx_global_port: 0\n    rx_global_port: 1\n    logical_if_id: 1000\n"
        "    l2: { src_mac: \"02:a5:02:00:00:01\", dst_mac: \"02:a5:02:00:00:02\" }\n"
        "    ipv4: { src: \"192.0.2.1\", dst: \"192.0.2.2\" }\n    udp: { src_port: 1, dst_port: 2 }\n"
        "    traffic: { frame_len: 512, rate_bps: 1000000000 }\n"
        "  - id: 2\n    classify: header\n    tx_global_port: 0\n    rx_global_port: 1\n"
        "    l2: { src_mac: \"02:a5:02:00:02:01\", dst_mac: \"02:a5:02:00:02:02\" }\n"
        "    ipv4: { src: \"192.0.2.3\", dst: \"198.51.100.9\" }\n    udp: { src_port: 49152, dst_port: 50002 }\n"
        "    traffic: { frame_len: 256, rate_bps: 200000000 }\n";
    struct pw_config *cfg = pw_config_new();
    struct pw_diag d = {0};
    PW_ASSERT_EQ(pw_config_parse_string(yaml, strlen(yaml), cfg, &d), PW_OK);
    PW_ASSERT_EQ(pw_config_validate(cfg, &d), PW_OK);
    struct pw_program *prog = pw_program_new();
    PW_ASSERT_EQ(pw_flow_compile(cfg, prog, &d), PW_OK);
    const struct pw_card_program *cp = &prog->per_card[0];
    /* exercise the windows we expect to be populated */
    PW_ASSERT(cp->n_map_entries >= 1);   /* structured flow 1 */
    PW_ASSERT(cp->n_fc_rules >= 1);      /* arp + bgp punt */
    PW_ASSERT(cp->n_hash_entries >= 1);  /* header-classified flow 2 */

    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_fake_backend_open("0000:03:00.0", &b), PW_OK);
    PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, cp), PW_OK);
    struct pw_fake_wr_counts wc;
    pw_fake_backend_wr_counts(b.ctx, &wc);
    /* Counts include the invalidate-to-capacity writes (the whole point: a
     * reload writes every slot so stale entries can't survive). */
    PW_ASSERT_EQ(wc.flowid_map, PWFPGA_FLOWID_MAP_DEPTH + (uint32_t)cp->n_map_entries);
    PW_ASSERT_EQ(wc.fc_cmp,     (uint32_t)cp->n_fc_cmps * 3u);
    PW_ASSERT_EQ(wc.fc_udf,     (uint32_t)cp->n_fc_udfs * 3u);
    /* configured rules: WORD0+LFID+LIF (3); disabled tail rules: WORD0 (1). */
    PW_ASSERT_EQ(wc.fc_rule,
                 (uint32_t)cp->n_fc_rules * 3u + (PWFPGA_NUM_RULE - (uint32_t)cp->n_fc_rules));
    /* HASH_DEPTH bucket invalidations + (if any) mask + seed + per-entry writes. */
    uint32_t exp_hash = PWFPGA_HASH_DEPTH + (cp->n_hash_entries
        ? (uint32_t)(PWFPGA_HASH_KEY_WORDS + 1u +
                     cp->n_hash_entries * (PWFPGA_HASH_KEY_WORDS + 1u))
        : 0u);
    PW_ASSERT_EQ(wc.hash, exp_hash);

    /* A backend without write32 but a program that needs the classifier windows
     * must report PW_E_NOT_IMPLEMENTED, not silently "succeed". */
    struct pw_card_backend_ops no_w32 = *b.ops;
    no_w32.write32 = NULL;
    PW_ASSERT_EQ(pw_program_card_tables(&no_w32, b.ctx, cp), PW_E_NOT_IMPLEMENTED);
    /* Flow rows present but no flow_commit (e.g. a staging backend) -> the writes
     * would never commit; report NOT_IMPLEMENTED rather than "programmed". */
    struct pw_card_backend_ops no_commit = *b.ops;
    no_commit.flow_commit = NULL;
    PW_ASSERT_EQ(pw_program_card_tables(&no_commit, b.ctx, cp), PW_E_NOT_IMPLEMENTED);

    /* Boundary hardening: a corrupt/hand-built program with out-of-range
     * counts or indices must be REJECTED up front (PW_E_INVAL), not translated
     * into a CSR offset that aliases a neighbouring window. Copy the valid
     * program and perturb one field at a time. */
    {
        struct pw_card_program bad = *cp;
        bad.n_fc_rules = PWFPGA_NUM_RULE + 1;   /* over comparator/rule capacity */
        PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, &bad), PW_E_INVAL);
    }
    {
        struct pw_card_program bad = *cp;       /* rows past the flow-table window */
        bad.n_flow_rows = PWFPGA_FLOW_TABLE_ROWS + 1;
        PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, &bad), PW_E_INVAL);
    }
    {
        struct pw_card_program bad = *cp;
        bad.n_hash_entries = PWFPGA_HASH_DEPTH + 1;
        PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, &bad), PW_E_INVAL);
    }
    if (cp->n_map_entries >= 1) {
        struct pw_flowid_map_entry me = cp->map_entries[0];
        me.flow_id = PWFPGA_FLOWID_MAP_DEPTH;   /* one past the map window */
        struct pw_card_program bad = *cp;
        bad.map_entries = &me;
        bad.n_map_entries = 1;
        PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, &bad), PW_E_INVAL);
    }
    {
        struct pw_card_program bad = *cp;   /* non-NULL count with NULL array */
        bad.n_map_entries = 1;
        bad.map_entries = NULL;
        PW_ASSERT_EQ(pw_program_card_tables(b.ops, b.ctx, &bad), PW_E_INVAL);
    }

    pw_card_backend_close(&b);
    pw_program_free(prog);
    pw_config_free(cfg);
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

    /* Table window writes succeed via the structured window
     * protocol (see test_bar_backend_window_writes for the
     * detailed layout check). */
    struct pwfpga_flow_config f = {0};
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, 0, &f), PW_OK);

    /* Flow-table window boundary: the LAST row (index ROWS-1 = 63) must be
     * ACCEPTED -- its 244-B write ends before the flow-commit register in the
     * slot's unused tail -- while one past it must be rejected as OUT_OF_RANGE
     * (would alias the histogram window). Regression guard for the off-by-one
     * where bounding by the commit register wrongly rejected the final row. */
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, PWFPGA_FLOW_TABLE_ROWS - 1, &f), PW_OK);
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, PWFPGA_FLOW_TABLE_ROWS, &f), PW_E_OUT_OF_RANGE);

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

static void test_vfio_open_bogus(void) {
    /* No hardware / no vfio binding in CI: a bogus BDF must fail
     * cleanly (no crash) and leave a handle that is safe to close. */
    struct pw_vfio_handle h;
    PW_ASSERT(pw_vfio_open_bar("0000:ff:1f.7", 0, &h) != PW_OK);
    pw_vfio_close(&h);  /* safe after a failed open */

    PW_ASSERT(pw_vfio_open_bar(NULL, 0, &h) == PW_E_INVAL);
    PW_ASSERT(pw_vfio_open_bar("0000:ff:1f.7", 9, &h) == PW_E_INVAL);

    /* The backend's vfio entry point fails cleanly too. */
    struct pw_card_backend b;
    PW_ASSERT(pw_bar_backend_open_vfio("0000:ff:1f.7", &b) != PW_OK);
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
    int n = b.ops->slow_path_rx(b.ctx, got, sizeof(got), &lif, NULL);
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

static void test_bar_backend_window_writes(void) {
    /* Verify the BAR backend lays out classifier / flow / commit
     * registers exactly where csr.h says it does. Uses a tmpfs file
     * as a synthetic BAR; reads the bytes back directly so the test
     * doesn't trust the backend's own readers.            */
    char path[] = "/tmp/pw_bar_win_XXXXXX";
    int fd = mkstemp(path);
    PW_ASSERT(fd >= 0);
    if (fd < 0) return;
    PW_ASSERT_EQ(ftruncate(fd, 65536), 0);
    close(fd);

    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_bar_backend_open_path(path, &b), PW_OK);

    /* The legacy classifier_write backend op is retired (the field/hash
     * classifier is programmed via write32; covered by tb_csr_full +
     * tb_field_classifier / tb_hash_classifier). This test now covers the
     * flow-table window serialization. */
    uint8_t *raw;
    uint32_t commit_val;

    /* --- flow_write at row 5 --- */
    struct pwfpga_flow_config f = {0};
    f.enable            = 1;
    f.egress_local_port = 1;
    f.global_flow_id    = 42;
    f.local_flow_id     = 5;
    f.rate_bps          = 1000000000ull;
    PW_ASSERT_EQ(b.ops->flow_write(b.ctx, 5, &f), PW_OK);
    PW_ASSERT_EQ(b.ops->flow_commit(b.ctx), PW_OK);

    /* re-read (raw is first mapped here -- no prior mapping to release) */
    fd = open(path, O_RDONLY);
    raw = mmap(NULL, 65536, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    size_t flow_base = PWFPGA_WIN_FLOW_TABLE + 5 * PWFPGA_FLOW_STRIDE;
    struct pwfpga_flow_config fback;
    memcpy(&fback, raw + flow_base, sizeof(fback));
    PW_ASSERT_EQ(fback.enable, 1);
    PW_ASSERT_EQ(fback.egress_local_port, 1);
    PW_ASSERT_EQ(fback.global_flow_id, 42);
    PW_ASSERT_EQ(fback.local_flow_id, 5);
    PW_ASSERT_EQ((long long)fback.rate_bps, (long long)1000000000ull);

    memcpy(&commit_val, raw + PWFPGA_REG_FLOW_COMMIT, 4);
    PW_ASSERT_EQ(commit_val, 1u);

    munmap(raw, 65536);
    pw_card_backend_close(&b);
    unlink(path);
}

static void test_bar_backend_stats_reads(void) {
    /* Stamp known counter bytes into the stats-snapshot window and
     * confirm bar_port_stats_read / bar_flow_stats_read decode them
     * at the right offsets. */
    char path[] = "/tmp/pw_bar_stats_XXXXXX";
    int fd = mkstemp(path);
    PW_ASSERT(fd >= 0);
    if (fd < 0) return;
    PW_ASSERT_EQ(ftruncate(fd, 65536), 0);
    /* Build a synthetic port_stats block for port 1 and a flow_stats
     * block for lfid 4. */
    struct pw_port_stats ps = {0};
    ps.rx_frames = 0x1111;
    ps.tx_frames = 0x2222;
    ps.link_up_count = 3;
    {
        ssize_t w1 = pwrite(fd, &ps, sizeof(ps),
                            PWFPGA_WIN_STATS_SNAPSHOT + 1 * PWFPGA_PORT_STATS_STRIDE);
        PW_ASSERT_EQ((long long)w1, (long long)sizeof(ps));
    }
    struct pw_flow_stats fs = {0};
    fs.rx_frames = 99;
    fs.lost_packets_estimated = 7;
    fs.sum_latency = 12345;
    fs.sample_count = 50;
    {
        ssize_t w2 = pwrite(fd, &fs, sizeof(fs),
                            PWFPGA_WIN_STATS_SNAPSHOT + PWFPGA_FLOW_STATS_BASE +
                            4 * PWFPGA_FLOW_STATS_STRIDE);
        PW_ASSERT_EQ((long long)w2, (long long)sizeof(fs));
    }
    close(fd);

    struct pw_card_backend b;
    PW_ASSERT_EQ(pw_bar_backend_open_path(path, &b), PW_OK);
    PW_ASSERT_EQ(b.ops->stats_snapshot(b.ctx), PW_OK);

    struct pw_port_stats ps_back = {0};
    PW_ASSERT_EQ(b.ops->port_stats_read(b.ctx, 1, &ps_back), PW_OK);
    PW_ASSERT_EQ(ps_back.rx_frames, 0x1111);
    PW_ASSERT_EQ(ps_back.tx_frames, 0x2222);
    PW_ASSERT_EQ(ps_back.link_up_count, 3);

    struct pw_flow_stats fs_back = {0};
    PW_ASSERT_EQ(b.ops->flow_stats_read(b.ctx, 4, &fs_back), PW_OK);
    PW_ASSERT_EQ(fs_back.rx_frames, 99);
    PW_ASSERT_EQ(fs_back.lost_packets_estimated, 7);
    PW_ASSERT_EQ(fs_back.sum_latency, 12345);
    PW_ASSERT_EQ(fs_back.sample_count, 50);

    pw_card_backend_close(&b);
    unlink(path);
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

static void test_ipc_framing(void) {
    /* Round-trip a length-prefixed frame through a socketpair. */
    int sp[2];
    PW_ASSERT(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0);

    const char *msg = "{\"rpc\":\"version\"}";
    PW_ASSERT_EQ(pw_ipc_write_frame(sp[0], msg, strlen(msg)), PW_OK);

    char   rx[256] = {0};
    size_t got = 0;
    PW_ASSERT_EQ(pw_ipc_read_frame(sp[1], rx, sizeof(rx), &got), PW_OK);
    PW_ASSERT_EQ(got, strlen(msg));
    PW_ASSERT(memcmp(msg, rx, got) == 0);

    close(sp[0]); close(sp[1]);
}

static void test_ipc_listen_connect(void) {
    /* Bind a socket via pw_ipc_listen, connect to it with
     * pw_ipc_connect, round-trip a frame. Honor $TMPDIR so the test runs in
     * sandboxes/CI where /tmp is not bindable; fall back to /tmp. If the
     * resulting path would exceed sun_path, quietly skip (portability, not a
     * code bug -- fill_sockaddr_un rejects over-length paths, covered by
     * test_ipc_path_too_long). */
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    char path[108];
    int n = snprintf(path, sizeof(path), "%s/pw-ipc-test-%d.sock",
                     tmp, (int)getpid());
    if (n < 0 || (size_t)n >= sizeof(path)) {
        printf("    (ipc_listen_connect skipped: TMPDIR too long for sun_path)\n");
        return;
    }

    /* On failure, surface errno + the offending path so a sandbox/perms
     * problem (bind EACCES/EROFS, connect ECONNREFUSED) is triaged from the
     * test log instead of just "PW_E_IO". */
    int srv = -1;
    pw_status lr = pw_ipc_listen(path, 0600, &srv);
    /* Some sandboxes (seccomp/permission-restricted CI) deny AF_UNIX bind()
     * outright with EPERM/EACCES/EROFS regardless of directory. That is an
     * environment capability limit, not a code fault, so skip like the TAP
     * test does on missing CAP_NET_ADMIN. Any OTHER errno still fails the
     * assert (a real bind regression -- e.g. EADDRINUSE/ENOENT -- is caught). */
    if (lr != PW_OK && (errno == EPERM || errno == EACCES || errno == EROFS)) {
        printf("    (ipc_listen_connect skipped: AF_UNIX bind denied by "
               "environment: %s)\n", strerror(errno));
        return;
    }
    if (lr != PW_OK)
        printf("    ipc_listen(%s) failed: %s (errno=%d %s)\n",
               path, pw_strerror(lr), errno, strerror(errno));
    PW_ASSERT_EQ(lr, PW_OK);
    PW_ASSERT(srv >= 0);

    int cli = -1;
    pw_status cr = pw_ipc_connect(path, &cli);
    if (cr != PW_OK)
        printf("    ipc_connect(%s) failed: %s (errno=%d %s)\n",
               path, pw_strerror(cr), errno, strerror(errno));
    PW_ASSERT_EQ(cr, PW_OK);

    int conn = accept(srv, NULL, NULL);
    PW_ASSERT(conn >= 0);

    const char *msg = "hello";
    PW_ASSERT_EQ(pw_ipc_write_frame(cli, msg, strlen(msg)), PW_OK);

    char  rx[64] = {0};
    size_t got = 0;
    PW_ASSERT_EQ(pw_ipc_read_frame(conn, rx, sizeof(rx), &got), PW_OK);
    PW_ASSERT_EQ(got, strlen(msg));
    PW_ASSERT(memcmp(msg, rx, got) == 0);

    close(conn); close(cli); close(srv);
    unlink(path);
}

static void test_ipc_path_too_long(void) {
    /* A path longer than sockaddr_un.sun_path (~108 B) must be REJECTED, not
     * silently truncated (which would bind/connect to a different socket). */
    char path[300];
    memset(path, 'x', sizeof(path) - 1);
    path[0] = '/';
    path[sizeof(path) - 1] = '\0';
    int fd = -1;
    PW_ASSERT_EQ(pw_ipc_listen(path, 0600, &fd), PW_E_OUT_OF_RANGE);
    PW_ASSERT_EQ(pw_ipc_connect(path, &fd), PW_E_OUT_OF_RANGE);
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

    /* Query live kernel state (used by the tap.stats RPC). The netdev exists
     * and was just brought up, so it must be found and admin_up. */
    struct pw_tap_state ts;
    PW_ASSERT_EQ(pw_tap_query(actual_name, &ts), PW_OK);
    PW_ASSERT(ts.admin_up);
    PW_ASSERT(ts.n_addrs >= 0 && ts.n_addrs <= PW_TAP_ADDR_MAX);
    /* A non-existent interface must not be reported as found. */
    PW_ASSERT(pw_tap_query("pw-no-such-if-xyz", &ts) != PW_OK);

    pw_tap_close(fd);
    /* After fd close (no persist), the device should be gone. */
    if (stat(sys_path, &st) == 0) {
        printf("    (note: TAP %s still present after close)\n", actual_name);
    }
}

typedef void (*test_fn)(void);
struct test_case { const char *name; test_fn fn; };

/* The JSON schema for the YAML config is informative (the C
 * validator is authoritative), but it must at least be well-formed
 * JSON with the structural keys the docs reference. This catches
 * accidental edits that break the schema file for editor plugins
 * that consume it (vscode-yaml, etc.). */
static void test_yaml_schema_well_formed(void) {
    static const char *paths[] = {
        "libpacketwyrm/schema/packetwyrm.schema.json",
        "../libpacketwyrm/schema/packetwyrm.schema.json",
        "../../sw/libpacketwyrm/schema/packetwyrm.schema.json",
        "sw/libpacketwyrm/schema/packetwyrm.schema.json",
    };
    char buf[65536];
    size_t n = 0;
    for (size_t k = 0; k < sizeof(paths)/sizeof(*paths); k++) {
        FILE *fp = fopen(paths[k], "rb");
        if (!fp) continue;
        n = fread(buf, 1, sizeof(buf), fp);
        fclose(fp);
        if (n > 0) break;
    }
    PW_ASSERT(n > 0);
    if (n == 0) return;

    struct json_tokener *tok  = json_tokener_new();
    struct json_object  *root = json_tokener_parse_ex(tok, buf, (int)n);
    json_tokener_free(tok);
    PW_ASSERT(root != NULL);
    if (!root) return;

    struct json_object *jx;
    PW_ASSERT(json_object_object_get_ex(root, "$schema", &jx));
    PW_ASSERT(json_object_object_get_ex(root, "title",   &jx));
    PW_ASSERT(json_object_object_get_ex(root, "$defs",   &jx));
    PW_ASSERT(json_object_object_get_ex(root, "properties", &jx));
    /* spot-check that the expected top-level config keys are
     * declared so editors that consume the schema can complete on
     * them. */
    struct json_object *props = jx;
    PW_ASSERT(json_object_object_get_ex(props, "system",             &jx));
    PW_ASSERT(json_object_object_get_ex(props, "cards",              &jx));
    PW_ASSERT(json_object_object_get_ex(props, "logical_interfaces", &jx));
    PW_ASSERT(json_object_object_get_ex(props, "flows",              &jx));
    json_object_put(root);
}

int main(void) {
    struct test_case cases[] = {
        { "tap_name", test_tap_name },
        { "parse_u64_hardening", test_parse_u64_hardening },
        { "validate_lif_name_rules", test_validate_lif_name_rules },
        { "parse_single_card", test_parse_single_card },
        { "accept_cross_card_latency", test_accept_cross_card_latency },
        { "config_split_env_test", test_config_split_env_test },
        { "accept_xcard_mixed_same_card", test_accept_xcard_mixed_same_card },
        { "accept_xcard_two_tx_sources", test_accept_xcard_two_tx_sources },
        { "traffic_validation", test_traffic_validation },
        { "rate_pps_compiles_nonzero", test_rate_pps_compiles_nonzero },
        { "min_legal_frame_clamp", test_min_legal_frame_clamp },
        { "punt_narrowing", test_punt_narrowing },
        { "punt_ipv6", test_punt_ipv6 },
        { "reject_dup_card", test_reject_dup_card },
        { "reject_dup_gport", test_reject_dup_gport },
        { "reject_unknown_gport_in_flow", test_reject_unknown_gport_in_flow },
        { "resolve_port_multi_card", test_resolve_port_multi_card },
        { "cross_card_flow_compiles", test_cross_card_flow_compiles },
        { "forward_rule_compiles", test_forward_rule_compiles },
        { "forward_ipv6_match_compiles", test_forward_ipv6_match_compiles },
        { "forward_comparator_exhaustion", test_forward_comparator_exhaustion },
        { "header_classify_ipv6_prefix", test_header_classify_ipv6_prefix },
        { "ipv6_flow_compiles", test_ipv6_flow_compiles },
        { "ipv6_modifier_128", test_ipv6_modifier_128 },
        { "tcp_flow_compiles", test_tcp_flow_compiles },
        { "udp_tcp_mutually_exclusive", test_udp_tcp_mutually_exclusive },
        { "reject_cross_card_forward", test_reject_cross_card_forward },
        { "flow_field_modifiers", test_flow_field_modifiers },
        { "background_and_match_mask", test_background_and_match_mask },
        { "header_classify_compiles", test_header_classify_compiles },
        { "header_classify_mask_collision", test_header_classify_mask_collision },
        { "encap_flow_compiles", test_encap_flow_compiles },
        { "frame_templates", test_frame_templates },
        { "frame_template_rejects", test_frame_template_rejects },
        { "fake_backend", test_fake_backend },
        { "fake_csr_window_recording", test_fake_csr_window_recording },
        { "program_card_tables", test_program_card_tables },
        { "bar_backend_path", test_bar_backend_path },
        { "bar_backend_window_writes", test_bar_backend_window_writes },
        { "bar_backend_stats_reads", test_bar_backend_stats_reads },
        { "pci_discover_no_match", test_pci_discover_no_match },
        { "vfio_open_bogus", test_vfio_open_bogus },
        { "fake_backend_slow_path", test_fake_backend_slow_path },
        { "host_plane_socketpair", test_host_plane_socketpair },
        { "tap_basic", test_tap_basic },
        { "host_plane_with_real_tap", test_host_plane_with_real_tap },
        { "ipc_framing", test_ipc_framing },
        { "ipc_listen_connect", test_ipc_listen_connect },
        { "ipc_path_too_long", test_ipc_path_too_long },
        { "yaml_schema_well_formed", test_yaml_schema_well_formed },
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        int before = g_fail;
        cases[i].fn();
        printf("  %-40s %s\n", cases[i].name, g_fail == before ? "ok" : "FAIL");
    }
    printf("%d/%d assertions passed, %d failed\n", g_total - g_fail, g_total, g_fail);
    return g_fail == 0 ? 0 : 1;
}
