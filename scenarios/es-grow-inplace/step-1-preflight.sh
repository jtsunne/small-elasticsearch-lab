#!/usr/bin/env bash
# Step 1: everything that must be true before es01 is restarted as a cluster
# node. Changes nothing on es01 except the snapshot repository and a snapshot.
#
# Usage: step-1-preflight.sh
#
#   - host vm.max_map_count: from step 2 on, es01 runs in production mode and
#     the bootstrap checks stop it from starting below 262144;
#   - transport certificates for es01..es04 (generated if certs/ is empty);
#   - es02 and es03 have no data volume yet (a leftover one may belong to
#     another cluster; step-3-add-node.sh --wipe removes it);
#   - records es01's cluster_uuid in .env as GROW_CLUSTER_UUID;
#   - registers the fs repository "grow" and takes snapshot before-grow, the
#     only way back once a second node has joined.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

need_running es01
if running es02 || running es03; then
	die "es02 or es03 is already running; preflight belongs before step 2"
fi

mmc=$(cat /proc/sys/vm/max_map_count)
if [ "$mmc" -lt 262144 ]; then
	die "vm.max_map_count is $mmc; production mode refuses to start below 262144 (Elastic recommends 1048576): sudo sysctl -w vm.max_map_count=1048576"
elif [ "$mmc" -lt 1048576 ]; then
	say "warning: vm.max_map_count is $mmc, above the 262144 minimum but below the recommended 1048576"
else
	say "vm.max_map_count $mmc"
fi

if ! compgen -G "$dir/certs/*.pem" >/dev/null; then
	say "no certificates yet: running certs/gen-certs.sh"
	"$dir/certs/gen-certs.sh"
fi
for n in es01 es02 es03; do
	[ -s "$dir/certs/$n.pem" ] && [ -s "$dir/certs/$n-key.pem" ] || die "certs/$n.pem or certs/$n-key.pem missing"
done

for v in esdata02 esdata03; do
	if volume_exists "$v"; then
		say "warning: volume ${project}_$v exists; step-3-add-node.sh refuses to use it without --wipe"
	fi
done

discovery=$(es_ok es01 GET '/_nodes/es01/settings?filter_path=nodes.*.settings.discovery.type' </dev/null |
	jq -r '[.nodes[].settings.discovery.type][0] // "multi-node"')
say "es01 discovery.type now: $discovery"

uuid=$(cluster_uuid es01)
current=$(env_value GROW_CLUSTER_UUID)
if [ -n "$current" ] && [ "$current" != "$uuid" ]; then
	die "es01 reports cluster_uuid $uuid but .env recorded $current: es01 is not the node this procedure started with"
fi
set_env GROW_CLUSTER_UUID "$uuid"
say "recorded cluster_uuid $uuid"

es_ok es01 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow"}}
JSON
if [ "$(es_status es01 GET /_snapshot/grow/before-grow)" = 200 ]; then
	say "snapshot before-grow already exists, keeping it"
else
	say "taking snapshot before-grow (app-*, security feature state)"
	es_ok es01 PUT '/_snapshot/grow/before-grow?wait_for_completion=true' <<'JSON' |
{"indices": "app-*", "include_global_state": false, "feature_states": ["security"]}
JSON
		jq -e '.snapshot.state == "SUCCESS"' >/dev/null || die "snapshot before-grow did not end in SUCCESS"
fi
counts=$(app_counts es01)
set_env GROW_SEED_COUNTS "$(printf '%s' "$counts" | paste -sd, -)"
say "es01 document counts, recorded for step 6:"
printf '%s\n' "$counts"
