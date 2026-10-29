#!/usr/bin/env bash
# L-T1 and L-T2: stops the elected master, then a second node, and checks what
# the cluster and Caddy do at each stage. expected.tsv cannot express this,
# because tests/run-scenario.sh only sends requests.
#
# Usage: fault-test.sh [--keep-up]
#
# Brings the scenario up itself with ALLOWED_CIDRS set to a client network it
# creates (FAULT_CLIENT_SUBNET, default 10.231.3.0/24), runs setup-roles.sh,
# prints TAP (also written to results/tests/<date>-es-three-local-fault.tap)
# and runs down -v at the end unless --keep-up. Every expectation below the
# baseline is a HYPOTHESIS written before the first run; see README.md.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../.." && pwd)
# shellcheck source=tests/lib.sh
. "$repo/tests/lib.sh"

keep_up=
while [ $# -gt 0 ]; do
	case $1 in
	--keep-up) keep_up=1; shift ;;
	-h | --help) sed -n '2,12p' "$0"; exit 0 ;;
	*) echo "error: unknown argument $1" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: the Docker daemon is not reachable" >&2; exit 1; }
[ -f "$dir/.env" ] || "$dir/init-env.sh"
compgen -G "$dir/certs/*.pem" >/dev/null || "$dir/certs/gen-certs.sh"

env_value() {
	grep -m1 "^$1=" "$dir/.env" | cut -d= -f2- || true
}
ELASTIC_PASSWORD=$(env_value ELASTIC_PASSWORD)
site=$(env_value ES_SITE_ADDRESS)
site=${site#*://}
site=${site%%:*}

subnet=${FAULT_CLIENT_SUBNET:-10.231.3.0/24}
export ALLOWED_CIDRS=$subnet
compose=(docker compose --project-directory "$dir" --env-file "$repo/versions.env"
	--env-file "$dir/.env" -f "$dir/compose.yaml")
project=$("${compose[@]}" config --format json | jq -r .name)
net=$project-fault-client
results=${RESULTS_DIR:-$repo/results/tests}
mkdir -p "$results"
caddy_cid=

cleanup() {
	local rc=$?
	[ -z "$caddy_cid" ] || docker network disconnect -f "$net" "$caddy_cid" >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
	[ -n "$keep_up" ] || "${compose[@]}" down -v >&2 || true
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

exec > >(tee "$results/$(date -u +%Y-%m-%d)-es-three-local-fault.tap")

"${compose[@]}" up -d --wait >&2
docker network create --subnet "$subnet" "$net" >/dev/null
caddy_cid=$("${compose[@]}" ps -q caddy)
docker network connect "$net" "$caddy_cid"
caddy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$caddy_cid")
image=$(docker inspect -f '{{.Config.Image}}' "$("${compose[@]}" ps -q es01)")
APP_API_KEY=$("$dir/setup-roles.sh" | sed -n 's/^APP_API_KEY=//p')
[ -n "$APP_API_KEY" ] || { echo "error: setup-roles.sh printed no APP_API_KEY" >&2; exit 1; }

# Secrets reach curl on stdin and through a config read from a pipe, never
# through argv. The first stdin line is the secret, the rest is the body.
# shellcheck disable=SC2016 # expanded inside the container
node_remote='IFS= read -r pass; pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}
curl -sS --max-time "$3" -w "\n%{http_code}" -X "$1" -H "Content-Type: application/json" \
	--data-binary @- -K <(printf "user = \"elastic:%s\"\n" "$pass") "http://127.0.0.1:9200$2"'
# shellcheck disable=SC2016 # expanded inside the client container
proxy_remote='IFS= read -r key
curl -sS -k --max-time 30 -w "\n%{http_code}" -X POST -H "Content-Type: application/x-ndjson" \
	--resolve "$3" --data-binary @- -K <(printf "header = \"Authorization: ApiKey %s\"\n" "$key") \
	"https://$2$1"'

# es_node SVC METHOD PATH [TIMEOUT] < body: response body, then the status on its
# own line; status 000 when curl got no answer.
es_node() {
	{ printf '%s\n' "$ELASTIC_PASSWORD"; cat; } |
		"${compose[@]}" exec -T "$1" bash -c "$node_remote" _ "$2" "$3" "${4:-30}" 2>/dev/null || true
}

# proxy PATH < body: a POST through Caddy from the allowlisted client network.
proxy() {
	{ printf '%s\n' "$APP_API_KEY"; cat; } |
		docker run --rm -i --network "$net" --entrypoint bash "$image" -c "$proxy_remote" _ \
			"$1" "$site" "$site:443:$caddy_ip" 2>/dev/null || true
}

status_of() { printf '%s' "${1##*$'\n'}"; }
body_of() { printf '%s' "${1%$'\n'*}"; }

master_of() {
	local res
	res=$(es_node "$1" GET '/_cat/master?h=node' 5 </dev/null)
	[ "$(status_of "$res")" = 200 ] && body_of "$res" | tr -d '[:space:]'
}

# wait_until SECONDS CMD...: polls once a second, prints the elapsed seconds.
wait_until() {
	local limit=$1 start=$SECONDS
	shift
	while ! "$@" >/dev/null 2>&1; do
		[ $((SECONDS - start)) -lt "$limit" ] || return 1
		sleep 1
	done
	echo $((SECONDS - start))
}

health_is() {
	local res
	res=$(es_node "$1" GET "/_cluster/health?filter_path=status" 5 </dev/null)
	[ "$(status_of "$res")" = 200 ] && [ "$(body_of "$res" | jq -r .status)" = "$2" ]
}

bulk_create() {
	printf '{"create":{"_id":"%s"}}\n{"message":"%s","@timestamp":"2026-01-01T00:00:00Z"}\n' "$1" "$1" |
		proxy '/app-a/_bulk?refresh=true'
}

check_bulk_ok() {
	local res=$1 desc=$2
	if [ "$(status_of "$res")" = 200 ] && body_of "$res" | jq -e '.errors == false' >/dev/null 2>&1; then
		tap_ok "$desc"
	else
		tap_not_ok "$desc" "status $(status_of "$res")" "body: $(body_of "$res" | head -c 300)"
	fi
}

tap_init
tap_diag "scenario: es-three-local fault test, client network $net ($subnet)"

res=$(es_node es01 GET '/_cluster/health?wait_for_status=green&wait_for_nodes=3&timeout=60s' </dev/null)
assert_eq "$(body_of "$res" | jq -r '"\(.status) \(.number_of_nodes)"')" "green 3" "baseline: green with 3 nodes"
check_bulk_ok "$(bulk_create base-1)" "baseline: bulk create through Caddy"

first=$(master_of es01) || first=
assert_match "$first" '^es0[123]$' "baseline: elected master is one of es01..es03"
survivors=()
for s in es01 es02 es03; do [ "$s" = "$first" ] || survivors+=("$s"); done

tap_diag "L-T1: stopping the elected master $first"
"${compose[@]}" stop "$first" >&2
new_master() { local m; m=$(master_of "${survivors[0]}") && [ -n "$m" ] && [ "$m" != "$first" ]; }
if t=$(wait_until 60 new_master); then
	tap_ok "L-T1: a new master is elected after $first stops (${t}s)"
	tap_diag "  measured: new master $(master_of "${survivors[0]}") after ${t}s"
else
	tap_not_ok "L-T1: a new master is elected after $first stops" "no new master within 60s"
fi
res=$(es_node "${survivors[0]}" GET '/_cluster/health?filter_path=status,number_of_nodes,unassigned_shards' </dev/null)
tap_diag "  health right after the loss: $(body_of "$res")"
fails=0
for _ in 1 2 3 4 5 6; do
	res=$(echo '{"query":{"match_all":{}}}' | proxy /app-a/_search)
	[ "$(status_of "$res")" = 200 ] || fails=$((fails + 1))
done
assert_eq "$fails" 0 "L-T1: none of six searches through Caddy fails with one node down"
check_bulk_ok "$(bulk_create t1-write)" "L-T1: bulk create through Caddy with one node down"
if t=$(wait_until 180 health_is "${survivors[0]}" green); then
	tap_ok "L-T1: green again on two nodes (${t}s)"
	tap_diag "  measured: green ${t}s after the master change; replica allocation waits index.unassigned.node_left.delayed_timeout"
else
	tap_not_ok "L-T1: green again on two nodes" "not green within 180s: $(body_of "$(es_node "${survivors[0]}" GET '/_cluster/health' </dev/null)")"
fi

last=${survivors[1]}
tap_diag "L-T2: stopping ${survivors[0]}, leaving $last alone"
"${compose[@]}" stop "${survivors[0]}" >&2
no_master() { ! master_of "$last"; }
if t=$(wait_until 60 no_master); then
	tap_ok "L-T2: $last reports no master (${t}s)"
else
	tap_not_ok "L-T2: $last reports no master" "still a master after 60s: $(master_of "$last")"
fi
res=$(es_node "$last" GET '/_cluster/health?timeout=5s&master_timeout=5s' 15 </dev/null)
assert_match "$(status_of "$res")" '^503$' "L-T2: cluster health without a master answers 503"
tap_diag "  health body: $(body_of "$res" | head -c 300)"
res=$(echo '{"query":{"match_all":{}}}' | proxy /app-a/_search)
tap_diag "  measured: search through Caddy without a master: status $(status_of "$res"), body $(body_of "$res" | head -c 300)"
res=$(bulk_create t2-write)
if [ "$(status_of "$res")" = 200 ] && body_of "$res" | jq -e '.errors == false' >/dev/null 2>&1; then
	tap_not_ok "L-T2: bulk create without a master is rejected" "it was accepted: $(body_of "$res" | head -c 300)"
else
	tap_ok "L-T2: bulk create without a master is rejected (status $(status_of "$res"))"
	tap_diag "  body: $(body_of "$res" | head -c 300)"
fi

tap_diag "recovery: starting $first and ${survivors[0]}"
"${compose[@]}" start "$first" "${survivors[0]}" >&2
if t=$(wait_until 300 health_is es01 green); then
	tap_ok "recovery: green with all nodes back (${t}s)"
else
	tap_not_ok "recovery: green with all nodes back" "not green within 300s"
fi
res=$(es_node es01 GET '/_cluster/health?filter_path=number_of_nodes' </dev/null)
assert_eq "$(body_of "$res" | jq -r .number_of_nodes)" 3 "recovery: three nodes in the cluster"
res=$(es_node es01 GET '/app-a/_doc/t1-write' </dev/null)
assert_eq "$(status_of "$res")" 200 "recovery: the write accepted during L-T1 is present"
res=$(es_node es01 GET '/app-a/_doc/t2-write' </dev/null)
assert_eq "$(status_of "$res")" 404 "recovery: the write rejected during L-T2 is absent"
uuids=$(for s in es01 es02 es03; do body_of "$(es_node "$s" GET / </dev/null)" | jq -r .cluster_uuid; done | sort -u)
assert_eq "$(printf '%s\n' "$uuids" | grep -c .)" 1 "recovery: all three nodes report the same cluster_uuid"

tap_finish
