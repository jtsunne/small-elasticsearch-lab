#!/usr/bin/env bash
# Prints the host record for a benchmark or test run as "key: value" lines.
# It never prints the hostname, IP or MAC addresses, serial numbers or the user
# name: the host is identified only by the --host-id label.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: host-info.sh --host-id LABEL [options]

  --host-id LABEL      host label such as laptop-6c16g-nvme-01 (required, not the hostname)
  --host-class CLASS   laptop, desktop, server or vm, as declared by the operator
  --data-path PATH     path on the filesystem that holds the data volume (default /var/lib/docker)
  --compose FILE       compose file to hash (repeatable)
  --es-url URL         cluster URL for JVM and processor details; credentials from
                       ES_USER and ES_PASSWORD, CA from ES_CA (optional)

Optional environment: CLOUD_INSTANCE_TYPE, CLOUD_REGION for a VM.
EOF
}

host_id=""
host_class=""
data_path="/var/lib/docker"
es_url=""
compose_files=()

while [ $# -gt 0 ]; do
	case "$1" in
	--host-id) host_id="${2:?}"; shift 2 ;;
	--host-class) host_class="${2:?}"; shift 2 ;;
	--data-path) data_path="${2:?}"; shift 2 ;;
	--compose) compose_files+=("${2:?}"); shift 2 ;;
	--es-url) es_url="${2:?}"; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [ -z "$host_id" ]; then
	usage >&2
	exit 2
fi
if ! [[ "$host_id" =~ ^[a-z0-9][a-z0-9-]{2,62}$ ]]; then
	echo "host id must match ^[a-z0-9][a-z0-9-]{2,62}$" >&2
	exit 2
fi
own_host=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
if [ "${host_id,,}" = "${own_host,,}" ] || [ "${host_id,,}" = "${own_host%%.*}" ]; then
	echo "host id must be a label, not the hostname" >&2
	exit 2
fi
case "$host_class" in
"" | laptop | desktop | server | vm) ;;
*) echo "host class must be laptop, desktop, server or vm" >&2; exit 2 ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

kv() {
	local value="${2:-}"
	printf '%s: %s\n' "$1" "${value:-n/a}"
}

read_file() {
	[ -r "$1" ] && tr -d '\n' <"$1" 2>/dev/null || true
}

redact_home() {
	local s="$1"
	if [ -n "${HOME:-}" ]; then s="${s//$HOME/\~}"; fi
	printf '%s' "$s"
}

lscpu_field() {
	LC_ALL=C lscpu 2>/dev/null | awk -F: -v k="$1" '$1 == k { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

# SMBIOS chassis types 8, 9, 10, 14, 31 and 32 are portable form factors.
chassis_class() {
	case "$1" in
	8 | 9 | 10 | 14 | 31 | 32) echo "portable" ;;
	3 | 4 | 5 | 6 | 7 | 13 | 15 | 16 | 35 | 36) echo "desktop" ;;
	17 | 23 | 28 | 29) echo "server" ;;
	1) echo "other" ;;
	"") echo "" ;;
	*) echo "type-$1" ;;
	esac
}

mhz_from_khz() {
	local khz
	khz=$(read_file "$1")
	[ -n "$khz" ] && echo "$((khz / 1000)) MHz" || true
}

physical_disk() {
	lsblk -s -nr -o NAME,TYPE "$1" 2>/dev/null | awk '$2 == "disk" { print $1; exit }'
}

kv record_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kv host_id "$host_id"
kv host_class_declared "$host_class"
chassis=$(read_file /sys/class/dmi/id/chassis_type)
kv dmi_chassis_type "${chassis:+$chassis ($(chassis_class "$chassis"))}"
virt=$(systemd-detect-virt 2>/dev/null || true)
kv virtualization "$virt"
kv cloud_instance_type "${CLOUD_INSTANCE_TYPE:-}"
kv cloud_region "${CLOUD_REGION:-}"

power=""
for ps in /sys/class/power_supply/*; do
	[ -e "$ps/type" ] || continue
	case "$(read_file "$ps/type")" in
	Mains) power+="ac_online=$(read_file "$ps/online") " ;;
	Battery) power+="battery_status=$(read_file "$ps/status") " ;;
	esac
done
kv power_supply "${power% }"

kv cpu_model "$(lscpu_field 'Model name')"
kv cpu_sockets "$(lscpu_field 'Socket(s)')"
kv cpu_cores_per_socket "$(lscpu_field 'Core(s) per socket')"
kv cpu_threads_per_core "$(lscpu_field 'Thread(s) per core')"
kv cpu_logical "$(nproc --all 2>/dev/null)"
kv smt_active "$(read_file /sys/devices/system/cpu/smt/active)"
cpufreq=/sys/devices/system/cpu/cpu0/cpufreq
kv cpu_base_clock "$(mhz_from_khz "$cpufreq/base_frequency")"
kv cpu_max_clock "$(mhz_from_khz "$cpufreq/cpuinfo_max_freq")"
kv cpufreq_driver "$(read_file "$cpufreq/scaling_driver")"
kv cpu_governor "$(read_file "$cpufreq/scaling_governor")"
kv energy_perf_preference "$(read_file "$cpufreq/energy_performance_preference")"
kv intel_no_turbo "$(read_file /sys/devices/system/cpu/intel_pstate/no_turbo)"
kv cpu_microcode "$(awk -F: '/^microcode/ { gsub(/[ \t]/, "", $2); print $2; exit }' /proc/cpuinfo)"

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
kv ram_total "$((mem_kb / 1024)) MiB"
ram_speed=""
if [ "$(id -u)" -eq 0 ] && command -v dmidecode >/dev/null; then
	ram_speed=$(dmidecode -t memory 2>/dev/null | awk -F: '/^[ \t]*Configured Memory Speed:/ && $2 !~ /Unknown/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')
fi
kv ram_speed "$ram_speed"
swap_kb=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
kv swap_total "$((swap_kb / 1024)) MiB"
kv vm_swappiness "$(read_file /proc/sys/vm/swappiness)"
kv vm_max_map_count "$(read_file /proc/sys/vm/max_map_count)"

kv kernel "$(uname -r)"
kv os "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}")"
cgfs=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)
case "$cgfs" in
cgroup2fs) cgv="v2" ;;
tmpfs) cgv="v1" ;;
*) cgv="$cgfs" ;;
esac
kv cgroup_version "$cgv"

docker_server=""
docker_up=0
if command -v docker >/dev/null; then
	if docker_server=$(docker version --format '{{.Server.Version}}' 2>/dev/null); then
		docker_up=1
	else
		docker_server=""
	fi
	kv docker_client "$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
	kv docker_compose "$(docker compose version --short 2>/dev/null || true)"
else
	kv docker_client ""
	kv docker_compose ""
fi
kv docker_engine "${docker_server:-n/a (daemon not reachable)}"

if [ -e "$data_path" ]; then
	read -r fs_source fs_type fs_target fs_options < <(findmnt -n -o SOURCE,FSTYPE,TARGET,OPTIONS -T "$data_path" 2>/dev/null || echo "")
	fs_source=${fs_source%%\[*}
	kv data_path "$(redact_home "$data_path")"
	kv data_fs_mountpoint "$(redact_home "${fs_target:-}")"
	kv data_fs_type "${fs_type:-}"
	kv data_fs_options "${fs_options:-}"
	kv data_fs_size "$(df -B1 --output=size "$data_path" 2>/dev/null | awk 'NR == 2 { printf "%.1f GiB", $1 / 1073741824 }')"
	disk=""
	[ -n "${fs_source:-}" ] && [ -b "$fs_source" ] && disk=$(physical_disk "$fs_source")
	if [ -n "$disk" ]; then
		kv data_disk_model "$(lsblk -dn -o MODEL "/dev/$disk" 2>/dev/null | sed 's/[ \t]*$//')"
		kv data_disk_transport "$(lsblk -dn -o TRAN "/dev/$disk" 2>/dev/null | tr -d ' ')"
		kv data_disk_rotational "$(read_file "/sys/block/$disk/queue/rotational")"
		kv data_disk_scheduler "$(read_file "/sys/block/$disk/queue/scheduler")"
		kv data_fs_layers "$(lsblk -s -nr -o TYPE "$fs_source" 2>/dev/null | paste -sd'>' -)"
	else
		kv data_disk_model ""
	fi
else
	kv data_path "$(redact_home "$data_path") (does not exist)"
fi

if [ -r "$repo_root/versions.env" ]; then
	while IFS='=' read -r key value; do
		case "$key" in
		*_IMAGE)
			kv "pinned_${key,,}" "$value"
			local_digest=""
			if [ "$docker_up" -eq 1 ]; then
				local_digest=$(docker image inspect --format '{{join .RepoDigests ","}}' "$value" 2>/dev/null || true)
			fi
			kv "local_${key,,}_digest" "${local_digest:-n/a (daemon not reachable or image not pulled)}"
			;;
		esac
	done < <(grep -E '^[A-Z_]+=' "$repo_root/versions.env")
fi

for f in "${compose_files[@]}"; do
	kv "compose_sha256 $(redact_home "$f")" "$(sha256sum "$f" | awk '{ print $1 }')"
done

if git -C "$repo_root" rev-parse HEAD >/dev/null 2>&1; then
	commit=$(git -C "$repo_root" rev-parse HEAD)
	[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ] && commit+=" (dirty)"
	kv repo_commit "$commit"
	kv loader_commit "$(git -C "$repo_root" log -1 --format=%H -- bench/loader 2>/dev/null)"
else
	kv repo_commit ""
fi
kv go_version "$(go env GOVERSION 2>/dev/null || true)"

jvm=""
procs=""
if [ -n "$es_url" ]; then
	curl_args=(-fsS --max-time 10)
	[ -n "${ES_USER:-}" ] && curl_args+=(-u "${ES_USER}:${ES_PASSWORD:-}")
	[ -n "${ES_CA:-}" ] && curl_args+=(--cacert "$ES_CA")
	if nodes=$(curl "${curl_args[@]}" "$es_url/_nodes/jvm,os?filter_path=nodes.*.version,nodes.*.jvm.version,nodes.*.jvm.vm_name,nodes.*.os.allocated_processors,nodes.*.os.available_processors" 2>/dev/null); then
		jvm=$(jq -r '[.nodes[] | "\(.jvm.vm_name) \(.jvm.version)"] | unique | join(", ")' <<<"$nodes")
		procs=$(jq -r '[.nodes[] | "allocated=\(.os.allocated_processors) available=\(.os.available_processors)"] | join(", ")' <<<"$nodes")
		kv engine_version "$(jq -r '[.nodes[].version] | unique | join(", ")' <<<"$nodes")"
	fi
fi
kv jvm "${jvm:-n/a (no cluster reachable)}"
kv node_processors "${procs:-n/a (no cluster reachable)}"
