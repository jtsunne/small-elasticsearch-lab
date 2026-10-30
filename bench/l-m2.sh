#!/usr/bin/env bash
# Lab test L-M2: the same synthetic bulk load into a single Elasticsearch node
# in a 2 GiB container (scenarios/bad-heap), once with a deliberately large
# heap ("bad") and once with half of the container ("control"). Records loader
# output, cgroup memory samples, JVM GC samples, OOM state and the container
# log for each run.
# See bench/README.md, section "l-m2.sh".
set -euo pipefail

usage() {
	cat <<'EOF'
usage: l-m2.sh --out DIR --data-dir DIR [--loader PATH] [--keep-data]

  --out DIR        result directory; created, must not exist yet
  --data-dir DIR   directory for the two node data directories; must be on a
                   disk filesystem (tmpfs and ramfs are refused) and writable
                   by uid 1000 or gid 0 inside the container
  --loader PATH    loader binary (default bench/loader/loader, see make loader)
  --keep-data      keep the node data directories after the run

Experiment parameters, environment variables with the values of the
2026-10-29 run as defaults:
  LM2_DOCS=3000000        synthetic documents per run (about 670 bytes each)
  LM2_SEED=42             awk srand seed of the generator
  LM2_CLIENTS=2           loader clients
  LM2_BULK_SIZE=1000      documents per _bulk request
  LM2_BAD_HEAP=1536m      heap of the "bad" run (-Xms and -Xmx)
  LM2_CONTROL_HEAP=1g     heap of the "control" run
  LM2_TIMEOUT=1500        seconds before a loader run is stopped
  LM2_SAMPLE_S=10         seconds between memory and node stats samples
  BENCH_ES_CPUSET=1       host CPU the node is pinned to (compose.bench.yaml)

Controls added after the 2026-10-29 run (the defaults reproduce that run):
  LM2_SWAP=default        default: the container may swap as Docker allows;
                          off: memswap_limit equal to mem_limit (2g), so the
                          container gets no swap (memory.swap.max 0 on
                          cgroup v2); the run stops if the node sees otherwise
  LM2_ORDER=bad,control   run order: bad,control or control,bad
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scenario_dir="$repo_root/scenarios/bad-heap"

out=""
data_root=""
loader="$repo_root/bench/loader/loader"
keep_data=0

while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="${2:?}"; shift 2 ;;
	--data-dir) data_root="${2:?}"; shift 2 ;;
	--loader) loader="${2:?}"; shift 2 ;;
	--keep-data) keep_data=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
[ -n "$out" ] && [ -n "$data_root" ] || { usage >&2; exit 2; }

docs="${LM2_DOCS:-3000000}"
seed="${LM2_SEED:-42}"
clients="${LM2_CLIENTS:-2}"
bulk_size="${LM2_BULK_SIZE:-1000}"
bad_heap="${LM2_BAD_HEAP:-1536m}"
control_heap="${LM2_CONTROL_HEAP:-1g}"
load_timeout="${LM2_TIMEOUT:-1500}"
sample_s="${LM2_SAMPLE_S:-10}"
swap_mode="${LM2_SWAP:-default}"
order="${LM2_ORDER:-bad,control}"
container_mem=2g
export BENCH_ES_CPUSET="${BENCH_ES_CPUSET:-1}"
url="http://127.0.0.1:9200"

die() {
	echo "l-m2.sh: $*" >&2
	exit 1
}
log() {
	echo "l-m2.sh: $(date -u +%H:%M:%S) $*" >&2
}

heap_bytes() {
	local n="${1%[mMgG]}"
	case "$1" in
	*[mM]) echo $((n * 1048576)) ;;
	*[gG]) echo $((n * 1073741824)) ;;
	*) return 1 ;;
	esac
}

for n in "$docs" "$seed" "$clients" "$bulk_size" "$load_timeout" "$sample_s"; do
	[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || die "numeric parameters must be positive integers, got '$n'"
done
for h in "$bad_heap" "$control_heap"; do
	[[ "$h" =~ ^[1-9][0-9]*[mMgG]$ ]] || die "heap sizes look like 1536m or 1g, got '$h'"
done
case "$swap_mode" in
default | off) ;;
*) die "LM2_SWAP must be default or off, got '$swap_mode'" ;;
esac
case "$order" in
bad,control | control,bad) ;;
*) die "LM2_ORDER must be bad,control or control,bad, got '$order'" ;;
esac

missing=()
[ "$(uname -s)" = Linux ] || missing+=("Linux host")
[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" = cgroup2fs ] ||
	missing+=("cgroup v2 mounted at /sys/fs/cgroup (the memory samples read memory.stat and memory.events)")
for tool in curl awk findmnt; do
	command -v "$tool" >/dev/null || missing+=("tool: $tool")
done
if ! command -v docker >/dev/null; then
	missing+=("docker CLI")
else
	docker info >/dev/null 2>&1 || missing+=("Docker daemon reachable by this user (docker info failed)")
	docker compose version >/dev/null 2>&1 || missing+=("Docker Compose v2 plugin (docker compose)")
fi
[ -x "$loader" ] || missing+=("loader binary $loader (make loader)")
[ -f "$scenario_dir/compose.yaml" ] && [ -f "$scenario_dir/compose.bench.yaml" ] ||
	missing+=("scenarios/bad-heap/compose.yaml and compose.bench.yaml")
if [ ! -d "$data_root" ]; then
	missing+=("--data-dir $data_root: directory does not exist")
else
	data_fstype=$(findmnt -n -o FSTYPE -T "$data_root" 2>/dev/null || true)
	case "$data_fstype" in
	tmpfs | ramfs | "") missing+=("--data-dir $data_root is on '${data_fstype:-unknown}': the index would live in RAM and be charged to the container's memory") ;;
	esac
	[ -w "$data_root" ] || missing+=("--data-dir $data_root is not writable by this user")
fi
[ ! -e "$out" ] || missing+=("--out $out exists; choose a new directory")
map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
[ "$map_count" -ge 1048576 ] || missing+=("vm.max_map_count >= 1048576 (now $map_count)")
# curl exit 7 is "connection refused": nothing else may hold the port that
# compose.bench.yaml publishes.
if command -v curl >/dev/null; then
	port_rc=0
	curl -s -o /dev/null --max-time 2 "$url" || port_rc=$?
	[ "$port_rc" -eq 7 ] || missing+=("127.0.0.1:9200 is in use or not refusing (curl exit $port_rc)")
fi

if [ ${#missing[@]} -gt 0 ]; then
	echo "l-m2.sh: prerequisites missing:" >&2
	printf '  - %s\n' "${missing[@]}" >&2
	exit 1
fi

out=$(mkdir -p "$out" && cd "$out" && pwd)
data_root=$(cd "$data_root" && pwd)

tmp=$(mktemp -d)
chmod 700 "$tmp"
started_projects=()
created_dirs=()
monitor_pids=()

cleanup() {
	local p d
	for p in "${monitor_pids[@]}"; do kill "$p" 2>/dev/null || true; done
	# By project label rather than through compose: the compose files need the
	# password and data path, which may already be gone at this point.
	for p in "${started_projects[@]}"; do
		docker ps -aq --filter "label=com.docker.compose.project=$p" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
		docker network ls -q --filter "label=com.docker.compose.project=$p" | xargs -r docker network rm >/dev/null 2>&1 || true
	done
	if [ "$keep_data" -eq 0 ]; then
		for d in "${created_dirs[@]}"; do
			rm -rf -- "$d" || echo "l-m2.sh: could not remove $d (files owned by the container user?)" >&2
		done
	fi
	rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

umask 077
password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
printf 'ELASTIC_PASSWORD=%s\n' "$password" >"$tmp/env"
umask 022

curl_node() {
	printf 'user = "elastic:%s"\n' "$password" | curl -sS --max-time 30 -K - "$@"
}

# Fixed seed, so every run gets the same documents from the same awk; gawk and
# mawk produce different sequences, which is why run.txt records the awk used.
generate() {
	awk -v n="$docs" -v seed="$seed" 'BEGIN {
		srand(seed)
		split("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega error warn info debug request response timeout retry cache index shard node cluster merge flush refresh segment query filter", w, " ")
		for (i = 1; i <= n; i++) {
			m = ""
			for (j = 0; j < 110; j++) m = m w[int(rand() * 47) + 1] " "
			printf "{\"@timestamp\":\"2026-01-01T%02d:%02d:%02dZ\",\"message\":\"%s\",\"user\":\"u%d\",\"n\":%d}\n", int(i / 3600) % 24, int(i / 60) % 60, i % 60, m, int(rand() * 100000), i
		}
	}'
}

sample_memory() {
	local cid="$1" file="$2" st mem
	while :; do
		st=$(docker inspect -f '{{.State.Status}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} exit={{.State.ExitCode}}' "$cid" 2>&1 || true)
		mem=$(docker exec "$cid" sh -c 'grep -E "^(anon|file|shmem|file_mapped|swapcached) " /sys/fs/cgroup/memory.stat | tr "\n" " "; cat /sys/fs/cgroup/memory.events | tr "\n" " "; printf "swap_current %s swap_max %s" "$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null || echo n/a)" "$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo n/a)"' 2>&1 || true)
		echo "$(date -u +%H:%M:%S) $st | $mem" >>"$file"
		sleep "$sample_s"
	done
}

nodestats_path="nodes.*.jvm.gc.collectors.*.collection_count,nodes.*.jvm.gc.collectors.*.collection_time_in_millis,nodes.*.jvm.mem.heap_used_percent,nodes.*.os.cgroup.memory"

# A node that does not answer is a data point: it gets a line with ok false
# and the curl exit code rather than no line.
sample_nodestats_once() {
	local file="$1" body="$2" ts rc code
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	rc=0
	code=$(curl_node --max-time "$sample_s" -o "$body" -w '%{http_code}' \
		"$url/_nodes/stats/jvm,os?filter_path=$nodestats_path" 2>/dev/null) || rc=$?
	if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ "$(head -c 1 "$body" 2>/dev/null)" = "{" ]; then
		printf '{"t":"%s","ok":true,"curl_exit":0,"http_code":200,"stats":%s}\n' "$ts" "$(tr -d '\n' <"$body")" >>"$file"
	else
		printf '{"t":"%s","ok":false,"curl_exit":%d,"http_code":"%s"}\n' "$ts" "$rc" "${code:-000}" >>"$file"
	fi
}

sample_nodestats() {
	while :; do
		sample_nodestats_once "$1" "$2"
		sleep "$sample_s"
	done
}

# Deltas are sums of increments between answered samples, so a restarted JVM
# adds its new counter value instead of producing a negative delta.
summarize_nodestats() {
	awk -v label="$1" '
	function num(s, coll, field,   o) {
		if (!match(s, "\"" coll "\": *\\{[^}]*\\}")) return ""
		o = substr(s, RSTART, RLENGTH)
		if (!match(o, "\"" field "\": *[0-9]+")) return ""
		o = substr(o, RSTART, RLENGTH)
		sub(/.*: */, "", o)
		return o + 0
	}
	BEGIN {
		coll[1] = "young"; coll[2] = "old"
		fname[1] = "count"; field[1] = "collection_count"
		fname[2] = "time_ms"; field[2] = "collection_time_in_millis"
	}
	/"ok":false/ { failed++; next }
	/"ok":true/ {
		answered++
		for (c = 1; c <= 2; c++) for (f = 1; f <= 2; f++) {
			k = coll[c] "_" fname[f]
			v = num($0, coll[c], field[f])
			if (v == "") continue
			if (k in prev) {
				if (v >= prev[k]) delta[k] += v - prev[k]
				else { delta[k] += v; resets[k]++ }
			} else delta[k] += 0
			prev[k] = v
		}
	}
	END {
		printf "%s_nodestats_samples: %d answered, %d not answered\n", label, answered, failed
		for (c = 1; c <= 2; c++) for (f = 1; f <= 2; f++) {
			k = coll[c] "_" fname[f]
			if (k in delta) printf "%s_gc_%s_delta: %d%s\n", label, k, delta[k], (resets[k] ? " (counter reset " resets[k] " times)" : "")
			else printf "%s_gc_%s_delta: n/a\n", label, k
		}
	}' "$2"
}

run_one() {
	local label="$1" heap="$2" project="lm2-$1" data="$data_root/lm2-$1"
	local expected cid rc heap_json

	expected=$(heap_bytes "$heap")
	[ ! -e "$data" ] || die "$data exists; remove it or choose another --data-dir"
	mkdir -p "$data"
	created_dirs+=("$data")
	cat >"$tmp/heap-$label.yaml" <<EOF
services:
  es01:
    environment:
      - ES_JAVA_OPTS=-Xms$heap -Xmx$heap
EOF
	if [ "$swap_mode" = off ]; then
		cat >>"$tmp/heap-$label.yaml" <<EOF
    mem_limit: $container_mem
    memswap_limit: $container_mem
EOF
	fi
	local compose=(docker compose --project-name "$project" --project-directory "$scenario_dir"
		--env-file "$repo_root/versions.env" --env-file "$tmp/env"
		-f "$scenario_dir/compose.yaml" -f "$scenario_dir/compose.bench.yaml" -f "$tmp/heap-$label.yaml")

	log "$label: starting es01 with heap $heap"
	started_projects+=("$project")
	BENCH_DATA_DIR="$data" "${compose[@]}" up -d --wait >>"$out/log.txt" 2>&1 || {
		BENCH_DATA_DIR="$data" "${compose[@]}" logs --tail 60 >>"$out/log.txt" 2>&1 || true
		die "$label: compose up failed, see $out/log.txt"
	}

	# compose's healthcheck passes before the .security-7 primary is assigned;
	# until then even elastic gets 503 or 401.
	local i
	for i in $(seq 1 36); do
		if heap_json=$(curl_node -f "$url/_nodes/jvm?filter_path=nodes.*.jvm.mem.heap_max_in_bytes" 2>/dev/null); then
			break
		fi
		heap_json=""
		sleep 5
	done
	[ -n "$heap_json" ] || die "$label: node did not answer as elastic within 180 s"
	echo "$heap_json" >"$out/$label-heap.json"
	grep -q "\"heap_max_in_bytes\":$expected[,}]" <<<"$heap_json" ||
		die "$label: heap_max_in_bytes is not $expected: $heap_json"

	cid=$(BENCH_DATA_DIR="$data" "${compose[@]}" ps -q es01)
	[ -n "$cid" ] || die "$label: no container id for es01"
	local swap_max
	swap_max=$(docker exec "$cid" cat /sys/fs/cgroup/memory.swap.max 2>&1 || true)
	echo "${label}_memory_swap_max: $swap_max" >>"$out/run.txt"
	[ "$swap_mode" != off ] || [ "$swap_max" = 0 ] ||
		die "$label: LM2_SWAP=off but memory.swap.max in the container is '$swap_max', not 0"

	sample_memory "$cid" "$out/$label-monitor.txt" &
	monitor_pids+=("$!")
	sample_nodestats "$out/$label-nodestats.jsonl" "$tmp/nodestats-$label.json" &
	monitor_pids+=("$!")

	log "$label: loading $docs documents, $clients clients, bulk size $bulk_size"
	rc=0
	generate | LOADER_PASSWORD="$password" timeout "$load_timeout" "$loader" bulk \
		-url "$url" -user elastic -index lm2 -input - \
		-clients "$clients" -bulk-size "$bulk_size" -label "$label" \
		-out "$out/$label-requests.jsonl" -summary "$out/$label-summary.csv" \
		>"$out/$label-loader.json" 2>"$out/$label-loader.err" || rc=$?
	echo "$label: loader exit=$rc" >>"$out/log.txt"

	local p
	for p in "${monitor_pids[@]}"; do kill "$p" 2>/dev/null || true; done
	for p in "${monitor_pids[@]}"; do wait "$p" 2>/dev/null || true; done
	monitor_pids=()
	sample_nodestats_once "$out/$label-nodestats.jsonl" "$tmp/nodestats-$label-final.json"
	summarize_nodestats "$label" "$out/$label-nodestats.jsonl" >>"$out/run.txt"

	docker inspect -f '{{.State.Status}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} exit={{.State.ExitCode}}' "$cid" >"$out/$label-final-state.txt" 2>&1 || true
	docker logs --tail 30 "$cid" >"$out/$label-container-tail.txt" 2>&1 || true
	mkdir -p "$out/raw"
	docker logs "$cid" >"$out/raw/$label-container.log" 2>&1 || true
	curl_node "$url/_cat/indices/lm2?v&h=index,docs.count,store.size,pri.store.size" >"$out/$label-index.txt" 2>&1 || true

	log "$label: removing the containers"
	BENCH_DATA_DIR="$data" "${compose[@]}" down -v >>"$out/log.txt" 2>&1 || true
}

{
	echo "experiment: L-M2, scenarios/bad-heap, synthetic bulk load"
	echo "start_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "docs: $docs"
	echo "seed: $seed"
	echo "awk: $(awk --version 2>/dev/null | head -n 1 || echo unknown)"
	echo "clients: $clients"
	echo "bulk_size: $bulk_size"
	echo "refresh_interval: index default"
	echo "mapping: dynamic"
	echo "bad_heap: $bad_heap"
	echo "control_heap: $control_heap"
	echo "cpuset: $BENCH_ES_CPUSET"
	echo "order: $order"
	echo "LM2_SWAP: $swap_mode"
	echo "container_mem_limit: $container_mem"
	echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo n/a)"
	swapon --show --noheadings --bytes 2>/dev/null |
		awk '{ n++; printf "swap_device: %s type=%s size=%s used=%s prio=%s\n", $1, $2, $3, $4, $5 } END { if (!n) print "swap_device: none" }' ||
		echo "swap_device: swapon failed"
	echo "data_fs_type: $data_fstype"
	echo "es_image: $(grep -E '^ES_IMAGE=' "$repo_root/versions.env" | cut -d= -f2-)"
	echo "repo_commit: $(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo n/a)"
} >"$out/run.txt"

IFS=, read -r -a run_order <<<"$order"
for label in "${run_order[@]}"; do
	case "$label" in
	bad) run_one bad "$bad_heap" ;;
	control) run_one control "$control_heap" ;;
	esac
done
echo "end_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out/run.txt"
log "done: $out"
