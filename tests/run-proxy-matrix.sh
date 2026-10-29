#!/usr/bin/env bash
# Runs tests/proxy-matrix.tsv against a Caddyfile and prints TAP.
#
# Proxy-only mode (default) needs no Docker and no Elasticsearch: the
# Caddyfile is adapted to JSON, every reverse_proxy is pointed at the echo
# upstream, every remote_ip/client_ip range is replaced by the test client
# address, the site is moved to 127.0.0.1 on a free high port with automatic
# HTTPS off, and Caddy and the echo upstream run as local processes. The
# allowed client sends from 127.0.0.2, the denied client from 127.0.0.3; any
# 127.0.0.0/8 address is local on Linux, so no setup is needed. Only the
# allowlist values change, never the structure, which is what is under test.
# Backend expectations (the engine's own answer) are not checked in this mode.
#
# Lab mode (--lab URL) sends the same rows to a running scenario's Caddy and
# checks the backend column too.
#
# usage: tests/run-proxy-matrix.sh [options] CADDYFILE [UPSTREAM_LISTEN]
#        tests/run-proxy-matrix.sh --lab URL [options]
#   UPSTREAM_LISTEN     address for the echo upstream (default 127.0.0.1:0)
#   --engine es|os      which engine's rows to run (default es)
#   --matrix FILE       matrix file (default tests/proxy-matrix.tsv)
#   --only ERE          run only rows whose id matches
#   --env-file FILE     KEY=VALUE lines exported while adapting the Caddyfile,
#                       for {$VAR} placeholders in it
#   --server NAME       Caddy server to test when the config has several
#   --host NAME         Host header. Default: the only host matcher of the
#                       tested server, else the only one starting with
#                       "<engine>.", else 127.0.0.1 when there is none; any
#                       other case stops with the hosts found
#   --verbose           print what the upstream received for every row
#   --keep              keep the work directory
#   lab mode only:
#   --lab URL           base URL of the scenario's Caddy
#   --allowed-from IP   bind allowed-client requests to this local address
#   --denied-from IP    bind denied-client requests to this local address;
#                       without it denied rows are skipped in lab mode
#   --insecure | --cacert FILE   TLS verification for --lab https URLs
# Environment: CADDY (caddy binary, default: caddy on PATH), ECHO_UPSTREAM
# (prebuilt echo-upstream binary, default: built from tests/echo-upstream),
# APP_AUTH (Authorization header value for rows that use ${APP_AUTH}; a dummy
# value in proxy-only mode).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ALLOWED_SRC=127.0.0.2
DENIED_SRC=127.0.0.3

engine=es
matrix=$here/proxy-matrix.tsv
only=
env_file=
server=
host=
verbose=
keep=
lab_url=
allowed_from=
denied_from=
tls_opt=
cacert=
caddyfile=
upstream_listen=127.0.0.1:0

die() {
	echo "run-proxy-matrix: $*" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case $1 in
	--engine) engine=${2:?}; shift 2 ;;
	--matrix) matrix=${2:?}; shift 2 ;;
	--only) only=${2:?}; shift 2 ;;
	--env-file) env_file=${2:?}; shift 2 ;;
	--server) server=${2:?}; shift 2 ;;
	--host) host=${2:?}; shift 2 ;;
	--verbose) verbose=1; shift ;;
	--keep) keep=1; shift ;;
	--lab) lab_url=${2:?}; shift 2 ;;
	--allowed-from) allowed_from=${2:?}; shift 2 ;;
	--denied-from) denied_from=${2:?}; shift 2 ;;
	--insecure) tls_opt=-k; shift ;;
	--cacert) cacert=${2:?}; shift 2 ;;
	-h | --help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
	-*) die "unknown option $1" ;;
	*)
		if [ -z "$caddyfile" ]; then caddyfile=$1; else upstream_listen=$1; fi
		shift
		;;
	esac
done

case $engine in es | os) ;; *) die "--engine must be es or os" ;; esac
[ -f "$matrix" ] || die "matrix file not found: $matrix"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
if [ -n "$lab_url" ]; then
	[ -z "$caddyfile" ] || die "--lab and a CADDYFILE are mutually exclusive"
else
	[ -n "$caddyfile" ] || die "CADDYFILE is required (or --lab URL)"
	[ -f "$caddyfile" ] || die "Caddyfile not found: $caddyfile"
fi

bad=$(awk -F'\t' '!/^#/ && NF && NF != 13 { printf "line %d has %d columns\n", NR, NF }' "$matrix")
[ -z "$bad" ] || die "$matrix: every row needs 13 tab-separated columns:"$'\n'"$bad"
dups=$(awk -F'\t' '!/^#/ && NF && $1 != "id" { print $1 }' "$matrix" | sort | uniq -d)
[ -z "$dups" ] || die "$matrix: duplicate ids: $dups"

work=$(mktemp -d "${TMPDIR:-/tmp}/proxy-matrix.XXXXXX")
pids=()
cleanup() {
	local rc=$? p
	for p in "${pids[@]}"; do
		kill "$p" 2>/dev/null || true
	done
	for p in "${pids[@]}"; do
		wait "$p" 2>/dev/null || true
	done
	if [ -n "$keep" ] || [ "$rc" -ne 0 ]; then
		echo "# work directory kept: $work" >&2
	else
		rm -rf "$work"
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$work/bodies" "$work/req"

body_file() {
	local spec=$1 n f
	case $spec in
	-) printf '' ;;
	fill:*)
		n=${spec#fill:}
		[[ $n =~ ^[0-9]+$ ]] || die "bad body spec $spec"
		f=$work/bodies/fill-$n
		[ -f "$f" ] || head -c "$n" /dev/zero | tr '\0' x >"$f"
		printf '%s' "$f"
		;;
	*)
		f=$here/fixtures/bodies/$spec
		[ -f "$f" ] || die "body file not found: $f"
		printf '%s' "$f"
		;;
	esac
}

caddy_bin=
base_url=
echo_log=$work/upstream.jsonl

start_proxy_only() {
	caddy_bin=${CADDY:-$(command -v caddy || true)}
	[ -n "$caddy_bin" ] && [ -x "$caddy_bin" ] ||
		die "caddy not found; set CADDY=/path/to/caddy or build one with: GOBIN=\$PWD/bin go install github.com/caddyserver/caddy/v2/cmd/caddy@v\$CADDY_VERSION"
	local caddy_mod
	caddy_mod=$("$caddy_bin" build-info 2>/dev/null | awk '$1 == "mod" && $2 == "github.com/caddyserver/caddy/v2" { print $3 }')

	local echo_bin=${ECHO_UPSTREAM:-}
	if [ -z "$echo_bin" ]; then
		command -v go >/dev/null || die "go is required to build tests/echo-upstream (or set ECHO_UPSTREAM)"
		echo_bin=$work/echo-upstream
		(cd "$here/echo-upstream" && go build -trimpath -o "$echo_bin" .) || die "building echo-upstream failed"
	fi

	"$echo_bin" -listen "$upstream_listen" -addr-file "$work/upstream.addr" -log "$echo_log" 2>"$work/upstream.err" &
	pids+=($!)
	wait_for 10 test -s "$work/upstream.addr" || die "echo upstream did not start: $(cat "$work/upstream.err")"
	local upstream
	upstream=$(cat "$work/upstream.addr")

	local -a envs=()
	if [ -n "$env_file" ]; then
		local line
		while IFS= read -r line || [ -n "$line" ]; do
			[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
			[[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "$env_file: not KEY=VALUE: $line"
			envs+=("$line")
		done <"$env_file"
	fi
	env ${envs[@]+"${envs[@]}"} "$caddy_bin" adapt --config "$caddyfile" --adapter caddyfile \
		>"$work/adapted.json" 2>"$work/adapt.err" || die "caddy adapt failed: $(cat "$work/adapt.err")"

	local servers
	servers=$(jq -r '.apps.http.servers // {} | keys[]' "$work/adapted.json")
	[ -n "$servers" ] || die "the adapted config has no HTTP servers"
	if [ -z "$server" ]; then
		server=$(jq -r '.apps.http.servers | to_entries[]
			| select([.value | .. | objects | select(.handler? == "reverse_proxy")] | length > 0)
			| .key' "$work/adapted.json" | head -n1)
		[ -n "$server" ] || die "no server in the config has a reverse_proxy"
	fi
	grep -qxF "$server" <<<"$servers" || die "no server named $server (have: $(tr '\n' ' ' <<<"$servers"))"

	# Each server gets its own free port so configs with an extra :80
	# redirect server still load; only the tested one is used.
	local s port ports_json='{}'
	for s in $servers; do
		port=$(free_port)
		ports_json=$(jq -c --arg s "$s" --arg p "127.0.0.1:$port" '. + {($s): $p}' <<<"$ports_json")
		[ "$s" == "$server" ] && base_url=http://127.0.0.1:$port
	done

	jq --arg up "$upstream" --arg allowed "$ALLOWED_SRC/32" --argjson ports "$ports_json" '
		.admin = {disabled: true, config: {persist: false}}
		| del(.apps.tls)
		| .apps.http.servers |= with_entries(
			.value.listen = [$ports[.key]]
			| .value.automatic_https = {disable: true}
			| del(.value.tls_connection_policies)
			| del(.value.listener_wrappers))
		| walk(if type == "object" then
			(if (.remote_ip | type) == "object" then .remote_ip.ranges = [$allowed] else . end)
			| (if (.client_ip | type) == "object" then .client_ip.ranges = [$allowed] else . end)
			| (if .handler? == "reverse_proxy" then
				.upstreams = [{dial: $up}] | del(.dynamic_upstreams) | del(.transport.tls)
				| del(.health_checks)
			  else . end)
		  else . end)
	' "$work/adapted.json" >"$work/caddy.json"

	local hosts
	hosts=$(jq -r --arg s "$server" '[.apps.http.servers[$s].routes[]?.match[]?.host[]?] | unique | join(" ")' "$work/caddy.json")
	if [ -z "$host" ]; then
		# Falling back to the first of several sites would run the engine rows
		# against whatever site comes first, such as a Dashboards site.
		host=$(jq -r --arg s "$server" --arg e "$engine." '[.apps.http.servers[$s].routes[]?.match[]?.host[]?] | unique
			| map(select(startswith($e))) as $engine_hosts
			| if length == 0 then "127.0.0.1"
			  elif length == 1 then first
			  elif ($engine_hosts | length) == 1 then $engine_hosts[0]
			  else empty end' "$work/caddy.json")
		[ -n "$host" ] ||
			die "server $server has several site hosts ($hosts) and not exactly one starts with '$engine.'; pass --host NAME"
	fi

	HOME=$work XDG_CONFIG_HOME=$work/xdg-config XDG_DATA_HOME=$work/xdg-data \
		"$caddy_bin" run --config "$work/caddy.json" >"$work/caddy.log" 2>&1 &
	pids+=($!)
	local caddy_pid=$!
	local cport=${base_url##*:}
	if ! wait_for 15 tcp_open 127.0.0.1 "$cport"; then
		die "caddy did not start on 127.0.0.1:$cport: $(tail -n 20 "$work/caddy.log")"
	fi
	kill -0 "$caddy_pid" 2>/dev/null || die "caddy exited: $(tail -n 20 "$work/caddy.log")"

	tap_diag "mode: proxy-only (no engine; backend column not checked)"
	tap_diag "caddyfile: $caddyfile"
	tap_diag "caddy: $caddy_bin ${caddy_mod:-version unknown}"
	tap_diag "server: $server at $base_url, Host: $host (site hosts: ${hosts:-none}; --host picks another)"
	tap_diag "echo upstream: $upstream"
	tap_diag "allowed client: $ALLOWED_SRC, denied client: $DENIED_SRC"
}

upstream_record() {
	jq -c --arg id "$1" 'select((.headers["X-Matrix-Id"] // [])[0] == $id)' "$echo_log" 2>/dev/null | tail -n1
}

# check_upstream RECORD SENT_TARGET SPEC: prints one line per mismatch.
check_upstream() {
	local rec=$1 sent=$2 spec=$3 item key want got
	[ "$spec" == "-" ] && return 0
	local -a items=()
	IFS=';' read -ra items <<<"$spec"
	for item in "${items[@]}"; do
		key=${item%%=*}
		want=${item#*=}
		if [ "$want" == "@sent" ]; then
			want=$sent
		else
			want=$(expand_vars "$want") || return 0
		fi
		case $key in
		target) got=$(jq -r '.request_uri' <<<"$rec") ;;
		method) got=$(jq -r '.method' <<<"$rec") ;;
		proto) got=$(jq -r '.proto' <<<"$rec") ;;
		body_bytes) got=$(jq -r '.body_bytes' <<<"$rec") ;;
		body_error) got=$(jq -r '.body_error // "none"' <<<"$rec") ;;
		header:*) got=$(jq -r --arg h "${key#header:}" '(.headers[$h] // ["<absent>"])[0]' <<<"$rec") ;;
		*) echo "unknown upstream check $key"; continue ;;
		esac
		[ "$got" == "$want" ] || echo "upstream $key: expected $want, got $got"
	done
}

backend_unchecked=0

# lab_mismatch EXPECTATION BACKEND: prints why the last response does not
# meet one proxy-column alternative, nothing when it does. Proxy-generated
# answers carry no body here; engine answers always do.
lab_mismatch() {
	local want=$1 backend=$2 has_body=
	[ -s "$HTTP_BODY_FILE" ] && has_body=1
	case $want in
	abort)
		[ "$HTTP_RESULT" == abort ] || echo "expected abort, got $HTTP_RESULT"
		;;
	[0-9][0-9][0-9])
		if [ "$HTTP_RESULT" != "$want" ]; then
			echo "expected $want from the proxy, got $HTTP_RESULT"
		elif [ -n "$has_body" ]; then
			echo "expected an empty proxy response, got a body: $(head -c 200 "$HTTP_BODY_FILE")"
		fi
		;;
	'!upstream')
		if [ "$HTTP_RESULT" != abort ] && [ -n "$has_body" ]; then
			echo "expected no engine answer, got $HTTP_RESULT with body: $(head -c 200 "$HTTP_BODY_FILE")"
		fi
		;;
	upstream)
		case $backend in
		-) [ -n "$has_body" ] || echo "expected an engine answer, got $HTTP_RESULT without a body" ;;
		[0-9][0-9][0-9])
			[ "$HTTP_RESULT" == "$backend" ] || echo "expected $backend from the engine, got $HTTP_RESULT"
			;;
		[0-9]xx)
			if ! [[ $HTTP_RESULT == "${backend:0:1}"[0-9][0-9] ]] || [ -z "$has_body" ]; then
				echo "expected $backend from the engine, got $HTTP_RESULT"
			fi
			;;
		bulk-item-403)
			if [ "$HTTP_RESULT" != 200 ] ||
				! jq -e '.errors == true and ([.items[][] | .status] | length > 0 and all(. == 403))' "$HTTP_BODY_FILE" >/dev/null 2>&1; then
				echo "expected 200 with every bulk item 403, got $HTTP_RESULT: $(head -c 300 "$HTTP_BODY_FILE")"
			fi
			;;
		*) echo "unknown backend expectation $backend" ;;
		esac
		;;
	*) echo "unknown proxy expectation $want" ;;
	esac
}

run_row() {
	local id=$1 lab=$2 client=$3 method=$4 target=$5 headers=$6 body=$7 proxy=$8 ups=$9 backend=${10} layer=${11} note=${12}
	target=${target//\{HOST\}/$host}
	local desc="$id [$lab] $client $method $target -> $proxy"
	[ "$backend" != "-" ] && desc+=" / backend $backend"
	[ "$layer" != "-" ] && desc+=" (stopped by $layer)"

	local src= url=$base_url
	if [ -n "$lab_url" ]; then
		url=$lab_url
		if [ "$client" == "denied" ]; then
			if [ -z "$denied_from" ]; then
				tap_skip "$desc" "lab mode needs --denied-from for denied-client rows"
				return
			fi
			src=$denied_from
		else
			src=$allowed_from
		fi
	else
		if [ "$client" == "denied" ]; then src=$DENIED_SRC; else src=$ALLOWED_SRC; fi
	fi

	local -a opts=(-X "$method" -t "$target" -o "$work/req/$id" -H "X-Matrix-Id: $id")
	mkdir -p "$work/req/$id"
	[ -n "$src" ] && opts+=(-s "$src")
	[ -n "$tls_opt" ] && opts+=("$tls_opt")
	[ -n "$cacert" ] && opts+=(-c "$cacert")
	local has_host= h expanded
	if [ "$headers" != "-" ]; then
		local -a hlist=()
		IFS='|' read -ra hlist <<<"$headers"
		for h in "${hlist[@]}"; do
			if [ "$h" == "HTTP/1.0" ]; then
				opts+=(-1)
				continue
			fi
			expanded=$(expand_vars "$h") || die "row $id: cannot expand header $h"
			opts+=(-H "$expanded")
			[[ ${h,,} == host:* ]] && has_host=1
		done
	fi
	[ -z "$has_host" ] && [ -n "$host" ] && opts+=(-H "Host: $host")
	local bf
	bf=$(body_file "$body")
	[ -n "$bf" ] && opts+=(-b "$bf")

	http_request "${opts[@]}" "$url"

	local -a problems=() alts=()
	IFS='|' read -ra alts <<<"$proxy"
	local a m matched=
	if [ -z "$lab_url" ]; then
		local actual=$HTTP_RESULT rec
		if [ -n "$(http_header X-Echo-Upstream)" ]; then actual=upstream; fi
		rec=$(upstream_record "$id")
		for a in "${alts[@]}"; do
			if [ "$a" == "$actual" ] || { [ "$a" == '!upstream' ] && [ "$actual" != upstream ]; }; then
				matched=1
			fi
		done
		[ -n "$matched" ] || problems+=("expected $proxy, got $actual")
		# Upstream checks on a row the client sees no upstream answer for
		# describe a request the upstream gets but never answers, such as a
		# body cut off at the size limit; without checks it must not arrive.
		if [ "$actual" != upstream ] && [ -n "$rec" ] && [ "$ups" == "-" ]; then
			problems+=("the upstream received it: $(jq -r '.request_line + " body_bytes=" + (.body_bytes|tostring)' <<<"$rec")")
		fi
		if [ "$actual" != upstream ] && [ -z "$rec" ] && [ "$ups" != "-" ] && [[ $proxy != *upstream* ]]; then
			problems+=("expected the upstream to receive part of it ($ups); it received nothing")
		fi
		if [ "$actual" == upstream ] && [ -z "$rec" ]; then
			problems+=("echo marker present but no upstream log record")
		fi
		if [ -n "$rec" ] && { [ "$actual" == upstream ] || [[ $proxy != *upstream* ]]; }; then
			while IFS= read -r m; do
				[ -n "$m" ] && problems+=("$m")
			done < <(check_upstream "$rec" "$target" "$ups")
		fi
		[ "$backend" != "-" ] && backend_unchecked=$((backend_unchecked + 1))
		if [ -n "$verbose" ] && [ -n "$rec" ]; then
			tap_diag "$id upstream saw: $(jq -r '.request_line + " body_bytes=" + (.body_bytes|tostring)' <<<"$rec")"
		fi
	else
		if [ "$proxy" == upstream ] && [ "$backend" == "-" ]; then
			tap_skip "$desc" "no backend expectation for this row"
			return
		fi
		local -a seen=()
		for a in "${alts[@]}"; do
			m=$(lab_mismatch "$a" "$backend")
			if [ -z "$m" ]; then
				matched=1
				break
			fi
			seen+=("$m")
		done
		[ -n "$matched" ] || problems+=("${seen[@]}")
	fi

	if [ ${#problems[@]} -eq 0 ]; then
		tap_ok "$desc"
	else
		[ "$HTTP_CURL_ERR" ] && problems+=("curl: $HTTP_CURL_ERR")
		problems+=("note: $note")
		tap_not_ok "$desc" "${problems[@]}"
	fi
}

tap_init
if [ -n "$lab_url" ]; then
	: "${APP_AUTH:?lab mode needs APP_AUTH, the Authorization header value of the scenario app credential}"
	base_url=$lab_url
	host=${host:-$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$lab_url")}
	tap_diag "mode: lab against $lab_url (engine $engine)"
else
	export APP_AUTH=${APP_AUTH:-ApiKey cHJveHktb25seTpub3QtYS1yZWFsLWtleQ==}
	start_proxy_only
fi

rows=0
while IFS=$'\t' read -r id lab eng client method target headers body proxy ups backend layer note; do
	[[ -z $id || $id == \#* || $id == id ]] && continue
	[ "$eng" == any ] || [ "$eng" == "$engine" ] || continue
	if [ -n "$only" ] && ! [[ $id =~ $only ]]; then continue; fi
	rows=$((rows + 1))
	run_row "$id" "$lab" "$client" "$method" "$target" "$headers" "$body" "$proxy" "$ups" "$backend" "$layer" "$note"
done <"$matrix"

[ "$rows" -gt 0 ] || die "no rows selected"
if [ "$backend_unchecked" -gt 0 ]; then
	tap_diag "$backend_unchecked backend expectations not checked in proxy-only mode; run with --lab against a scenario"
fi
tap_finish
