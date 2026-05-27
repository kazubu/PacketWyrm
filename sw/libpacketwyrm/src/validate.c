/* Static validation: duplicates, dangling references, cross-card
 * latency requests. No FPGA required. */

#include "packetwyrm/config.h"

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
        for (size_t j = i + 1; j < cfg->n_logical_if; j++) {
            if (cfg->logical_if[i].id == cfg->logical_if[j].id) {
                char p[80]; snprintf(p, sizeof(p), "logical_interfaces[%zu].id", j);
                diag(d, PW_E_DUP_LOGICAL_IF, p, "duplicate logical_if id");
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
        bool same_card = (tx.card_id == rx.card_id);
        if (!same_card && (f->meas.latency || f->meas.jitter)) {
            char p[96]; snprintf(p, sizeof(p), "flows[%zu].measurements.latency", i);
            diag(d, PW_E_CROSS_CARD_LATENCY, p,
                 "cross-card flow does not support latency/jitter (no clock sync yet)");
            return PW_E_CROSS_CARD_LATENCY;
        }
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
    }

    if (d) d->code = PW_OK;
    return PW_OK;
}
