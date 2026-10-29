#!/usr/bin/env bash
# Step 4: with three nodes in the cluster, gives app-* one replica (template and
# existing indices) and waits for green.
#
# Usage: step-4-replicas.sh
#
# Until this step every shard has a single copy, so losing any node that holds
# one loses data. Check disk first: replicas double the space app-* needs.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

need_running es01 es02 es03
assert_same_cluster es01 es02 es03
[ "$(voters)" = 3 ] || die "voting configuration has $(voters) nodes, expected 3"

es_ok es01 GET '/_cat/allocation?v&h=node,shards,disk.indices,disk.used,disk.avail,disk.percent' </dev/null
say "index template app: 1 replica"
es_ok es01 PUT /_index_template/app >/dev/null <<'JSON'
{
  "index_patterns": ["app-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": 1}
  }
}
JSON
say "existing app-* indices: 1 replica"
es_ok es01 PUT '/app-*/_settings' >/dev/null <<'JSON'
{"index.number_of_replicas": 1}
JSON
start=$SECONDS
es_ok es01 GET '/_cluster/health?wait_for_status=green&timeout=300s' </dev/null >/dev/null ||
	die "not green within 300s: $(es_ok es01 GET /_cluster/health </dev/null)"
say "green after $((SECONDS - start))s"
es_ok es01 GET '/_cat/shards/app-*?h=index,prirep,state,node&s=index' </dev/null
