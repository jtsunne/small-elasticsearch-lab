# shellcheck shell=bash disable=SC2034 # the variables are used by the scripts that source this file
# Sourced by the step scripts of this scenario; sets no shell options itself.
# Every request runs curl inside the named node container against
# 127.0.0.1:9200 as elastic. The password reaches curl on stdin and through a
# config read from a pipe, never through argv.

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$dir/../.." && pwd)

say() { printf '==> %s\n' "$*"; }
die() {
	echo "error: $*" >&2
	exit 1
}

command -v jq >/dev/null || die "jq is required"
[ -f "$dir/.env" ] || die "$dir/.env missing, run $dir/init-env.sh"

# Single keys, not sourced: ALLOWED_CIDRS and ES_UPSTREAMS hold spaces.
env_value() {
	grep -m1 "^$1=" "$dir/.env" | cut -d= -f2- || true
}

# set_env KEY VALUE: replaces the KEY line in .env, or appends it.
set_env() {
	local tmp
	tmp=$(mktemp "$dir/.env.XXXXXX")
	grep -v "^$1=" "$dir/.env" >"$tmp" || true
	printf '%s=%s\n' "$1" "$2" >>"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$dir/.env"
}

ELASTIC_PASSWORD=$(env_value ELASTIC_PASSWORD)
case $ELASTIC_PASSWORD in
"" | change-me*) die "ELASTIC_PASSWORD is unset or still the .env.example placeholder" ;;
esac

# compose: the grown cluster (also used for exec and ps on any node);
# compose_single: es01 as a single node; compose_traps: compose.yaml plus the
# lab traps.
base=(docker compose --project-directory "$dir" --env-file "$repo/versions.env" --env-file "$dir/.env")
compose=("${base[@]}" -f "$dir/compose.yaml")
compose_single=("${base[@]}" -f "$dir/compose.single.yaml")
compose_traps=("${base[@]}" -f "$dir/compose.yaml" -f "$dir/compose.traps.yaml" --profile trap)
project=es-grow-inplace
# trap.sh switches this to compose_traps to reach es04.
exec_compose=("${compose[@]}")

# shellcheck disable=SC2016 # expanded inside the container
es_remote='IFS= read -r pass; pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}
curl -sS --max-time 120 -w "\n%{http_code}" -X "$1" -H "Content-Type: application/json" \
	--data-binary @- -K <(printf "user = \"elastic:%s\"\n" "$pass") "http://127.0.0.1:9200$2"'

# es SVC METHOD PATH < body: the response body, then the status on its own line.
es() {
	{ printf '%s\n' "$ELASTIC_PASSWORD"; cat; } |
		"${exec_compose[@]}" exec -T "$1" bash -c "$es_remote" _ "$2" "$3" || true
}

# es_ok SVC METHOD PATH < body: prints the body, fails unless 2xx.
es_ok() {
	local res status body
	res=$(es "$@")
	status=${res##*$'\n'}
	body=${res%$'\n'*}
	case $status in
	2??) printf '%s' "$body" ;;
	*) echo "error: $1: $2 $3 returned $status: $body" >&2; return 1 ;;
	esac
}

# es_status SVC METHOD PATH: only the status.
es_status() {
	es "$@" </dev/null | tail -n1
}

running() {
	"${compose[@]}" ps --status running -q "$1" 2>/dev/null | grep -q .
}

need_running() {
	local s
	for s in "$@"; do
		running "$s" || die "$s is not running"
	done
}

cluster_uuid() {
	es_ok "$1" GET / </dev/null | jq -er .cluster_uuid
}

cluster_name() {
	es_ok "$1" GET / </dev/null | jq -er .cluster_name
}

# app_counts SVC: "index count" lines for every app-* index, sorted.
app_counts() {
	es_ok "$1" GET '/_cat/indices/app-*?format=json&h=index' </dev/null | jq -r '.[].index' | sort |
		while read -r idx; do
			printf '%s %s\n' "$idx" "$(es_ok "$1" GET "/$idx/_count" </dev/null | jq -r .count)"
		done
}

# The cluster_uuid es01 had before growth, recorded by step-1-preflight.sh.
# Every node that serves traffic must report it.
recorded_uuid() {
	local u
	u=$(env_value GROW_CLUSTER_UUID)
	[ -n "$u" ] || die "GROW_CLUSTER_UUID is not in .env, run step-1-preflight.sh"
	printf '%s' "$u"
}

# assert_same_cluster SVC...: each node reports the recorded cluster_uuid.
assert_same_cluster() {
	local s u want
	want=$(recorded_uuid)
	for s in "$@"; do
		u=$(cluster_uuid "$s") || die "cannot read cluster_uuid from $s"
		[ "$u" = "$want" ] || die "$s reports cluster_uuid $u, expected $want: it is not part of the original cluster"
	done
}

volume_exists() {
	docker volume inspect "${project}_$1" >/dev/null 2>&1
}

voters() {
	es_ok es01 GET '/_cluster/state/metadata?filter_path=metadata.cluster_coordination.last_committed_config' </dev/null |
		jq -r '.metadata.cluster_coordination.last_committed_config | length'
}
