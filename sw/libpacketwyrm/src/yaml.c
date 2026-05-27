/* libyaml-backed parser producing the pw_yaml_node AST declared in
 * yaml.h. libyaml handles all the lexical / indentation work; we only
 * walk its event stream and build our small node tree. */

#include "yaml.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <yaml.h>

static char *pw_xstrdup_n(const char *s, size_t n) {
    char *r = (char *)malloc(n + 1);
    if (!r) return NULL;
    if (n) memcpy(r, s, n);
    r[n] = '\0';
    return r;
}

static pw_yaml_node *pw_yaml_node_new(pw_yaml_kind k, int line) {
    pw_yaml_node *n = (pw_yaml_node *)calloc(1, sizeof(*n));
    if (!n) return NULL;
    n->kind = k;
    n->line = line;
    return n;
}

void pw_yaml_free(pw_yaml_node *root) {
    if (!root) return;
    switch (root->kind) {
    case PW_YAML_SCALAR:
        free(root->u.scalar.value);
        break;
    case PW_YAML_MAP:
        for (size_t i = 0; i < root->u.map.n; i++) {
            free(root->u.map.items[i].key);
            pw_yaml_free(root->u.map.items[i].value);
        }
        free(root->u.map.items);
        break;
    case PW_YAML_SEQ:
        for (size_t i = 0; i < root->u.seq.n; i++)
            pw_yaml_free(root->u.seq.items[i]);
        free(root->u.seq.items);
        break;
    }
    free(root);
}

const pw_yaml_node *pw_yaml_map_get(const pw_yaml_node *m, const char *key) {
    if (!m || m->kind != PW_YAML_MAP) return NULL;
    for (size_t i = 0; i < m->u.map.n; i++)
        if (strcmp(m->u.map.items[i].key, key) == 0)
            return m->u.map.items[i].value;
    return NULL;
}

const char *pw_yaml_scalar(const pw_yaml_node *n) {
    if (!n || n->kind != PW_YAML_SCALAR) return NULL;
    return n->u.scalar.value;
}

static void set_err(pw_yaml_err *err, int line, const char *fmt, ...) {
    if (!err || err->message[0]) return;
    err->line = line;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err->message, sizeof(err->message), fmt, ap);
    va_end(ap);
}

static int map_append(pw_yaml_node *m, char *key, pw_yaml_node *v) {
    pw_yaml_pair *na = (pw_yaml_pair *)realloc(m->u.map.items,
                                                sizeof(pw_yaml_pair) * (m->u.map.n + 1));
    if (!na) return -1;
    m->u.map.items = na;
    m->u.map.items[m->u.map.n].key = key;
    m->u.map.items[m->u.map.n].value = v;
    m->u.map.n++;
    return 0;
}

static int seq_append(pw_yaml_node *s, pw_yaml_node *v) {
    pw_yaml_node **na = (pw_yaml_node **)realloc(s->u.seq.items,
                                                  sizeof(pw_yaml_node *) * (s->u.seq.n + 1));
    if (!na) return -1;
    s->u.seq.items = na;
    s->u.seq.items[s->u.seq.n++] = v;
    return 0;
}

/* Forward decls for the event-driven recursive descent. */
typedef struct {
    yaml_parser_t *p;
    pw_yaml_err   *err;
    int            failed;
} ctx_t;

static int next_event(ctx_t *c, yaml_event_t *ev) {
    if (!yaml_parser_parse(c->p, ev)) {
        set_err(c->err, (int)c->p->problem_mark.line + 1,
                "%s", c->p->problem ? c->p->problem : "yaml parse error");
        c->failed = 1;
        return 0;
    }
    return 1;
}

static pw_yaml_node *build_node(ctx_t *c, yaml_event_t *first);

static pw_yaml_node *build_scalar(yaml_event_t *ev) {
    pw_yaml_node *n = pw_yaml_node_new(PW_YAML_SCALAR, (int)ev->start_mark.line + 1);
    if (!n) return NULL;
    n->u.scalar.value = pw_xstrdup_n((const char *)ev->data.scalar.value,
                                     ev->data.scalar.length);
    if (!n->u.scalar.value) { free(n); return NULL; }
    return n;
}

static pw_yaml_node *build_sequence(ctx_t *c, yaml_event_t *start) {
    pw_yaml_node *seq = pw_yaml_node_new(PW_YAML_SEQ, (int)start->start_mark.line + 1);
    if (!seq) return NULL;
    while (1) {
        yaml_event_t ev;
        if (!next_event(c, &ev)) { pw_yaml_free(seq); return NULL; }
        if (ev.type == YAML_SEQUENCE_END_EVENT) { yaml_event_delete(&ev); return seq; }
        pw_yaml_node *child = build_node(c, &ev);
        yaml_event_delete(&ev);
        if (!child) { pw_yaml_free(seq); return NULL; }
        if (seq_append(seq, child) < 0) {
            pw_yaml_free(child); pw_yaml_free(seq); return NULL;
        }
    }
}

static pw_yaml_node *build_mapping(ctx_t *c, yaml_event_t *start) {
    pw_yaml_node *m = pw_yaml_node_new(PW_YAML_MAP, (int)start->start_mark.line + 1);
    if (!m) return NULL;
    while (1) {
        yaml_event_t kev;
        if (!next_event(c, &kev)) { pw_yaml_free(m); return NULL; }
        if (kev.type == YAML_MAPPING_END_EVENT) { yaml_event_delete(&kev); return m; }
        if (kev.type != YAML_SCALAR_EVENT) {
            set_err(c->err, (int)kev.start_mark.line + 1, "non-scalar mapping key not supported");
            yaml_event_delete(&kev); pw_yaml_free(m); return NULL;
        }
        char *key = pw_xstrdup_n((const char *)kev.data.scalar.value,
                                 kev.data.scalar.length);
        yaml_event_delete(&kev);
        if (!key) { pw_yaml_free(m); return NULL; }

        yaml_event_t vev;
        if (!next_event(c, &vev)) { free(key); pw_yaml_free(m); return NULL; }
        pw_yaml_node *vn = build_node(c, &vev);
        yaml_event_delete(&vev);
        if (!vn) { free(key); pw_yaml_free(m); return NULL; }
        if (map_append(m, key, vn) < 0) {
            free(key); pw_yaml_free(vn); pw_yaml_free(m); return NULL;
        }
    }
}

static pw_yaml_node *build_node(ctx_t *c, yaml_event_t *ev) {
    switch (ev->type) {
    case YAML_SCALAR_EVENT:
        return build_scalar(ev);
    case YAML_SEQUENCE_START_EVENT:
        return build_sequence(c, ev);
    case YAML_MAPPING_START_EVENT:
        return build_mapping(c, ev);
    case YAML_ALIAS_EVENT:
        set_err(c->err, (int)ev->start_mark.line + 1, "YAML anchors/aliases are not supported");
        c->failed = 1;
        return NULL;
    default:
        set_err(c->err, (int)ev->start_mark.line + 1, "unexpected YAML event");
        c->failed = 1;
        return NULL;
    }
}

pw_yaml_node *pw_yaml_parse(const char *text, size_t len, pw_yaml_err *err) {
    if (err) { err->message[0] = '\0'; err->line = 0; }

    yaml_parser_t p;
    if (!yaml_parser_initialize(&p)) {
        set_err(err, 0, "failed to initialize libyaml parser");
        return NULL;
    }
    yaml_parser_set_input_string(&p, (const unsigned char *)text, len);

    ctx_t c = { .p = &p, .err = err, .failed = 0 };
    pw_yaml_node *root = NULL;

    /* Walk stream-start, document-start, then a single value. */
    int seen_stream = 0, seen_doc = 0;
    while (!c.failed) {
        yaml_event_t ev;
        if (!next_event(&c, &ev)) break;
        switch (ev.type) {
        case YAML_STREAM_START_EVENT: seen_stream = 1; yaml_event_delete(&ev); break;
        case YAML_DOCUMENT_START_EVENT: seen_doc = 1; yaml_event_delete(&ev); break;
        case YAML_DOCUMENT_END_EVENT:
        case YAML_STREAM_END_EVENT:
            yaml_event_delete(&ev);
            goto done;
        default:
            if (!seen_stream || !seen_doc) {
                set_err(err, (int)ev.start_mark.line + 1, "unexpected YAML event before document");
                yaml_event_delete(&ev); c.failed = 1; break;
            }
            if (root) {
                set_err(err, (int)ev.start_mark.line + 1, "multiple top-level YAML documents not supported");
                yaml_event_delete(&ev); c.failed = 1; break;
            }
            root = build_node(&c, &ev);
            yaml_event_delete(&ev);
            if (!root) c.failed = 1;
            break;
        }
    }
done:
    yaml_parser_delete(&p);

    if (c.failed) {
        pw_yaml_free(root);
        return NULL;
    }
    if (!root) {
        /* Empty document: return an empty mapping so callers can treat it
         * uniformly. */
        root = pw_yaml_node_new(PW_YAML_MAP, 1);
    }
    return root;
}
