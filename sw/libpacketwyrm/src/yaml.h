/* Tiny YAML parser sufficient for docs/design/yaml-schema.md.
 *
 * Supports:
 *   - block mappings: key: value
 *   - block sequences: - value | - key: value
 *   - nested blocks via indentation
 *   - scalars: bare strings, "double-quoted" strings, integers, booleans
 *   - line comments starting with #
 *
 * Anything outside this subset (flow style, anchors, multi-doc, tags)
 * is rejected. The parser is internal to libpacketwyrm. */
#ifndef PACKETWYRM_YAML_INTERNAL_H
#define PACKETWYRM_YAML_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    PW_YAML_SCALAR,
    PW_YAML_MAP,
    PW_YAML_SEQ,
} pw_yaml_kind;

typedef struct pw_yaml_node pw_yaml_node;
typedef struct pw_yaml_pair pw_yaml_pair;

struct pw_yaml_node {
    pw_yaml_kind kind;
    int          line;
    union {
        struct { char *value; }                          scalar;
        struct { pw_yaml_pair *items; size_t n; }        map;
        struct { pw_yaml_node **items; size_t n; }       seq;
    } u;
};

struct pw_yaml_pair {
    char         *key;
    pw_yaml_node *value;
};

typedef struct {
    char message[256];
    int  line;
} pw_yaml_err;

pw_yaml_node *pw_yaml_parse(const char *text, size_t len, pw_yaml_err *err);
void          pw_yaml_free(pw_yaml_node *root);

const pw_yaml_node *pw_yaml_map_get(const pw_yaml_node *m, const char *key);
const char         *pw_yaml_scalar(const pw_yaml_node *n);

#endif
