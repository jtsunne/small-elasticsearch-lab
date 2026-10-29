#!/usr/bin/env bash
# Step 4: restores a snapshot from "grow" into the new cluster with one replica,
# then compares document counts with es00.
#
# Usage: step-4-restore.sh SNAPSHOT [--replace]
#   SNAPSHOT    grow-1 (rehearsal) or grow-final (cutover copy)
#   --replace   delete app-* on the NEW cluster before restoring; needed for
#               the second restore. Never touches es00.
#
# Restores the security feature state too, which closes and overwrites the new
# cluster's security indices: users, roles and API keys become es00's.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

snapshot=
replace=
for a in "$@"; do
	case $a in
	--replace) replace=1 ;;
	-h | --help) sed -n '2,12p' "$0"; exit 0 ;;
	-*) die "unknown argument $a" ;;
	*) snapshot=$a ;;
	esac
done
[[ $snapshot =~ ^grow-(1|final)$ ]] || die "usage: step-4-restore.sh grow-1|grow-final [--replace]"

need_running es00 es01 es02 es03
assert_new_cluster
[ "$(es_status es01 GET "/_snapshot/grow/$snapshot")" = 200 ] || die "snapshot $snapshot not found in repository grow on the new cluster"

existing=$(es_ok es01 GET '/_cat/indices/app-*?format=json&h=index' </dev/null | jq -r '.[].index' | sort | paste -sd' ' -)
if [ -n "$existing" ]; then
	[ -n "$replace" ] || die "the new cluster already has: $existing; rerun with --replace to delete them there first"
	say "deleting on the NEW cluster only (es-grow-new, $(cluster_uuid es01)): $existing"
	for idx in $existing; do
		es_ok es01 DELETE "/$idx" </dev/null >/dev/null
	done
fi

# The template is not in the snapshot (no global state); recreate it here with
# the replica count this cluster needs.
say "index template app on the new cluster: 1 shard, 1 replica"
es_ok es01 PUT /_index_template/app >/dev/null <<'JSON'
{
  "index_patterns": ["app-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": 1}
  }
}
JSON

say "restoring $snapshot: app-*, security feature state, replicas 1, write block cleared"
start=$SECONDS
es_ok es01 POST "/_snapshot/grow/$snapshot/_restore?wait_for_completion=true" <<'JSON' >/dev/null
{
  "indices": "app-*",
  "include_global_state": false,
  "feature_states": ["security"],
  "index_settings": {"index.number_of_replicas": 1, "index.blocks.write": false}
}
JSON
READY_TIMEOUT=${READY_TIMEOUT:-300} wait_ready es01 '/_cluster/health/app-*?wait_for_status=green&timeout=30s' ||
	die "restored indices did not reach green"
say "restore and replica recovery took $((SECONDS - start))s"

old=$(app_counts es00)
new=$(app_counts es01)
printf '%-12s %10s %10s\n' index es00 new
join -a1 -a2 -e missing -o 0,1.2,2.2 <(printf '%s\n' "$old") <(printf '%s\n' "$new") |
	while read -r idx a b; do printf '%-12s %10s %10s\n' "$idx" "$a" "$b"; done
if [ "$old" = "$new" ]; then
	say "document counts match"
else
	say "document counts differ: expected after grow-1 if es00 took writes since; not acceptable after grow-final"
	[ "$snapshot" != grow-final ] || exit 1
fi
es_ok es01 GET '/app-*/_settings?filter_path=*.settings.index.number_of_replicas,*.settings.index.blocks' </dev/null | jq -c .
