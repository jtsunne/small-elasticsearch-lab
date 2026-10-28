#!/usr/bin/env bash
# Prepares and applies the security plugin configuration of this scenario.
#
#   init-security.sh          render security/internal_users.yml with bcrypt
#                             hashes of the passwords in .env (before first start)
#   init-security.sh --apply  load internal_users.yml, roles.yml and
#                             roles_mapping.yml into the running cluster with
#                             securityadmin.sh and the admin certificate
#
# On the first start the plugin creates its index from the mounted files
# (plugins.security.allow_default_init_securityindex), so --apply is only
# needed after a change. --apply overwrites users and roles created through the
# REST API or Dashboards.
set -euo pipefail

usage() {
	sed -n '2,13s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

scenario_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$scenario_dir/../.." && pwd)
apply=0

while [ $# -gt 0 ]; do
	case "$1" in
	--apply) apply=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

die() {
	echo "init-security.sh: $*" >&2
	exit 1
}

[ -f "$scenario_dir/.env" ] || die "no .env; copy .env.example to .env and set the passwords"
# shellcheck disable=SC1091
. "$repo_root/versions.env"

# .env is read the way Compose reads it, not sourced: values may contain spaces
# and shell metacharacters. Only *_PASSWORD and *_SECRET keys are taken.
secrets=()
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in '' | '#'*) continue ;; esac
	key="${line%%=*}"
	value="${line#*=}"
	[[ "$key" =~ ^[A-Z0-9_]+_(PASSWORD|SECRET)$ ]] || continue
	if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
		value="${BASH_REMATCH[1]}"
	fi
	export "$key=$value"
	[[ "$key" != *_SECRET ]] || secrets+=("$key")
done <"$scenario_dir/.env"

for var in "${secrets[@]}"; do
	value="${!var}"
	[ "${#value}" -ge 32 ] || die "$var must be at least 32 characters"
	case "$value" in *change-me* | *changeme* | *CHANGE-ME* | *CHANGEME*) die "$var still has the .env.example value" ;; esac
done

compose=(docker compose --project-directory "$scenario_dir" --env-file "$repo_root/versions.env"
	--env-file "$scenario_dir/.env" -f "$scenario_dir/compose.yaml")
security_dir=/usr/share/opensearch/config/opensearch-security
tools=/usr/share/opensearch/plugins/opensearch-security/tools

if [ "$apply" -eq 1 ]; then
	[ -f "$scenario_dir/security/internal_users.yml" ] || die "security/internal_users.yml missing; run without --apply first"
	for pair in internal_users.yml:internalusers roles.yml:roles roles_mapping.yml:rolesmapping; do
		file="${pair%%:*}"
		type="${pair##*:}"
		echo "applying $file"
		# -f/-t loads one configuration type at a time, so action groups,
		# tenants and config.yml in the index are left as they are.
		"${compose[@]}" exec -T os01 "$tools/securityadmin.sh" \
			-f "$security_dir/$file" -t "$type" \
			-h os01 -p 9200 -icl \
			-cacert /usr/share/opensearch/config/root-ca.pem \
			-cert /usr/share/opensearch/config/admin.pem \
			-key /usr/share/opensearch/config/admin-key.pem
	done
	exit 0
fi

template="$scenario_dir/internal_users.yml.example"
placeholders=$(grep -o '@@[A-Z_]*_HASH@@' "$template" | sort -u)
[ -n "$placeholders" ] || die "no @@<NAME>_HASH@@ placeholders in $template"

# The demo installer enforces strength rules on OPENSEARCH_INITIAL_ADMIN_PASSWORD;
# with the demo configuration disabled nothing checks the passwords in
# internal_users.yml, so this script does a minimum itself.
declare -A hashes
for placeholder in $placeholders; do
	name="${placeholder#@@}"
	name="${name%_HASH@@}"
	var="${name}_PASSWORD"
	value="${!var:-}"
	[ -n "$value" ] || die "$var is not set in .env"
	[ "${#value}" -ge 16 ] || die "$var must be at least 16 characters"
	case "$value" in *change-me* | *changeme* | *CHANGE-ME* | *CHANGEME*) die "$var still has the .env.example value" ;; esac
	echo "hashing $var"
	# The password reaches hash.sh through the environment (-env), never argv,
	# so it does not show up in the process list.
	hash=$(docker run --rm --network none -e "$var" --entrypoint "$tools/hash.sh" \
		"$OPENSEARCH_IMAGE" -env "$var" | grep -E '^\$2[aby]\$' | tail -n 1) ||
		die "hash.sh failed for $var"
	[ -n "$hash" ] || die "hash.sh printed no bcrypt hash for $var"
	hashes[$placeholder]="$hash"
done

mkdir -p "$scenario_dir/security"
out="$scenario_dir/security/internal_users.yml"
tmp=$(mktemp "$scenario_dir/security/.internal_users.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cp "$template" "$tmp"
for placeholder in "${!hashes[@]}"; do
	PLACEHOLDER="$placeholder" HASH="${hashes[$placeholder]}" \
		awk '{ gsub(ENVIRON["PLACEHOLDER"], ENVIRON["HASH"]); print }' "$tmp" >"$tmp.new"
	mv "$tmp.new" "$tmp"
done
! grep -q '@@[A-Z_]*_HASH@@' "$tmp" || die "unreplaced placeholder left in $out"
chmod 0600 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "wrote $out"
if [ "$(id -u)" != 1000 ]; then
	echo "note: the container user is uid 1000; run: sudo chown 1000 $out" >&2
fi
