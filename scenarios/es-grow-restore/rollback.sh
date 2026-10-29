#!/usr/bin/env bash
# Rollback for procedure A: points Caddy back at es00, gives the repository
# back to es00 and lifts the write block on its app-* indices.
#
# Usage: rollback.sh --confirm
#
# Documents written to the new cluster after cutover are NOT copied back; the
# script prints the counts on both sides so the difference is visible. The new
# cluster is left running with its data; stop it with
# docker compose ... stop es01 es02 es03 once it is no longer needed.
set -euo pipefail
# shellcheck source=scenarios/es-grow-restore/common.sh
. "$(dirname "$0")/common.sh"

[ "${1:-}" = --confirm ] || { sed -n '2,10p' "$0"; die "pass --confirm"; }
need_running es00

if running es01; then
	assert_new_cluster
	say "counts now (es00 first, then the new cluster); the difference stays on the new cluster:"
	app_counts es00
	app_counts es01
	say "making repository grow read-only on the new cluster"
	es_ok es01 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow", "readonly": true}}
JSON
fi

say "registering repository grow on es00 as writable"
es_ok es00 PUT /_snapshot/grow >/dev/null <<'JSON'
{"type": "fs", "settings": {"location": "grow"}}
JSON
say "lifting the write block on es00's app-* indices"
es_ok es00 PUT '/app-*/_settings' >/dev/null <<'JSON'
{"index.blocks.write": null}
JSON
say "switching Caddy back to es00"
set_env ES_UPSTREAMS es00:9200
"${compose[@]}" up -d --wait --no-deps caddy
say "rolled back: Caddy proxies to es00, which accepts writes again"
