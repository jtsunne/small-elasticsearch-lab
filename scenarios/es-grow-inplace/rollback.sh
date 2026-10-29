#!/usr/bin/env bash
# Rollback for procedure B, valid only before any other node has joined: puts
# es01 back on compose.single.yaml (single-node discovery, no transport TLS).
#
# Usage: rollback.sh --confirm
#
# Once es02 or es03 has joined, es01's voting configuration holds more than one
# node and there is no in-place way back. Then the way back is a new single
# node restored from snapshot before-grow, as in es-grow-restore.
set -euo pipefail
# shellcheck source=scenarios/es-grow-inplace/common.sh
. "$(dirname "$0")/common.sh"

[ "${1:-}" = --confirm ] || { sed -n '2,9p' "$0"; die "pass --confirm"; }
if running es02 || running es03; then
	die "es02 or es03 is running; in-place rollback is not possible, see README.md"
fi
for v in esdata02 esdata03; do
	! volume_exists "$v" || die "volume ${project}_$v exists: a second node has run, and shards may have moved to it; in-place rollback is not safe, see README.md"
done
need_running es01
assert_same_cluster es01
n=$(voters)
[ "$n" = 1 ] || die "es01's voting configuration has $n nodes; another node joined at some point, in-place rollback is not possible"

say "recreating es01 and caddy from compose.single.yaml"
"${compose_single[@]}" up -d --wait es01 caddy
assert_same_cluster es01
say "es01 is a single node again, cluster_uuid unchanged"
