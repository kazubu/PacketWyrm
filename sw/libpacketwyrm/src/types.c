#include "packetwyrm/types.h"

const char *pw_strerror(pw_status s) {
    switch (s) {
    case PW_OK:                      return "ok";
    case PW_E_INVAL:                 return "invalid argument";
    case PW_E_PARSE:                 return "parse error";
    case PW_E_DUP_CARD_ID:           return "duplicate card_id";
    case PW_E_DUP_GLOBAL_PORT:       return "duplicate global_port_id";
    case PW_E_DUP_LOGICAL_IF:        return "duplicate logical_if_id";
    case PW_E_DUP_FLOW_ID:           return "duplicate global_flow_id";
    case PW_E_UNKNOWN_CARD:          return "unknown card";
    case PW_E_UNKNOWN_GLOBAL_PORT:   return "unknown global_port_id";
    case PW_E_UNKNOWN_LOGICAL_IF:    return "unknown logical_if_id";
    case PW_E_CROSS_CARD_LATENCY:    return "cross-card flow does not support latency/jitter";
    case PW_E_MISSING_FIELD:         return "required field missing";
    case PW_E_OUT_OF_RANGE:          return "value out of range";
    case PW_E_NO_CARD:               return "no card with that PCI BDF";
    case PW_E_NO_RESOURCES:          return "out of resources (memory or table slot)";
    case PW_E_BACKEND:               return "backend error";
    case PW_E_IO:                    return "I/O error";
    case PW_E_OVERFLOW:              return "value overflow";
    case PW_E_DEGRADED:              return "card is degraded";
    case PW_E_NOT_IMPLEMENTED:       return "not implemented";
    }
    return "unknown pw_status";
}
