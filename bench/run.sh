#!/usr/bin/env bash
# Benchmark orchestration: size steps of on-disk primary store, repeated on a
# fresh cluster each time, with the host record and node statistics captured
# next to the loader output. See bench/README.md for the scenario contract.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: run.sh --engine es|os --host-id LABEL --data-fs PATH [options]

Required:
  --engine es|os
  --host-id LABEL           host label, never the hostname (see host-info.sh)
  --data-fs PATH            mountpoint of a dedicated filesystem for the data volume

Options:
  --mode steps|sweep        steps: L-B1 ingest at fixed settings plus L-B2 queries per size
                            step (default); sweep: L-B1 bulk size, clients and refresh sweep
  --scenario NAME           default es-single or os-single
  --service NAME            compose service of the node (default es01 or os01)
  --url URL                 node URL as published by the scenario's compose.bench.yaml
                            (default http://127.0.0.1:9200)
  --user NAME               default elastic or admin; password from LOADER_PASSWORD
  --corpus http_logs|geonames  (default http_logs)
  --mapping dynamic|keyword|logsdb  (default keyword; logsdb is Elasticsearch only)
  --setting KEY=VALUE       extra index setting, repeatable (index.codec=best_compression)
  --steps "1 10 30"         primary store targets in GB (10^9 bytes)
  --reps N                  repetitions, each on a fresh cluster (default 3)
  --repeat N                read the corpus N times (synthetic replication, default 1)
  --bulk-size N             default 1000          --clients N         default 1
  --refresh-interval D      default 30s
  --concurrency "1 4"       query concurrency levels   --duration D   default 5m
  --warmup D                default 30s           --cold               add a cold-cache run
  --sweep-gb N              store target for each sweep combination (default 1)
  --host-class CLASS        laptop, desktop, server or vm
  --loader-cpus LIST        pin the loader with taskset, for example 2-3
  --results-dir DIR         default bench/results/<date>-<host-id>-<engine>-<version>
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bench_dir="$repo_root/bench"

engine=""
host_id=""
data_fs=""
mode="steps"
scenario=""
service=""
url="http://127.0.0.1:9200"
user=""
corpus="http_logs"
mapping="keyword"
settings=()
steps="1 10 30"
reps=3
repeat=1
bulk_size=1000
clients=1
refresh="30s"
concurrency="1 4"
duration="5m"
warmup="30s"
cold=0
sweep_gb=1
host_class=""
loader_cpus=""
results_dir=""

while [ $# -gt 0 ]; do
	case "$1" in
	--engine) engine="${2:?}"; shift 2 ;;
	--host-id) host_id="${2:?}"; shift 2 ;;
	--data-fs) data_fs="${2:?}"; shift 2 ;;
	--mode) mode="${2:?}"; shift 2 ;;
	--scenario) scenario="${2:?}"; shift 2 ;;
	--service) service="${2:?}"; shift 2 ;;
	--url) url="${2:?}"; shift 2 ;;
	--user) user="${2:?}"; shift 2 ;;
	--corpus) corpus="${2:?}"; shift 2 ;;
	--mapping) mapping="${2:?}"; shift 2 ;;
	--setting) settings+=("${2:?}"); shift 2 ;;
	--steps) steps="${2:?}"; shift 2 ;;
	--reps) reps="${2:?}"; shift 2 ;;
	--repeat) repeat="${2:?}"; shift 2 ;;
	--bulk-size) bulk_size="${2:?}"; shift 2 ;;
	--clients) clients="${2:?}"; shift 2 ;;
	--refresh-interval) refresh="${2:?}"; shift 2 ;;
	--concurrency) concurrency="${2:?}"; shift 2 ;;
	--duration) duration="${2:?}"; shift 2 ;;
	--warmup) warmup="${2:?}"; shift 2 ;;
	--cold) cold=1; shift ;;
	--sweep-gb) sweep_gb="${2:?}"; shift 2 ;;
	--host-class) host_class="${2:?}"; shift 2 ;;
	--loader-cpus) loader_cpus="${2:?}"; shift 2 ;;
	--results-dir) results_dir="${2:?}"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

die() {
	echo "run.sh: $*" >&2
	exit 1
}
log() {
	echo "run.sh: $(date -u +%H:%M:%S) $*" >&2
}

case "$engine" in
es) min_map_count=1048576; version_key=ES_VERSION; default_user=elastic ;;
os) min_map_count=262144; version_key=OPENSEARCH_VERSION; default_user=admin ;;
*) usage >&2; exit 2 ;;
esac
[ -n "$host_id" ] || { usage >&2; exit 2; }
[ -n "$data_fs" ] || { usage >&2; exit 2; }
case "$mode" in steps | sweep) ;; *) die "mode must be steps or sweep" ;; esac
case "$corpus" in http_logs | geonames) ;; *) die "corpus must be http_logs or geonames" ;; esac
case "$mapping" in
dynamic | keyword) ;;
logsdb)
	[ "$engine" = es ] || die "logsdb is an Elasticsearch index mode; OpenSearch has no equivalent profile here"
	[ "$corpus" = http_logs ] || die "logsdb needs a @timestamp field; use it with http_logs"
	;;
*) die "mapping must be dynamic, keyword or logsdb" ;;
esac
for n in "$reps" "$repeat" "$bulk_size" "$clients" "$sweep_gb"; do
	[[ "$n" =~ ^[1-9][0-9]*$ ]] || die "numeric options must be positive integers, got '$n'"
done
for s in $steps; do
	[[ "$s" =~ ^[1-9][0-9]*$ ]] || die "steps must be positive integers in GB, got '$s'"
done
scenario="${scenario:-${engine}-single}"
service="${service:-${engine}01}"
user="${user:-$default_user}"
scenario_dir="$repo_root/scenarios/$scenario"
[ "$data_fs" = / ] || data_fs="${data_fs%/}"

# Prerequisites from the lab requirements. Everything missing is reported at
# once, so a fresh host can be fixed in one pass.
missing=()
[ "$(uname -s)" = Linux ] || missing+=("Linux host")
[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" = cgroup2fs ] ||
	missing+=("cgroup v2 mounted at /sys/fs/cgroup (cgroup v1 is not supported)")
for tool in curl jq sha256sum findmnt; do
	command -v "$tool" >/dev/null || missing+=("tool: $tool")
done
if ! command -v docker >/dev/null; then
	missing+=("docker CLI")
else
	docker info >/dev/null 2>&1 || missing+=("Docker daemon reachable by this user (docker info failed)")
	docker compose version >/dev/null 2>&1 || missing+=("Docker Compose v2 plugin (docker compose)")
fi
map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
[ "$map_count" -ge "$min_map_count" ] ||
	missing+=("vm.max_map_count >= $min_map_count (now $map_count): sudo sysctl -w vm.max_map_count=$min_map_count")
if [ ! -d "$data_fs" ]; then
	missing+=("--data-fs $data_fs: directory does not exist")
else
	fs_target=$(findmnt -n -o TARGET -T "$data_fs" 2>/dev/null || true)
	root_src=$(findmnt -n -o SOURCE -T / 2>/dev/null | sed 's/\[.*//')
	data_src=$(findmnt -n -o SOURCE -T "$data_fs" 2>/dev/null | sed 's/\[.*//')
	if [ "$fs_target" != "$data_fs" ]; then
		missing+=("--data-fs $data_fs must be the mountpoint of a dedicated filesystem (it is inside $fs_target)")
	elif [ "$data_src" = "$root_src" ]; then
		missing+=("--data-fs $data_fs is on the same device as / ($root_src); watermarks would be computed on the host disk")
	fi
	[ -w "$data_fs" ] || missing+=("--data-fs $data_fs is not writable by this user")
fi
[ -r "$repo_root/versions.env" ] || missing+=("versions.env")
[ -f "$scenario_dir/compose.yaml" ] || missing+=("scenarios/$scenario/compose.yaml (scenario not written yet)")
[ -f "$scenario_dir/compose.bench.yaml" ] ||
	missing+=("scenarios/$scenario/compose.bench.yaml (bench override that publishes the node on 127.0.0.1 and mounts \$BENCH_DATA_DIR)")
[ -n "${LOADER_PASSWORD:-}" ] || missing+=("LOADER_PASSWORD environment variable for user $user")
if [ ! -x "$bench_dir/loader/loader" ] && ! command -v go >/dev/null; then
	missing+=("bench/loader/loader binary (make loader) or a Go toolchain")
fi
[ -z "$loader_cpus" ] || command -v taskset >/dev/null || missing+=("taskset (for --loader-cpus)")
mapping_file="$bench_dir/mappings/$engine/$corpus-$mapping.json"
[ -f "$mapping_file" ] || missing+=("mapping profile bench/mappings/$engine/$corpus-$mapping.json")
query_file="$bench_dir/queries/$corpus.json"
[ -f "$query_file" ] || missing+=("query set bench/queries/$corpus.json")
mapfile -t corpus_files < <(find "$bench_dir/corpus/$corpus" -maxdepth 1 -name 'documents-*.json' ! -name '*.unparsed.json' 2>/dev/null | sort)
[ ${#corpus_files[@]} -gt 0 ] || missing+=("corpus files in bench/corpus/$corpus (bench/fetch-corpus.sh $corpus)")
on_battery=0
for ps in /sys/class/power_supply/*; do
	[ -r "$ps/type" ] || continue
	if [ "$(cat "$ps/type")" = Mains ] && [ "$(cat "$ps/online" 2>/dev/null || echo 1)" = 0 ]; then
		on_battery=1
	fi
done
[ "$on_battery" -eq 0 ] || missing+=("AC power (the host runs on battery)")

if [ ${#missing[@]} -gt 0 ]; then
	echo "run.sh: prerequisites missing:" >&2
	printf '  - %s\n' "${missing[@]}" >&2
	exit 1
fi

# shellcheck disable=SC1091
. "$repo_root/versions.env"
version="${!version_key}"
date_tag=$(date -u +%Y-%m-%d)
results_dir="${results_dir:-$bench_dir/results/$date_tag-$host_id-$engine-$version}"
[ ! -e "$results_dir" ] || die "$results_dir exists; pass --results-dir to choose another"
mkdir -p "$results_dir/raw" "$results_dir/stats"
summary="$results_dir/summary.csv"

if [ ! -x "$bench_dir/loader/loader" ]; then
	log "building the loader"
	(cd "$bench_dir/loader" && go build -trimpath -o loader .)
fi
loader=("$bench_dir/loader/loader")
[ -z "$loader_cpus" ] || loader=(taskset -c "$loader_cpus" "${loader[@]}")

export BENCH_DATA_DIR="$data_fs/bench-$engine"
compose_files=("$scenario_dir/compose.yaml" "$scenario_dir/compose.bench.yaml")
compose=(docker compose --project-directory "$scenario_dir" --env-file "$repo_root/versions.env")
[ ! -f "$scenario_dir/.env" ] || compose+=(--env-file "$scenario_dir/.env")
for f in "${compose_files[@]}"; do compose+=(-f "$f"); done

host_info=("$bench_dir/host-info.sh" --host-id "$host_id" --data-path "$data_fs")
[ -z "$host_class" ] || host_info+=(--host-class "$host_class")
for f in "${compose_files[@]}"; do host_info+=(--compose "$f"); done

curl_node() {
	curl -fsS --max-time 30 -u "$user:$LOADER_PASSWORD" "$@"
}

reset_cluster() {
	log "resetting $scenario"
	"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
	# BENCH_DATA_DIR is a fixed subdirectory of the validated mountpoint.
	if [ -d "$BENCH_DATA_DIR" ]; then
		find "$BENCH_DATA_DIR" -mindepth 1 -delete
	fi
	mkdir -p "$BENCH_DATA_DIR"
	"${compose[@]}" up -d --wait
	wait_healthy
}

wait_healthy() {
	local i
	for i in $(seq 1 60); do
		if curl_node "$url/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
	done
	die "cluster at $url did not become healthy (last attempt $i)"
}

container_id() {
	"${compose[@]}" ps -q "$service"
}

# Captures cgroup and node statistics for the container; name is a tag such
# as rep1-step10-after-ingest.
snapshot() {
	local name="$1" cid cg
	local dir="$results_dir/stats/$name"
	mkdir -p "$dir"
	curl_node "$url/_nodes/stats/jvm,os,process,fs,indices,thread_pool,breaker" >"$dir/nodes-stats.json" || true
	curl_node "$url/_cat/indices?format=json&bytes=b&h=index,docs.count,store.size,pri.store.size" >"$dir/cat-indices.json" || true
	curl_node "$url/_cat/segments?format=json&bytes=b" >"$dir/cat-segments.json" || true
	cid=$(container_id)
	if [ -n "$cid" ]; then
		docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}' "$cid" >"$dir/container-state.txt" || true
		cg=$(find /sys/fs/cgroup -maxdepth 3 -type d -name "*$cid*" 2>/dev/null | head -n 1)
		if [ -n "$cg" ]; then
			for f in memory.stat memory.current memory.peak memory.events cpu.stat io.stat; do
				if [ -r "$cg/$f" ]; then cp "$cg/$f" "$dir/$f"; fi
			done
		fi
	fi
}

capture_host() {
	"${host_info[@]}" --es-url "$url" >"$results_dir/host.txt" 2>/dev/null ||
		"${host_info[@]}" >"$results_dir/host.txt"
	sha256sum "${compose_files[@]}" "$repo_root/versions.env" "$mapping_file" "$query_file" |
		sed "s|$repo_root/||" >"$results_dir/inputs.sha256"
}

loader_common=(-url "$url" -user "$user" -index "bench-$corpus" -summary "$summary")

input_args=()
for f in "${corpus_files[@]}"; do input_args+=(-input "$f"); done
setting_args=()
for s in "${settings[@]}"; do setting_args+=(-setting "$s"); done
kw=""
[ "$mapping" != dynamic ] || kw=".keyword"
label="$engine-$version-$corpus-$mapping"

run_queries() {
	local tag="$1" c
	for c in $concurrency; do
		log "queries $tag concurrency $c"
		"${loader[@]}" search "${loader_common[@]}" -queries "$query_file" -var "kw=$kw" \
			-concurrency "$c" -duration "$duration" -warmup "$warmup" \
			-run-id "$tag-c$c" -label "$label" -out "$results_dir/raw/$tag-search-c$c.jsonl" \
			>"$results_dir/raw/$tag-search-c$c.json"
	done
}

drop_caches() {
	if sudo -n true 2>/dev/null; then
		sync
		echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
		echo yes
	else
		echo no
	fi
}

{
	echo "mode=$mode engine=$engine version=$version scenario=$scenario corpus=$corpus mapping=$mapping"
	echo "steps_gb=$steps reps=$reps repeat=$repeat bulk_size=$bulk_size clients=$clients refresh=$refresh"
	echo "concurrency=$concurrency duration=$duration warmup=$warmup cold=$cold settings=${settings[*]:-none}"
	echo "loader_cpus=${loader_cpus:-unpinned} started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$results_dir/run.txt"

host_captured=0
if [ "$mode" = steps ]; then
	for rep in $(seq 1 "$reps"); do
		reset_cluster
		if [ "$host_captured" -eq 0 ]; then
			capture_host
			host_captured=1
		fi
		skip=0
		first=1
		for step in $steps; do
			tag="rep$rep-step$step"
			log "$tag: ingest to $step GB primary store"
			idx_args=()
			[ "$first" -eq 0 ] || idx_args=(-mapping "$mapping_file" -recreate -refresh-interval "$refresh" "${setting_args[@]}")
			"${loader[@]}" bulk "${loader_common[@]}" "${input_args[@]}" -repeat "$repeat" "${idx_args[@]}" \
				-skip-docs "$skip" -max-store-bytes "$((step * 1000000000))" \
				-bulk-size "$bulk_size" -clients "$clients" \
				-run-id "$tag" -label "$label" -out "$results_dir/raw/$tag-bulk.jsonl" \
				>"$results_dir/raw/$tag-bulk.json"
			skip=$((skip + $(jq '.docs_ok + .docs_failed' "$results_dir/raw/$tag-bulk.json")))
			first=0
			store=$(jq '.store_bytes' "$results_dir/raw/$tag-bulk.json")
			snapshot "$tag-after-ingest"
			if [ "$store" -lt "$((step * 1000000000))" ]; then
				log "$tag: corpus exhausted at $store bytes, below the $step GB target; recorded as is"
				echo "$tag corpus exhausted at $store bytes" >>"$results_dir/run.txt"
			fi
			run_queries "$tag-warm"
			if [ "$cold" -eq 1 ]; then
				"${compose[@]}" restart "$service" >/dev/null
				dropped=$(drop_caches)
				echo "$tag cold run: container restarted, page cache dropped=$dropped" >>"$results_dir/run.txt"
				wait_healthy
				run_queries "$tag-cold"
			fi
			snapshot "$tag-after-queries"
			[ "$store" -ge "$((step * 1000000000))" ] || break
		done
	done
else
	for rep in $(seq 1 "$reps"); do
		reset_cluster
		if [ "$host_captured" -eq 0 ]; then
			capture_host
			host_captured=1
		fi
		for bs in 100 500 1000 5000; do
			for cl in 1 2; do
				for ri in 1s 30s; do
					tag="rep$rep-sweep-b$bs-c$cl-r$ri"
					log "$tag"
					"${loader[@]}" bulk "${loader_common[@]}" "${input_args[@]}" -repeat "$repeat" \
						-mapping "$mapping_file" -recreate -refresh-interval "$ri" "${setting_args[@]}" \
						-max-store-bytes "$((sweep_gb * 1000000000))" -bulk-size "$bs" -clients "$cl" \
						-run-id "$tag" -label "$label" -out "$results_dir/raw/$tag-bulk.jsonl" \
						>"$results_dir/raw/$tag-bulk.json"
					snapshot "$tag"
				done
			done
		done
	done
fi

"${compose[@]}" down -v >/dev/null 2>&1 || true
echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$results_dir/run.txt"
log "results in $results_dir"
