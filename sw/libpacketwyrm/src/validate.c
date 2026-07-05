/* Static validation: duplicates, dangling references, cross-card
 * latency requests. No FPGA required. */

#include "packetwyrm/config.h"
#include "packetwyrm/tap.h"   /* PW_TAP_IFNAME_MAX (TAP netdev name limit) */

#include <stdio.h>
#include <string.h>

static void diag(struct pw_diag *d, pw_status code, const char *path, const char *msg) {
    if (!d) return;
    d->code = code;
    snprintf(d->path, sizeof(d->path), "%s", path);
    snprintf(d->message, sizeof(d->message), "%s", msg);
}

pw_status pw_config_validate(const struct pw_config *cfg, struct pw_diag *d) {
    if (!cfg) return PW_E_INVAL;

    /* card duplicates */
    for (size_t i = 0; i < cfg->n_cards; i++) {
        for (size_t j = i + 1; j < cfg->n_cards; j++) {
            if (cfg->cards[i].id == cfg->cards[j].id) {
                char p[64]; snprintf(p, sizeof(p), "cards[%zu].id", j);
                diag(d, PW_E_DUP_CARD_ID, p, "duplicate card id");
                return PW_E_DUP_CARD_ID;
            }
            if (strcmp(cfg->cards[i].pci, cfg->cards[j].pci) == 0) {
                char p[64]; snprintf(p, sizeof(p), "cards[%zu].pci", j);
                diag(d, PW_E_DUP_CARD_ID, p, "duplicate PCI BDF");
                return PW_E_DUP_CARD_ID;
            }
        }
    }

    /* global_port duplicates across all cards */
    for (size_t i = 0; i < cfg->n_cards; i++) {
        const struct pw_card *ci = &cfg->cards[i];
        for (size_t pi = 0; pi < ci->n_ports; pi++) {
            for (size_t j = i; j < cfg->n_cards; j++) {
                const struct pw_card *cj = &cfg->cards[j];
                for (size_t pj = (j == i) ? pi + 1 : 0; pj < cj->n_ports; pj++) {
                    if (ci->ports[pi].global_port == cj->ports[pj].global_port) {
                        char p[80]; snprintf(p, sizeof(p), "cards[%zu].ports[%zu].global_port", j, pj);
                        diag(d, PW_E_DUP_GLOBAL_PORT, p, "duplicate global_port");
                        return PW_E_DUP_GLOBAL_PORT;
                    }
                }
            }
        }
        /* duplicate local_port within a card */
        for (size_t pi = 0; pi < ci->n_ports; pi++) {
            for (size_t pj = pi + 1; pj < ci->n_ports; pj++) {
                if (ci->ports[pi].local_port == ci->ports[pj].local_port) {
                    char p[80]; snprintf(p, sizeof(p), "cards[%zu].ports[%zu].local_port", i, pj);
                    diag(d, PW_E_DUP_GLOBAL_PORT, p, "duplicate local_port within card");
                    return PW_E_DUP_GLOBAL_PORT;
                }
            }
        }
    }

    /* logical_if id + name duplicates, port resolution */
    for (size_t i = 0; i < cfg->n_logical_if; i++) {
        /* The name becomes the Linux TAP netdev name, so it must fit IFNAMSIZ
         * (PW_TAP_IFNAME_MAX; the TAP layer truncates at 15 chars) or the
         * created device won't match the configured name -- the daemon would
         * bind a truncated name and tools would wait for the full one. */
        if (strlen(cfg->logical_if[i].name) >= PW_TAP_IFNAME_MAX) {
            char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].name", i);
            diag(d, PW_E_INVAL, p,
                 "logical_if name too long for a TAP device (max 15 chars)");
            return PW_E_INVAL;
        }
        /* `netns` is parsed but the TAP layer (pw_tap_*) is not namespace-aware
         * yet -- it operates in the daemon's own netns. Reject a non-empty value
         * rather than silently ignore it (which would leave the TAP in the wrong
         * namespace). Lab tooling that needs a netns moves the TAP externally. */
        if (cfg->logical_if[i].netns[0] != '\0') {
            char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].netns", i);
            diag(d, PW_E_INVAL, p,
                 "logical_if netns is not yet supported (TAP stays in the daemon's "
                 "namespace); move the TAP externally or omit netns");
            return PW_E_INVAL;
        }
        for (size_t j = i + 1; j < cfg->n_logical_if; j++) {
            if (cfg->logical_if[i].id == cfg->logical_if[j].id) {
                char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].id", j);
                diag(d, PW_E_DUP_LOGICAL_IF, p, "duplicate logical_if id");
                return PW_E_DUP_LOGICAL_IF;
            }
            /* Distinct logical_ifs must have distinct names: each maps to its
             * own TAP netdev, and two with the same name would collide (create
             * failure or an unintended attach to the same device). */
            if (strcmp(cfg->logical_if[i].name, cfg->logical_if[j].name) == 0) {
                char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].name", j);
                diag(d, PW_E_DUP_LOGICAL_IF, p, "duplicate logical_if name");
                return PW_E_DUP_LOGICAL_IF;
            }
        }
        struct pwfpga_port_ref ref;
        if (pw_config_resolve_port(cfg, cfg->logical_if[i].global_port, &ref) != PW_OK) {
            char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].global_port", i);
            diag(d, PW_E_UNKNOWN_GLOBAL_PORT, p, "global_port is not declared in any card");
            return PW_E_UNKNOWN_GLOBAL_PORT;
        }
    }

    /* flow duplicates, references, cross-card latency */
    for (size_t i = 0; i < cfg->n_flows; i++) {
        const struct pw_flow *f = &cfg->flows[i];
        for (size_t j = i + 1; j < cfg->n_flows; j++) {
            if (f->id == cfg->flows[j].id) {
                char p[64]; snprintf(p, sizeof(p), "flows[%zu].id", j);
                diag(d, PW_E_DUP_FLOW_ID, p, "duplicate flow id");
                return PW_E_DUP_FLOW_ID;
            }
        }
        struct pwfpga_port_ref tx, rx;
        if (pw_config_resolve_port(cfg, f->tx_global_port, &tx) != PW_OK) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].tx_global_port", i);
            diag(d, PW_E_UNKNOWN_GLOBAL_PORT, p, "tx_global_port is not declared in any card");
            return PW_E_UNKNOWN_GLOBAL_PORT;
        }
        if (pw_config_resolve_port(cfg, f->rx_global_port, &rx) != PW_OK) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].rx_global_port", i);
            diag(d, PW_E_UNKNOWN_GLOBAL_PORT, p, "rx_global_port is not declared in any card");
            return PW_E_UNKNOWN_GLOBAL_PORT;
        }
        if (f->logical_if_id != 0 && !pw_config_logical_if_by_id(cfg, f->logical_if_id)) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].logical_if_id", i);
            diag(d, PW_E_UNKNOWN_LOGICAL_IF, p, "logical_if_id is not declared");
            return PW_E_UNKNOWN_LOGICAL_IF;
        }
        /* Cross-card latency/jitter is now supported: the daemon offset-corrects
         * the RX checker latency using the J5 GPIO time-sync (and jitter is a
         * diff of consecutive latencies, so the inter-card offset cancels). This
         * requires the cards' J5 headers to be wired (cross-chassis sync); if
         * they are not, the corrected latency is meaningless -- a HARDWARE setup
         * concern the config validator can't detect, not a config error. */
        bool same_card = (tx.card_id == rx.card_id);
        (void)same_card;
        /* traffic exclusivity */
        bool has_fixed = f->traffic.frame_len_fixed_set;
        bool has_range = (f->traffic.frame_len_max != 0);
        if (has_fixed && has_range) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].traffic.frame_len*", i);
            diag(d, PW_E_INVAL, p, "set either frame_len or frame_len_min/max/step, not both");
            return PW_E_INVAL;
        }
        if (!has_fixed && !has_range) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].traffic", i);
            diag(d, PW_E_MISSING_FIELD, p, "frame_len or frame_len_min/max required");
            return PW_E_MISSING_FIELD;
        }
        if (f->traffic.rate_bps == 0 && f->traffic.rate_pps == 0) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].traffic", i);
            diag(d, PW_E_MISSING_FIELD, p, "rate_bps or rate_pps required");
            return PW_E_MISSING_FIELD;
        }
        if (f->traffic.rate_bps != 0 && f->traffic.rate_pps != 0) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].traffic", i);
            diag(d, PW_E_INVAL, p, "set either rate_bps or rate_pps, not both");
            return PW_E_INVAL;
        }
        /* Raw frame templates (raw/ip/eth) carry no PacketWyrm test header, so
         * per-flow loss/latency/jitter/sequence measurement is impossible and
         * RX must classify on header fields (the flow-id map keys on the test
         * header, which isn't there). Encapsulation also needs the inner test
         * frame, so it is not combinable with a raw template. */
        if (f->traffic.frame_template != PW_FRAME_TEMPLATE_TEST) {
            char p[80];
            if (f->meas.loss || f->meas.latency || f->meas.jitter) {
                snprintf(p, sizeof(p), "flows[%zu].measurements", i);
                diag(d, PW_E_INVAL, p, "raw frame templates (raw/ip/eth) carry no test "
                     "header -- loss/latency/jitter cannot be measured; remove measurements");
                return PW_E_INVAL;
            }
            if (!f->classify_header) {
                snprintf(p, sizeof(p), "flows[%zu].classify", i);
                diag(d, PW_E_INVAL, p, "raw frame templates (raw/ip/eth) have no test-header "
                     "flow_id -- set classify: header");
                return PW_E_INVAL;
            }
            if (f->encap.present) {
                snprintf(p, sizeof(p), "flows[%zu].encap", i);
                diag(d, PW_E_INVAL, p, "encapsulation is not supported with a raw frame template");
                return PW_E_INVAL;
            }
        }
        /* Background (load) flows are TX-only: the compiler emits no RX row /
         * classifier and allocates no RX checker slot, so loss/latency/jitter
         * cannot be measured. Reject the combination up front rather than
         * silently returning zero/absent measurements at runtime. */
        if (f->background && (f->meas.loss || f->meas.latency || f->meas.jitter)) {
            char p[80]; snprintf(p, sizeof(p), "flows[%zu].measurements", i);
            diag(d, PW_E_INVAL, p, "background flows are TX-only and cannot request "
                 "measurements (loss/latency/jitter); remove measurements or background");
            return PW_E_INVAL;
        }
    }

    /* (Stage 2: per-flow lat_correction lifts the old stage-1 restriction --
     * one RX card may now mix same-card and cross-card flows, and take cross-card
     * traffic from multiple TX cards, each flow getting its own correction slot.
     * No cross-card-topology constraint to enforce here any more.) */

    /* forward rules: both ports resolve and live on the same card (the
     * classifier is per-card; egress_local_port is a local port). */
    for (size_t i = 0; i < cfg->n_forwards; i++) {
        const struct pw_forward_rule *fr = &cfg->forwards[i];
        struct pwfpga_port_ref ing, egr;
        if (pw_config_resolve_port(cfg, fr->ingress_port, &ing) != PW_OK) {
            char p[80]; snprintf(p, sizeof(p), "forwards[%zu].ingress_port", i);
            diag(d, PW_E_UNKNOWN_GLOBAL_PORT, p, "ingress_port does not resolve to a card port");
            return PW_E_UNKNOWN_GLOBAL_PORT;
        }
        if (pw_config_resolve_port(cfg, fr->egress_port, &egr) != PW_OK) {
            char p[80]; snprintf(p, sizeof(p), "forwards[%zu].egress_port", i);
            diag(d, PW_E_UNKNOWN_GLOBAL_PORT, p, "egress_port does not resolve to a card port");
            return PW_E_UNKNOWN_GLOBAL_PORT;
        }
        if (ing.card_id != egr.card_id) {
            char p[80]; snprintf(p, sizeof(p), "forwards[%zu]", i);
            diag(d, PW_E_INVAL, p, "ingress and egress ports must be on the same card");
            return PW_E_INVAL;
        }
    }

    if (d) d->code = PW_OK;
    return PW_OK;
}
