#!/usr/bin/env bash
# Creates the index template, the test indices, the app_writer role and the
# app_x user, then creates an expiring, scoped API key for the application as
# elastic. Run it again to rotate: it creates a new key, see README.md.
#
# Usage: setup-roles.sh [--key-out FILE]
#
# The node publishes no port and Caddy does not proxy _security, so every call
# runs curl inside the es01 container against 127.0.0.1:9200. Passwords reach
# that curl on stdin and as a curl config read from a pipe, never through argv,
# which any user on the host can read with ps.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../.." && pwd)
key_out=""

while [ $# -gt 0 ]; do
	case "$1" in
	--key-out) key_out="${2:?--key-out needs a file}"; shift 2 ;;
	-h | --help) sed -n '2,6p' "$0"; exit 0 ;;
	*) echo "error: unknown argument $1" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -f "$dir/.env" ] || { echo "error: $dir/.env missing, run init-env.sh" >&2; exit 1; }

# Read single keys instead of sourcing .env: ALLOWED_CIDRS holds spaces and
# compose does not quote values.
env_value() {
	local v
	v=$(grep -m1 "^$1=" "$dir/.env" | cut -d= -f2-) || true
	printf '%s' "${!1:-$v}"
}
ELASTIC_PASSWORD=$(env_value ELASTIC_PASSWORD)
APP_PASSWORD=$(env_value APP_PASSWORD)
for name in ELASTIC_PASSWORD APP_PASSWORD; do
	case "${!name}" in
	"" | change-me*) echo "error: $name is unset or still the .env.example placeholder" >&2; exit 1 ;;
	esac
done

compose=(docker compose --project-directory "$dir" --env-file "$repo/versions.env"
	--env-file "$dir/.env" -f "$dir/compose.yaml")

# The first stdin line is the password, the rest is the request body. bash
# reads a pipe byte by byte, so curl gets the stream right after that line.
# shellcheck disable=SC2016 # expanded inside the container
remote='IFS= read -r pass; pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}
curl -sS -w "\n%{http_code}" -X "$1" -H "Content-Type: application/json" \
	--data-binary @- -K <(printf "user = \"%s:%s\"\n" "$3" "$pass") \
	"http://127.0.0.1:9200$2"'

# es METHOD PATH < body; runs as elastic, prints the response body, then the
# status on its own line.
es() {
	{ printf '%s\n' "$ELASTIC_PASSWORD"; cat; } |
		"${compose[@]}" exec -T es01 bash -c "$remote" _ "$1" "$2" elastic
}

# es_ok METHOD PATH < body; prints the body, fails unless 2xx.
es_ok() {
	local res status body
	res=$(es "$@")
	status=${res##*$'\n'}
	body=${res%$'\n'*}
	case "$status" in
	2??) printf '%s' "$body" ;;
	*) echo "error: $1 $2 returned $status: $body" >&2; return 1 ;;
	esac
}

create_index_once() {
	if [ "$(es GET "/$1" </dev/null | tail -n1)" = 404 ]; then
		es_ok PUT "/$1" >/dev/null
	fi
}

"${compose[@]}" ps --status running -q es01 | grep -q . ||
	{ echo "error: es01 is not running, start it with make up SCENARIO=$(basename "$dir")" >&2; exit 1; }

# Green, not yellow: with three nodes every replica has somewhere to go.
es_ok GET '/_cluster/health?wait_for_status=green&wait_for_nodes=3&timeout=120s' </dev/null >/dev/null

es_ok PUT /_index_template/app >/dev/null <<'JSON'
{
  "index_patterns": ["app-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": 1}
  }
}
JSON

es_ok PUT /_security/role/app_writer >/dev/null <<'JSON'
{
  "indices": [
    {"names": ["app-*"], "privileges": ["read", "create_doc"]}
  ]
}
JSON

APP_PASSWORD=$APP_PASSWORD jq -n '{password: env.APP_PASSWORD, roles: ["app_writer"], full_name: "app-x service"}' |
	es_ok PUT /_security/user/app_x >/dev/null

create_index_once app-a </dev/null
create_index_once secret <<'JSON'
{"settings": {"number_of_shards": 1, "number_of_replicas": 1}}
JSON
echo '{"message": "seed", "@timestamp": "2026-01-01T00:00:00Z"}' |
	es_ok PUT '/app-a/_doc/seed?refresh=true' >/dev/null
echo '{"message": "not for app-x", "@timestamp": "2026-01-01T00:00:00Z"}' |
	es_ok PUT '/secret/_doc/1?refresh=true' >/dev/null
es_ok GET '/_cluster/health/app-a,secret?wait_for_status=green&timeout=120s' </dev/null >/dev/null

# The key is owned by elastic, so role_descriptors is its only limit: without
# them it would be a superuser key. Keys never expire unless told to.
key=$(es_ok POST /_security/api_key <<'JSON' | jq -er .encoded
{
  "name": "app-x-key",
  "expiration": "30d",
  "role_descriptors": {
    "app_x_key": {
      "indices": [
        {"names": ["app-*"], "privileges": ["read", "create_doc"]}
      ]
    }
  }
}
JSON
)

if [ -n "$key_out" ]; then
	(umask 077 && printf 'APP_API_KEY=%s\n' "$key" >"$key_out")
	echo "role app_writer, user app_x and an app API key (30 days, owned by elastic) created; key written to $key_out"
else
	echo "role app_writer, user app_x and an app API key (30 days, owned by elastic) created" >&2
	printf 'APP_API_KEY=%s\n' "$key"
fi
