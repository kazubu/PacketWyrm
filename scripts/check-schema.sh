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

if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not found"
    exit 0
fi
if ! python3 -c "import yaml, jsonschema" >/dev/null 2>&1; then
    echo "skip: install python3-yaml and python3-jsonschema to validate"
    exit 0
fi

if [ ! -f "$schema" ]; then
    echo "FAIL: schema not found at $schema"
    exit 1
fi

failed=0
# Validate every example config, not just the canonical two -- the schema is
# split-aware (env-only / test-only / combined all valid), so drift in any
# example (new flow/forward key, missing schema property) is caught here.
shopt -s nullglob
for cfg in "$root"/configs/examples/*.yaml; do
    if [ ! -f "$cfg" ]; then continue; fi
    if python3 - "$schema" "$cfg" <<'PY'
import json, sys, yaml, jsonschema
schema = json.load(open(sys.argv[1]))
cfg    = yaml.safe_load(open(sys.argv[2]))
jsonschema.validate(cfg, schema)
PY
    then
        echo "ok: $(basename "$cfg")"
    else
        echo "FAIL: $(basename "$cfg")"
        failed=1
    fi
done

exit $failed
