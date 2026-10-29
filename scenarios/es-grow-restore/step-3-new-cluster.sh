#!/usr/bin/env bash
# Step 3: starts the new three-node cluster es01..es03 next to es00 and
# registers the same repository there as read-only. Caddy still points at es00.
#
# Usage: step-3-new-cluster.sh
#
# Safe to run again. Generates transport certificates first if certs/ has none.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

if ! compgen -G "$dir/certs/*.pem" >/dev/null; then
	say "no certificates yet: running certs/gen-certs.sh"
	"$dir/certs/gen-certs.sh"
fi
need_running es00

say "starting es01, es02, es03 (cluster es-grow-new)"
"${compose[@]}" up -d --wait es01 es02 es03
es_ok es01 GET '/_cluster/health?wait_for_status=green&wait_for_nodes=3&timeout=120s' </dev/null >/dev/null
assert_new_cluster
say "es00 cluster_uuid $(cluster_uuid es00), new cluster_uuid $(cluster_uuid es01): two separate clusters, as intended"

# Only one cluster may write to a repository; until cutover that is es00.
say "registering repository grow on the new cluster as read-only"
es_ok es01 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow", "readonly": true}}
JSON
es_ok es01 POST /_snapshot/grow/_verify </dev/null | jq -c '.nodes | map_values(.name)'
es_ok es01 GET '/_snapshot/grow/_all' </dev/null | jq -r '.snapshots[] | "\(.snapshot) \(.state)"'
