#!/usr/bin/env bash
# Step 0: the starting point. Brings up es00 (the single node, es-single's
# configuration plus path.repo) and Caddy, creates what es-single's
# setup-roles.sh creates, loads SEED_DOCS documents (default 1000) into app-b,
# and writes the app API key to .env as APP_API_KEY.
#
# Usage: step-0-seed.sh
#
# Safe to run again: existing roles, indices and documents are kept, and a new
# API key is created only when .env has none.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

seed_docs=${SEED_DOCS:-1000}
[[ $seed_docs =~ ^[0-9]+$ ]] || die "SEED_DOCS must be a number"

snap=$(env_value SNAPSHOT_DIR)
[ -n "$snap" ] || die "SNAPSHOT_DIR is not set in .env"
case $snap in /*) ;; *) snap=$dir/$snap ;; esac
if [ ! -d "$snap" ]; then
	say "creating the snapshot directory $snap (owner $(id -un), group 0, mode 2770)"
	mkdir -p "$snap"
	image=$(grep -m1 '^ES_IMAGE=' "$repo/versions.env" | cut -d= -f2-)
	# Only root can give the directory group 0, which the node process has.
	# shellcheck disable=SC2016 # expanded inside the container
	docker run --rm --user 0 -v "$snap:/snap" --entrypoint bash "$image" \
		-c 'chown "$1:0" /snap && chmod 2770 /snap' _ "$(id -u)"
fi

say "starting es00 and caddy"
"${compose[@]}" up -d --wait es00 caddy

wait_ready es00 '/_cluster/health?wait_for_status=yellow&timeout=30s'

say "index template app (1 shard, 0 replicas), role app_writer, user app_x"
es_ok es00 PUT /_index_template/app >/dev/null <<'JSON'
{
  "index_patterns": ["app-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": 0}
  }
}
JSON
es_ok es00 PUT /_security/role/app_writer >/dev/null <<'JSON'
{
  "indices": [
    {"names": ["app-*"], "privileges": ["read", "create_doc"]}
  ]
}
JSON
app_password=$(env_value APP_PASSWORD)
case $app_password in "" | change-me*) die "APP_PASSWORD is unset or still the placeholder" ;; esac
APP_PASSWORD=$app_password jq -n '{password: env.APP_PASSWORD, roles: ["app_writer"], full_name: "app-x service"}' |
	es_ok es00 PUT /_security/user/app_x >/dev/null

for idx in app-a app-b; do
	[ "$(es_status es00 GET "/$idx")" = 404 ] && es_ok es00 PUT "/$idx" </dev/null >/dev/null
done
echo '{"message": "seed", "@timestamp": "2026-01-01T00:00:00Z"}' |
	es_ok es00 PUT '/app-a/_doc/seed?refresh=true' >/dev/null

have=$(es_ok es00 GET /app-b/_count </dev/null | jq -r .count)
if [ "$have" -lt "$seed_docs" ]; then
	say "loading $((seed_docs - have)) documents into app-b"
	# Fixed ids make a second run top up instead of duplicating.
	for ((start = have; start < seed_docs; start += 500)); do
		end=$((start + 500 < seed_docs ? start + 500 : seed_docs))
		for ((i = start; i < end; i++)); do
			printf '{"create":{"_id":"doc-%d"}}\n{"message":"seed document %d","n":%d,"@timestamp":"2026-01-01T00:00:00Z"}\n' "$i" "$i" "$i"
		done | es_ok es00 POST '/app-b/_bulk?refresh=wait_for' | jq -e '.errors == false' >/dev/null ||
			die "bulk load into app-b reported errors"
	done
fi

if [ -z "$(env_value APP_API_KEY)" ]; then
	say "creating the app API key (30 days, owned by elastic, scoped by role_descriptors)"
	key=$(es_ok es00 POST /_security/api_key <<'JSON' | jq -er .encoded
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
	set_env APP_API_KEY "$key"
fi

say "es00 holds:"
app_counts es00
