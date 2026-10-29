#!/usr/bin/env bash
# Creates the index template, the test indices, the app_writer role and the
# app_x user, then creates an expiring, scoped API key for the application as
# elastic. Run it again to rotate: it creates a new key, see README.md.
#
# Usage: setup-roles.sh [--key-out FILE]
# READY_TIMEOUT (seconds, default 180) bounds the wait for the cluster.
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

# wait_ready PATH: GET PATH until it answers 200. compose up --wait returns
# when the node answers HTTP, which can be before the .security-7 primary is
# assigned; until then even elastic fails with 503 ("failed to retrieve
# password hash for reserved user"), or 401. 401, 408 (health timeout), 503
# and no answer are retried until READY_TIMEOUT seconds (default 180) have
# passed; anything else fails at once.
wait_ready() {
	local timeout=${READY_TIMEOUT:-180} start=$SECONDS attempt=0 res status
	[[ $timeout =~ ^[0-9]+$ ]] || { echo "error: READY_TIMEOUT must be a number of seconds" >&2; return 1; }
	while :; do
		attempt=$((attempt + 1))
		res=$(es GET "$1" </dev/null 2>/dev/null) || true
		status=${res##*$'\n'}
		[[ $status =~ ^[0-9]{3}$ ]] || status=000
		case "$status" in
		200) return 0 ;;
		401 | 408 | 503 | 000) ;;
		*) echo "error: GET $1 returned $status: ${res%$'\n'*}" >&2; return 1 ;;
		esac
		if [ $((SECONDS - start)) -ge "$timeout" ]; then
			echo "error: GET $1 not ready after ${timeout}s ($attempt attempts), last answer $status: ${res%$'\n'*}" >&2
			return 1
		fi
		echo "waiting for $1: attempt $attempt answered $status, $((SECONDS - start))s of ${timeout}s" >&2
		sleep 3
	done
}

create_index_once() {
	if [ "$(es GET "/$1" </dev/null | tail -n1)" = 404 ]; then
		es_ok PUT "/$1" >/dev/null
	fi
}

"${compose[@]}" ps --status running -q es01 | grep -q . ||
	{ echo "error: es01 is not running, start it with make up SCENARIO=$(basename "$dir")" >&2; exit 1; }

wait_ready '/_cluster/health?wait_for_status=yellow&timeout=30s'

es_ok PUT /_index_template/app >/dev/null <<'JSON'
{
  "index_patterns": ["app-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": 0}
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
{"settings": {"number_of_shards": 1, "number_of_replicas": 0}}
JSON
echo '{"message": "seed", "@timestamp": "2026-01-01T00:00:00Z"}' |
	es_ok PUT '/app-a/_doc/seed?refresh=true' >/dev/null
echo '{"message": "not for app-x", "@timestamp": "2026-01-01T00:00:00Z"}' |
	es_ok PUT '/secret/_doc/1?refresh=true' >/dev/null

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
