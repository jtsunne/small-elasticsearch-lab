#!/usr/bin/env bash
# Reproduces the two growth traps of the lab matrix and records what happens.
# Not part of the procedure.
#
# Usage: trap.sh g4 --confirm   between step 1 and step 2: restarts es01 with
#                               seed hosts and TLS but still discovery.type
#                               single-node, then starts es02 and records
#                               whether it can join. Removes es02 and its
#                               volume afterwards. Run step 2 next.
#        trap.sh g3 --confirm   after step 4: starts es04 with
#                               cluster.initial_master_nodes set to itself and
#                               records whether it joins or forms a second
#                               cluster. Removes es04 and its volume afterwards.
#
# Logs and API answers go to results/tests/<date>-es-grow-inplace-L-G3.log or
# -L-G4.log.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

which=${1:-}
[ "${2:-}" = --confirm ] || { sed -n '2,17p' "$0"; die "pass the trap name and --confirm"; }
exec_compose=("${compose_traps[@]}")
results=${RESULTS_DIR:-$repo/results/tests}
mkdir -p "$results"

# remove_new_node SVC VOLUME: stops and removes a node that is not es01, and
# its data volume.
remove_new_node() {
	[ "$1" != es01 ] && [ "$2" != esdata01 ] || die "refusing to remove es01 or its volume"
	"${compose_traps[@]}" rm -f -s "$1" >/dev/null 2>&1 || true
	docker volume rm "${project}_$2" >/dev/null 2>&1 || true
}

case $which in
g4)
	log=$results/$(date -u +%Y-%m-%d)-es-grow-inplace-L-G4.log
	need_running es01
	assert_same_cluster es01
	if running es02 || running es03 || volume_exists esdata02 || volume_exists esdata03; then
		die "es02 or es03 has already run; L-G4 belongs between step 1 and step 2"
	fi
	[ "$(es_status es01 GET /_snapshot/grow/before-grow)" = 200 ] || die "no snapshot before-grow, run step-1-preflight.sh"
	{
		say "L-G4: recreating es01 with discovery.type single-node plus seed hosts and transport TLS"
		"${compose_traps[@]}" up -d --no-deps es01
		start=$SECONDS
		until [ "$(es_status es01 GET /)" = 200 ] || [ $((SECONDS - start)) -ge 180 ]; do sleep 2; done
		say "es01 GET / after $((SECONDS - start))s: status $(es_status es01 GET /)"
		es_ok es01 GET / </dev/null | jq -c '{cluster_name, cluster_uuid}' || true
		say "starting es02 (empty data, no initial_master_nodes) for 60s"
		"${compose[@]}" up -d --no-deps es02
		sleep 60
		say "es02 GET /: $(es es02 GET / </dev/null | head -c 300 | tr '\n' ' ')"
		say "es01 nodes: $(es_ok es01 GET '/_cat/nodes?h=name' </dev/null | tr '\n' ' ')"
		say "es01 log lines about discovery or joins:"
		"${compose[@]}" logs --no-color es01 2>&1 | grep -E 'single-node|seed_hosts|cannot join|bootstrap check' | tail -n 20 || true
		say "es02 log lines about discovery or joins:"
		"${compose[@]}" logs --no-color es02 2>&1 | grep -E 'single-node|cannot join|master not discovered|join' | tail -n 20 || true
		remove_new_node es02 esdata02
		say "es02 and its volume removed; es01 still runs the trap configuration, run step-2-restart-first.sh next"
	} 2>&1 | tee "$log"
	;;
g3)
	log=$results/$(date -u +%Y-%m-%d)-es-grow-inplace-L-G3.log
	need_running es01 es02 es03
	assert_same_cluster es01 es02 es03
	[ -s "$dir/certs/es04.pem" ] || die "certs/es04.pem missing; certs were generated without es04"
	! volume_exists esdata04 || die "volume ${project}_esdata04 exists from an earlier run; remove it first"
	{
		say "L-G3: starting es04 with cluster.initial_master_nodes=es04 and seed hosts es01..es03"
		"${compose_traps[@]}" up -d --no-deps es04
		start=$SECONDS
		until [ "$(es_status es04 GET /)" = 200 ] || [ $((SECONDS - start)) -ge 180 ]; do sleep 2; done
		sleep 30
		say "es04: $(es_ok es04 GET / </dev/null | jq -c '{cluster_name, cluster_uuid}' || echo 'no answer')"
		say "original cluster_uuid: $(recorded_uuid)"
		say "es01 nodes: $(es_ok es01 GET '/_cat/nodes?h=name' </dev/null | tr '\n' ' ')"
		say "es04 nodes: $(es_ok es04 GET '/_cat/nodes?h=name' </dev/null | tr '\n' ' ' || true)"
		say "es04 log lines about bootstrap, joins or cluster UUIDs:"
		"${compose_traps[@]}" logs --no-color es04 2>&1 | grep -Ei 'bootstrap|cluster uuid|join|elected-as-master' | tail -n 20 || true
		remove_new_node es04 esdata04
		say "es04 and its volume removed"
	} 2>&1 | tee "$log"
	;;
*) die "unknown trap '$which', expected g3 or g4" ;;
esac
