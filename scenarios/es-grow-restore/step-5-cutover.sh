#!/usr/bin/env bash
# Step 5: points Caddy at the new cluster and hands the repository to it.
#
# Usage: step-5-cutover.sh
#
# Refuses unless es00's app-* indices are write-blocked (step-2-snapshot.sh
# --final ran) and the new cluster holds the same document counts, so no write
# accepted by es00 can be missing on the new cluster. es00 keeps running
# untouched for rollback.sh.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

need_running es00 es01 es02 es03
assert_new_cluster

blocked=$(es_ok es00 GET '/app-*/_settings?filter_path=*.settings.index.blocks.write' </dev/null |
	jq -r '[.[] | .settings.index.blocks.write] | if length > 0 and all(. == "true") then "yes" else "no" end')
[ "$blocked" = yes ] || die "es00's app-* indices are not all write-blocked; run step-2-snapshot.sh --final and step-4-restore.sh grow-final --replace first"
[ "$(app_counts es00)" = "$(app_counts es01)" ] || die "document counts differ between es00 and the new cluster; restore grow-final again"

# Two clusters must never write to one repository: es00 lets go first.
say "unregistering repository grow on es00 (the files stay)"
es_ok es00 DELETE /_snapshot/grow </dev/null >/dev/null
say "registering repository grow on the new cluster as writable"
es_ok es01 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow"}}
JSON

say "switching Caddy to es01 es02 es03 (Caddy is recreated: a few seconds without the proxy)"
set_env ES_UPSTREAMS "es01:9200 es02:9200 es03:9200"
start=$SECONDS
"${compose[@]}" up -d --wait --no-deps caddy
say "Caddy back after $((SECONDS - start))s, now proxying to the new cluster"
say "run the checks: COMPOSE_PROFILES=new NODE_SERVICE=es01 tests/run-scenario.sh --keep-up es-grow-restore"
