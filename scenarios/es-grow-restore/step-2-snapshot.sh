#!/usr/bin/env bash
# Step 2: snapshots app-* and the security feature state of es00 into "grow".
#
# Usage: step-2-snapshot.sh           snapshot grow-1, es00 keeps taking writes
#        step-2-snapshot.sh --final   blocks writes to app-* on es00 first,
#                                     then takes grow-final (the cutover copy)
#
# Safe to run again: an existing snapshot of the same name is kept, not
# replaced. --final leaves es00's app-* indices write-blocked until
# step-5-cutover.sh finishes or rollback.sh lifts the block.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

final=
case ${1:-} in
"") ;;
--final) final=1 ;;
-h | --help) sed -n '2,10p' "$0"; exit 0 ;;
*) die "unknown argument $1" ;;
esac
name=grow-1
[ -z "$final" ] || name=grow-final

need_running es00
[ "$(es_status es00 GET /_snapshot/grow)" = 200 ] || die "repository grow is not registered on es00, run step-1-repo.sh"

if [ -n "$final" ]; then
	say "blocking writes to app-* on es00: from here until cutover, application writes fail"
	es_ok es00 PUT '/app-*/_settings' >/dev/null <<'JSON'
{"index.blocks.write": true}
JSON
fi

if [ "$(es_status es00 GET "/_snapshot/grow/$name")" = 200 ]; then
	say "snapshot $name already exists, keeping it"
else
	say "taking snapshot $name of app-* plus the security feature state (users, roles, API keys)"
	es_ok es00 PUT "/_snapshot/grow/$name?wait_for_completion=true" <<'JSON' |
{"indices": "app-*", "include_global_state": false, "feature_states": ["security"]}
JSON
		jq -e '.snapshot.state == "SUCCESS"' >/dev/null || die "snapshot $name did not end in SUCCESS"
fi
es_ok es00 GET "/_snapshot/grow/$name" </dev/null |
	jq -r '.snapshots[0] | "state \(.state), indices \(.indices | sort | join(",")), features \([.feature_states[]?.feature_name] | join(","))"'
say "es00 document counts at this point:"
app_counts es00
