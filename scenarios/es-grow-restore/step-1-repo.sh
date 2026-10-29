#!/usr/bin/env bash
# Step 1: registers the fs snapshot repository "grow" on es00 (writable) and
# verifies it. es00 already has path.repo in this lab; on a real node adding
# path.repo is a config change plus a restart, see README.md.
#
# Usage: step-1-repo.sh
#
# Safe to run again: registering the same settings twice changes nothing.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

need_running es00
say "registering repository grow on es00 (type fs, location grow under path.repo, writable)"
es_ok es00 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow"}}
JSON
say "verifying the repository from every node of es00's cluster"
es_ok es00 POST /_snapshot/grow/_verify </dev/null | jq -c '.nodes | map_values(.name)'
