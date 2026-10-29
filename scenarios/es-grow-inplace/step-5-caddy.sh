#!/usr/bin/env bash
# Step 5: recreates Caddy from compose.yaml so it proxies to all three nodes.
#
# Usage: step-5-caddy.sh
#
# Refuses unless all three nodes report the recorded cluster_uuid: Caddy must
# never balance across two clusters.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

need_running es01 es02 es03
assert_same_cluster es01 es02 es03
start=$SECONDS
"${compose[@]}" up -d --no-deps --wait caddy
say "Caddy recreated in $((SECONDS - start))s, upstreams es01 es02 es03"
