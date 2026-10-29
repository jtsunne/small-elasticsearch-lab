#!/usr/bin/env bash
# Step 2: the one restart of es01. Recreates it from compose.yaml: discovery.type
# single-node removed, seed hosts es01..es03, transport TLS on, still alone.
# The data volume is kept, so the cluster_uuid must not change.
#
# Usage: step-2-restart-first.sh
#
# Downtime: from the stop until es01 answers again; the script prints it.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

need_running es01
want=$(recorded_uuid)
assert_same_cluster es01
if running es02 || running es03; then
	die "es02 or es03 is running; step 2 must run with es01 alone"
fi

say "recreating es01 with the cluster configuration (Caddy gets errors until it is back)"
start=$SECONDS
"${compose[@]}" up -d --no-deps --wait es01
READY_TIMEOUT=${READY_TIMEOUT:-300} wait_ready es01 '/_cluster/health?wait_for_status=yellow&timeout=5s' ||
	die "es01 not serving after the restart; check: docker compose logs es01"
say "es01 back after $((SECONDS - start))s"

got=$(cluster_uuid es01)
[ "$got" = "$want" ] || die "es01 reports cluster_uuid $got after the restart, expected $want; STOP: do not start other nodes, see README.md"
say "cluster_uuid unchanged ($got); voting configuration size $(voters)"
es_ok es01 GET '/_nodes/es01/settings?filter_path=nodes.*.settings.discovery,nodes.*.settings.xpack.security.transport.ssl.enabled' </dev/null | jq -c '.nodes[].settings'
