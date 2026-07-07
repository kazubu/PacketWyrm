#!/usr/bin/env bash
# Validate the example PacketWyrm YAML configurations against the
# JSON schema in sw/libpacketwyrm/schema/packetwyrm.schema.json.
#
# The schema is informative (the C validator in libpacketwyrm is
# authoritative). This script catches drift between the schema and
# the docs / examples, and gives editor plugins like vscode-yaml a
# spec to autocomplete against.
#
# Dependencies: python3 with `jsonschema` and `PyYAML`. If either is
# missing the script prints a skip notice and exits 0.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
schema=$root/sw/libpacketwyrm/schema/packetwyrm.schema.json

# --strict (or PW_SCHEMA_STRICT=1): treat missing deps as a FAILURE rather than
# a skip. CI passes --strict (it installs the deps), so a future CI change that
# drops python3-yaml/jsonschema fails loudly instead of silently skipping drift
# detection. Local runs without the flag still skip gracefully.
strict=0
[ "${1:-}" = "--strict" ] && strict=1
[ "${PW_SCHEMA_STRICT:-0}" = "1" ] && strict=1
miss() {
    if [ "$strict" = "1" ]; then echo "FAIL: $1"; exit 1; else echo "skip: $1"; exit 0; fi
}

if ! command -v python3 >/dev/null 2>&1; then
    miss "python3 not found"
fi
if ! python3 -c "import yaml, jsonschema" >/dev/null 2>&1; then
    miss "install python3-yaml and python3-jsonschema to validate"
fi

if [ ! -f "$schema" ]; then
    echo "FAIL: schema not found at $schema"
    exit 1
fi

failed=0
checked=0
# Validate every example config, not just the canonical two -- the schema is
# split-aware (env-only / test-only / combined all valid), so drift in any
# example (new flow/forward key, missing schema property) is caught here.
# Enumerate RECURSIVELY: the lab-*-2node subdirectories carry packetwyrm.yaml
# examples too. Files named lab.yaml are pktwyrm-tinet lab specs (a different
# format with its own validator in tools/pktwyrm-tinet), not PacketWyrm
# configs, so they are excluded.
while IFS= read -r cfg; do
    checked=$((checked + 1))
    if python3 - "$schema" "$cfg" <<'PY'
import json, sys, yaml, jsonschema
schema = json.load(open(sys.argv[1]))
cfg    = yaml.safe_load(open(sys.argv[2]))
jsonschema.validate(cfg, schema)
PY
    then
        echo "ok: ${cfg#"$root"/configs/examples/}"
    else
        echo "FAIL: ${cfg#"$root"/configs/examples/}"
        failed=1
    fi
done < <(find "$root/configs/examples" -type f -name '*.yaml' ! -name 'lab.yaml' | sort)

# An empty enumeration means the script is looking in the wrong place (moved
# tree, bad glob) -- that must be a loud failure, not a silent pass.
if [ "$checked" -eq 0 ]; then
    echo "FAIL: no example configs found under $root/configs/examples"
    exit 1
fi

exit $failed
