#!/usr/bin/env bash
# Step 6: the L-G2 outcome: one cluster_uuid on all nodes, green, replicas 1,
# and the document counts recorded before growth.
#
# Usage: step-6-verify.sh
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

need_running es01 es02 es03
assert_same_cluster es01 es02 es03
say "all three nodes report cluster_uuid $(recorded_uuid)"
health=$(es_ok es01 GET /_cluster/health </dev/null | jq -r '"\(.status) \(.number_of_nodes)"')
[ "$health" = "green 3" ] || die "health is $health, expected green 3"
say "green, 3 nodes, voting configuration size $(voters)"
want=$(env_value GROW_SEED_COUNTS)
got=$(app_counts es01 | paste -sd, -)
[ "$want" = "$got" ] || die "document counts $got differ from those recorded before growth: $want (expected if the application wrote meanwhile)"
say "document counts equal to before growth: $got"
