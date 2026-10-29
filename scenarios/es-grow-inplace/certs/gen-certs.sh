#!/usr/bin/env bash
# Generates a CA and one transport certificate per node with
# elasticsearch-certutil, run inside the pinned Elasticsearch image, and writes
# PEM files next to this script. Refuses to overwrite existing files.
#
# Usage: certs/gen-certs.sh [NODE...]      (default: es01 es02 es03 es04;
# es04 is only for the L-G3 trap)
#
# Output: ca.pem, ca-key.pem (host only, never mounted), <node>.pem and
# <node>-key.pem. Node keys are owned by the host user with group 0 and mode
# 640, because the container user is uid 1000, gid 0.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../../.." && pwd)
nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || nodes=(es01 es02 es03 es04)

for n in "${nodes[@]}"; do
	[[ $n =~ ^[a-z][a-z0-9-]*$ ]] || { echo "error: bad node name '$n'" >&2; exit 2; }
done

existing=$(find "$dir" -maxdepth 1 \( -name '*.pem' -o -name '*.zip' \) -print -quit)
if [ -n "$existing" ]; then
	echo "error: $dir already holds certificates ($existing); remove them first to regenerate" >&2
	exit 1
fi

image=$(grep -m1 '^ES_IMAGE=' "$repo/versions.env" | cut -d= -f2-)
[ -n "$image" ] || { echo "error: ES_IMAGE not found in $repo/versions.env" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: the Docker daemon is not reachable" >&2; exit 1; }

work=$(mktemp -d "$dir/.gen.XXXXXX")
trap 'rm -rf "$work"' EXIT

{
	echo "instances:"
	for n in "${nodes[@]}"; do
		printf '  - name: %s\n    dns: [%s, localhost]\n    ip: [127.0.0.1]\n' "$n" "$n"
	done
} >"$work/instances.yml"

echo "generating a CA and certificates for: ${nodes[*]} (image $image)"
# shellcheck disable=SC2016 # expanded inside the container
docker run --rm --user 0 -v "$work:/work" --entrypoint bash "$image" -c '
set -euo pipefail
cd /usr/share/elasticsearch
bin/elasticsearch-certutil ca --silent --pem --out /work/ca.zip
unzip -q /work/ca.zip -d /work
bin/elasticsearch-certutil cert --silent --pem --ca-cert /work/ca/ca.crt --ca-key /work/ca/ca.key \
	--in /work/instances.yml --out /work/nodes.zip
unzip -q /work/nodes.zip -d /work/nodes
mkdir /work/out
cp /work/ca/ca.crt /work/out/ca.pem
cp /work/ca/ca.key /work/out/ca-key.pem
for d in /work/nodes/*/; do
	n=$(basename "$d")
	cp "$d/$n.crt" "/work/out/$n.pem"
	cp "$d/$n.key" "/work/out/$n-key.pem"
done
chown -R "$1:$2" /work
chown "$1:0" /work/out/*.pem
chown "$1:$2" /work/out/ca-key.pem
chmod 644 /work/out/*.pem
chmod 640 /work/out/*-key.pem
chmod 600 /work/out/ca-key.pem
' _ "$(id -u)" "$(id -g)"

for n in "${nodes[@]}"; do
	[ -s "$work/out/$n.pem" ] && [ -s "$work/out/$n-key.pem" ] ||
		{ echo "error: certutil produced no certificate for $n" >&2; exit 1; }
done
mv "$work"/out/*.pem "$dir/"
ls -l "$dir"/*.pem
