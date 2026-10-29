#!/usr/bin/env bash
# Step 3: starts one new node with an empty data path and checks that it joined
# es01's cluster. Run it for es02, then for es03.
#
# Usage: step-3-add-node.sh es02|es03 [--wipe]
#   --wipe   delete that node's existing data volume first. Never possible for
#            es01: its volume holds the only copy of the data.
#
# A new node must start with an empty data path: a node that ever joined or
# bootstrapped another cluster is locked to that cluster's UUID and is
# rejected. If the node shows up with a different cluster_uuid anyway, the
# script stops it at once.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

node=
wipe=
for a in "$@"; do
	case $a in
	--wipe) wipe=1 ;;
	-h | --help) sed -n '2,13p' "$0"; exit 0 ;;
	es02 | es03) node=$a ;;
	es01) die "es01 is the original node; this script only adds new ones" ;;
	*) die "unknown argument $a" ;;
	esac
done
[ -n "$node" ] || die "usage: step-3-add-node.sh es02|es03 [--wipe]"
vol=esdata${node#es}
[ "$vol" != esdata01 ] || die "refusing to touch esdata01"

need_running es01
assert_same_cluster es01
[ "$(es_ok es01 GET '/_nodes/es01/settings?filter_path=nodes.*.settings.discovery.type' </dev/null |
	jq -r '[.nodes[].settings.discovery.type][0] // "multi-node"')" != single-node ] ||
	die "es01 still runs with discovery.type single-node and rejects every join; run step-2-restart-first.sh"
if [ "$node" = es03 ] && ! running es02; then
	die "add es02 first"
fi

if running "$node"; then
	say "$node is already running"
else
	if volume_exists "$vol"; then
		[ -n "$wipe" ] || die "volume ${project}_$vol exists and may hold another cluster's state; rerun with --wipe to delete it"
		say "deleting ${project}_$vol (the new node's data path, not es01's)"
		"${compose[@]}" rm -f -s "$node" >/dev/null 2>&1 || true
		docker volume rm "${project}_$vol" >/dev/null
	fi
	say "starting $node with an empty data path, seed hosts es01..es03, no initial_master_nodes"
	"${compose[@]}" up -d --no-deps --wait "$node"
fi

# A node that has not joined yet reports _na_; give it a minute.
start=$SECONDS
while got=$(cluster_uuid "$node" 2>/dev/null) || got=; [ -z "$got" ] || [ "$got" = _na_ ]; do
	[ $((SECONDS - start)) -lt 60 ] || break
	sleep 2
done
if [ "$got" != "$(recorded_uuid)" ]; then
	"${compose[@]}" stop "$node" >&2
	die "$node reports cluster_uuid '${got:-none}', not $(recorded_uuid); stopped it. Check its log, then rerun with --wipe"
fi
es_ok es01 GET '/_cat/nodes?h=name,node.role,master&s=name' </dev/null
say "$node joined; voting configuration size $(voters)"
