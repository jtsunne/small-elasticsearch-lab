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

compose=(docker compose --project-directory "$dir" --env-file "$repo/versions.env"
	--env-file "$dir/.env" -f "$dir/compose.yaml" --profile new)

# shellcheck disable=SC2016 # expanded inside the container
es_remote='IFS= read -r pass; pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}
curl -sS --max-time 120 -w "\n%{http_code}" -X "$1" -H "Content-Type: application/json" \
	--data-binary @- -K <(printf "user = \"elastic:%s\"\n" "$pass") "http://127.0.0.1:9200$2"'

# es SVC METHOD PATH < body: the response body, then the status on its own line.
es() {
	{ printf '%s\n' "$ELASTIC_PASSWORD"; cat; } |
		"${compose[@]}" exec -T "$1" bash -c "$es_remote" _ "$2" "$3" || true
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

# The new cluster is es01..es03, the old node es00. Destructive calls go only
# to a node that passes this check.
assert_new_cluster() {
	local name
	name=$(cluster_name es01) || die "cannot read the cluster name from es01"
	[ "$name" = es-grow-new ] || die "es01 reports cluster $name, expected es-grow-new"
	if running es00 && [ "$(cluster_uuid es00)" = "$(cluster_uuid es01)" ]; then
		die "es00 and es01 report the same cluster_uuid; refusing to touch either"
	fi
}
