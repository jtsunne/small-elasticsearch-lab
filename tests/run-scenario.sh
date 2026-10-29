#!/usr/bin/env bash
# Brings a scenario up, waits for health, runs its expected.tsv, prints TAP and
# brings it down with its volumes. The column format is in tests/README.md.
#
# usage: tests/run-scenario.sh [--keep-up] [--plan-only] SCENARIO
#   --keep-up    leave the stack running afterwards (default: down -v)
#   --plan-only  parse expected.tsv and print how each row would run; needs
#                no Docker, starts nothing
# Environment:
#   TEST_ALLOWED_SUBNET, TEST_DENIED_SUBNET   client networks (defaults
#       10.231.1.0/24 and 10.231.2.0/24); must not overlap existing networks
#   TEST_ALLOWLIST_VARS   compose variables set to TEST_ALLOWED_SUBNET for the
#       run (default "ALLOWED_CIDRS ALLOW_CIDRS")
#   NODE_SERVICE          node service for "node" rows (default: the first
#       service named es<N> or os<N>)
#   CADDY_SERVICE         proxy service (default caddy)
#   APP_USER              user behind the app_user credential (default: APP_USER
#       from .env, else app_x)
#   RESULTS_DIR           where the TAP copy and recorded bodies go (default
#       results/tests)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

keep_up=
plan_only=
scenario=
while [ $# -gt 0 ]; do
	case $1 in
	--keep-up) keep_up=1; shift ;;
	--plan-only) plan_only=1; shift ;;
	-h | --help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
	-*) echo "run-scenario: unknown option $1" >&2; exit 2 ;;
	*) scenario=$1; shift ;;
	esac
done

die() {
	echo "run-scenario: $*" >&2
	exit 2
}

[ -n "$scenario" ] || die "usage: tests/run-scenario.sh [--keep-up] [--plan-only] SCENARIO"
sdir=$repo/scenarios/$scenario
[ -d "$sdir" ] || die "unknown scenario '$scenario'"
expected=$sdir/expected.tsv
[ -f "$expected" ] || die "scenario '$scenario' has no expected.tsv"
command -v jq >/dev/null || die "jq is required"

declare -A col=()
header=$(grep -m1 -v '^#' "$expected")
i=0
IFS=$'\t' read -ra hnames <<<"$header"
for name in "${hnames[@]}"; do
	col[$name]=$i
	i=$((i + 1))
done
ncols=$i
for c in id method path expect_status; do
	[ -n "${col[$c]+set}" ] || die "$expected: header has no '$c' column"
done
bad=$(awk -F'\t' -v n="$ncols" '!/^#/ && NF && NF != n { printf "line %d has %d columns, header has %d\n", NR, NF, n }' "$expected")
[ -z "$bad" ] || die "$expected:"$'\n'"$bad"

# field ROWVAR NAME...: the first of the named columns present in the header.
field() {
	local -n _row=$1
	shift
	local n
	for n in "$@"; do
		if [ -n "${col[$n]+set}" ]; then
			printf '%s' "${_row[${col[$n]}]}"
			return
		fi
	done
	printf -- '-'
}

# Row normalisation. T3 writes site/from (site: node, host or a proxy site
# name; from: allowed, denied), T4 writes client/site (client: node, allowed,
# denied; site: a proxy site name). Both reduce to a kind, a site and a source.
row_kind= row_site= row_from=
classify_row() {
	local v
	row_kind= row_site= row_from=
	for v in "$@"; do
		case $v in
		- | '') ;;
		node | host) row_kind=$v ;;
		allowed | denied) row_from=$v ;;
		*) row_site=$v ;;
		esac
	done
	if [ -z "$row_kind" ]; then
		[ -n "$row_site" ] || return 1
		row_kind=proxy
		row_from=${row_from:-allowed}
	fi
}

# auth_config AUTH: curl config lines for the credential, read from the test
# environment. Config lines never reach argv, so ps does not show secrets.
auth_config() {
	local a=$1 user var val
	case $a in
	- | none) return 0 ;;
	elastic) user=elastic var=ELASTIC_PASSWORD ;;
	admin) user=admin var=ADMIN_PASSWORD ;;
	app_user)
		user=$(tenv APP_USER 2>/dev/null) || user=
		if [ -z "$user" ] || [ "$user" == "<APP_USER>" ]; then
			user=app_x
		fi
		var=APP_PASSWORD
		;;
	demo_*)
		printf 'user = "%s:%s"\n' "${a#demo_}" "${a#demo_}"
		return 0
		;;
	app_key)
		val=$(tenv APP_API_KEY) || return 1
		printf 'header = "Authorization: ApiKey %s"\n' "$val"
		return 0
		;;
	bad_key)
		printf 'header = "Authorization: ApiKey %s"\n' "$(printf 'not-a-key:not-a-secret' | base64)"
		return 0
		;;
	apikey/*)
		val=$(tenv "${a#apikey/}") || return 1
		printf 'header = "Authorization: ApiKey %s"\n' "$val"
		return 0
		;;
	*/*) user=${a%%/*} var=${a#*/} ;;
	*=*)
		printf 'user = "%s:%s"\n' "${a%%=*}" "${a#*=}"
		return 0
		;;
	*)
		echo "unknown auth '$a'" >&2
		return 1
		;;
	esac
	val=$(tenv "$var") || return 1
	val=${val//\\/\\\\}
	val=${val//\"/\\\"}
	printf 'user = "%s:%s"\n' "$user" "$val"
}

declare -A testenv=()
tenv() {
	if [ -n "${!1+set}" ] && [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		printf '%s' "${!1}"
	elif [ -n "${testenv[$1]+set}" ]; then
		printf '%s' "${testenv[$1]}"
	elif [ -n "$plan_only" ]; then
		printf '<%s>' "$1"
	else
		echo "variable $1 is not set (not in the environment, .env or setup output)" >&2
		return 1
	fi
}

# load_env FILE: KEY=VALUE lines into testenv, without sourcing (values may
# hold spaces, and a .env is data, not a script).
load_env() {
	local line k v
	while IFS= read -r line || [ -n "$line" ]; do
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
		k=${BASH_REMATCH[1]}
		v=${BASH_REMATCH[2]}
		if [[ $v =~ ^\"(.*)\"$ || $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
		testenv[$k]=$v
	done <"$1"
}

# body_spec SPEC: prints "file PATH", "bytes N", "inline TEXT" or "none".
body_spec() {
	local b=$1
	case $b in
	-) echo none ;;
	bytes:* | zeros:*)
		[[ ${b#*:} =~ ^[0-9]+$ ]] || return 1
		echo "bytes ${b#*:}"
		;;
	inline:*) echo "inline ${b#inline:}" ;;
	*)
		b=${b#@}
		[ -f "$sdir/$b" ] || { echo "body file not found: $sdir/$b" >&2; return 1; }
		echo "file $sdir/$b"
		;;
	esac
}

write_body() {
	local spec=$1
	case $spec in
	none) ;;
	bytes\ *) head -c "${spec#bytes }" /dev/zero | tr '\0' x ;;
	inline\ *) printf '%s' "${spec#inline }" ;;
	file\ *) cat "${spec#file }" ;;
	esac
}

# The script each client runs with bash: the first stdin line is a count n,
# the next n lines a curl config (credentials, headers), the rest the body.
# bash reads a pipe byte by byte, so curl gets the stream right after them.
# shellcheck disable=SC2016 # expanded by the client's bash
remote='set -u
method=$1 target=$2 url=$3 hasbody=$4 resolve=$5
read -r n
cfg=
for ((i = 0; i < n; i++)); do IFS= read -r l; cfg+=$l$'"'"'\n'"'"'; done
args=(-sS --path-as-is -k -H "Expect:" -w "\n%{http_code}" --max-time 30)
if [ "$method" = HEAD ]; then args+=(--head -o /dev/null); else args+=(-X "$method"); fi
[ "$target" != - ] && args+=(--request-target "$target")
[ "$resolve" != - ] && args+=(--resolve "$resolve")
[ "$hasbody" = 1 ] && args+=(--data-binary @-)
curl "${args[@]}" -K <(printf "%s" "$cfg") "$url" 2>/dev/null
rc=$?
printf "\n__RC__ %s\n" "$rc"'

run_client() {
	local -a runner=("$@")
	local cfg=$CUR_CFG nlines=0
	[ -n "$cfg" ] && nlines=$(printf '%s' "$cfg" | grep -c '')
	{
		printf '%s\n' "$nlines"
		[ -n "$cfg" ] && printf '%s\n' "$cfg"
		write_body "$CUR_BODY"
	} | "${runner[@]}" -c "$remote" _ "$CUR_METHOD" "$CUR_TARGET" "$CUR_URL" "$CUR_HASBODY" "$CUR_RESOLVE" >"$work/out" 2>"$work/err" || true
}

# parse_client_output: splits $work/out into body, status and curl exit.
parse_client_output() {
	local out rc_line status_line
	out=$(cat "$work/out")
	rc_line=${out##*$'\n'}
	out=${out%$'\n'*}
	status_line=${out##*$'\n'}
	out=${out%$'\n'*}
	if [[ $rc_line =~ ^__RC__\ ([0-9]+)$ ]]; then
		RES_RC=${BASH_REMATCH[1]}
	else
		RES_RC=999
	fi
	RES_STATUS=$status_line
	printf '%s' "$out" >"$work/body"
	case $RES_RC in
	0) RES_RESULT=$RES_STATUS ;;
	7) RES_RESULT=refused ;;
	999) RES_RESULT="error:client $(head -c 200 "$work/err")" ;;
	*) RES_RESULT=$(http_classify "$RES_RC" "$RES_STATUS") ;;
	esac
}

host_request() {
	local cfgfile=$work/host.cfg
	printf '%s' "$CUR_CFG" >"$cfgfile"
	local -a args=(-sS --path-as-is -H 'Expect:' -o "$work/body" -w '%{http_code}' --max-time 30 -K "$cfgfile")
	if [ "$CUR_METHOD" == HEAD ]; then args+=(--head); else args+=(-X "$CUR_METHOD"); fi
	[ "$CUR_HASBODY" == 1 ] && args+=(--data-binary @-)
	local rc=0
	RES_STATUS=$(write_body "$CUR_BODY" | curl "${args[@]}" "$CUR_URL" 2>"$work/err") || rc=$?
	rm -f "$cfgfile"
	RES_RC=$rc
	case $rc in
	0) RES_RESULT=$RES_STATUS ;;
	7) RES_RESULT=refused ;;
	*) RES_RESULT=$(http_classify "$rc" "$RES_STATUS") ;;
	esac
}

check_expect() {
	local exp=$1 jqraw=$2 alt ok= out
	local -a alts=() problems=()
	IFS='|' read -ra alts <<<"$exp"
	for alt in "${alts[@]}"; do
		[ "$alt" == "$RES_RESULT" ] && ok=1
	done
	[ -n "$ok" ] || problems+=("expected $exp, got $RES_RESULT")
	local body=$work/body
	case $jqraw in
	- | '') ;;
	record)
		mkdir -p "$results/$stamp-$scenario"
		cp "$body" "$results/$stamp-$scenario/$CUR_ID.json"
		;;
	jq:*)
		if ! out=$(jq -e "${jqraw#jq:}" "$body" 2>&1); then
			problems+=("jq -e ${jqraw#jq:}: ${out:-<empty>}")
		fi
		;;
	contains:*) grep -qF -- "${jqraw#contains:}" "$body" || problems+=("body does not contain ${jqraw#contains:}") ;;
	'!contains:'*) ! grep -qF -- "${jqraw#!contains:}" "$body" || problems+=("body contains ${jqraw#!contains:}") ;;
	*) problems+=("unknown expectation $jqraw") ;;
	esac
	if [ ${#problems[@]} -gt 0 ]; then
		problems+=("body: $(head -c 300 "$body")")
		tap_not_ok "$CUR_DESC" "${problems[@]}"
	else
		tap_ok "$CUR_DESC"
		[ "$jqraw" == record ] && tap_diag "  recorded $results/$stamp-$scenario/$CUR_ID.json"
	fi
	return 0
}

# Expectation column: T3 uses "expect" with jq:/contains:/record prefixes,
# T4 uses "expect_jq" holding a bare jq expression.
expect_of() {
	local -n _r=$1
	if [ -n "${col[expect]+set}" ]; then
		printf '%s' "${_r[${col[expect]}]}"
	elif [ -n "${col[expect_jq]+set}" ]; then
		local v=${_r[${col[expect_jq]}]}
		if [ "$v" == "-" ]; then printf -- '-'; else printf 'jq:%s' "$v"; fi
	else
		printf -- '-'
	fi
}

work=
stamp=$(date -u +%Y-%m-%d)
results=${RESULTS_DIR:-$repo/results/tests}
compose=()
networks=()
caddy_cid=
cleanup() {
	local rc=$? n
	if [ -n "$caddy_cid" ]; then
		for n in "${networks[@]}"; do
			docker network disconnect -f "$n" "$caddy_cid" >/dev/null 2>&1 || true
		done
	fi
	for n in "${networks[@]}"; do
		docker network rm "$n" >/dev/null 2>&1 || true
	done
	if [ ${#compose[@]} -gt 0 ] && [ -z "$keep_up" ]; then
		"${compose[@]}" down -v >&2 || true
	fi
	[ -n "$work" ] && rm -rf "$work"
	exit "$rc"
}

if [ -z "$plan_only" ]; then
	command -v docker >/dev/null || die "docker is not installed"
	docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable by this user (docker info failed); nothing was started"
	[ -f "$sdir/compose.yaml" ] || die "scenario '$scenario' has no compose.yaml"
fi
work=$(mktemp -d)
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -z "$plan_only" ]; then
	mkdir -p "$results"
	exec > >(tee "$results/$stamp-$scenario.tap")
fi

tap_init
tap_diag "scenario: $scenario ($expected)"

if [ -n "$plan_only" ]; then
	[ -f "$sdir/.env" ] && load_env "$sdir/.env"
else
	if [ ! -f "$sdir/.env" ]; then
		[ -x "$sdir/init-env.sh" ] || die "$sdir/.env is missing and there is no init-env.sh; copy .env.example to .env"
		tap_diag "no .env: running init-env.sh"
		"$sdir/init-env.sh" >&2
	fi
	if [ -x "$sdir/certs/gen-certs.sh" ] && ! compgen -G "$sdir/certs/*.pem" >/dev/null; then
		tap_diag "no certificates: running certs/gen-certs.sh"
		"$sdir/certs/gen-certs.sh" >&2
	fi
	if [ -x "$sdir/init-security.sh" ]; then
		tap_diag "running init-security.sh"
		"$sdir/init-security.sh" >&2
	fi
	load_env "$sdir/.env"

	allowed_subnet=${TEST_ALLOWED_SUBNET:-10.231.1.0/24}
	denied_subnet=${TEST_DENIED_SUBNET:-10.231.2.0/24}
	# Compose gives the shell environment precedence over --env-file values,
	# so the allowlist becomes the allowed client network for this run only.
	for v in ${TEST_ALLOWLIST_VARS:-ALLOWED_CIDRS ALLOW_CIDRS}; do
		export "$v=$allowed_subnet"
	done
	compose=(docker compose --project-directory "$sdir" --env-file "$repo/versions.env"
		--env-file "$sdir/.env" -f "$sdir/compose.yaml")
	project=$("${compose[@]}" config --format json | jq -r .name)
	"${compose[@]}" up -d --wait >&2 || die "compose up --wait failed"
	tap_diag "up: project $project"

	node_service=${NODE_SERVICE:-$("${compose[@]}" config --services | grep -m1 -E '^(es|os)[0-9]+$' || true)}
	[ -n "$node_service" ] || die "no node service found; set NODE_SERVICE"
	node_cid=$("${compose[@]}" ps -q "$node_service")
	[ -n "$node_cid" ] || die "service $node_service is not running"
	node_image=$(docker inspect -f '{{.Config.Image}}' "$node_cid")

	# The node answers plain HTTP or HTTPS depending on the scenario; probe
	# once from inside its own container.
	node_url=http://127.0.0.1:9200
	if ! docker exec "$node_cid" curl -s -o /dev/null --max-time 10 "$node_url/" 2>/dev/null; then
		node_url=https://127.0.0.1:9200
	fi
	tap_diag "node: $node_service at $node_url (from inside the container)"

	caddy_service=${CADDY_SERVICE:-caddy}
	caddy_cid=$("${compose[@]}" ps -q "$caddy_service" 2>/dev/null || true)
	if [ -n "$caddy_cid" ]; then
		for pair in "allowed $allowed_subnet" "denied $denied_subnet"; do
			read -r kind subnet <<<"$pair"
			net=$project-test-$kind
			docker network create --subnet "$subnet" "$net" >/dev/null ||
				die "cannot create network $net with subnet $subnet (set TEST_${kind^^}_SUBNET)"
			networks+=("$net")
			docker network connect "$net" "$caddy_cid"
		done
		tap_diag "clients: allowed from $allowed_subnet, denied from $denied_subnet (allowlist variables set to $allowed_subnet)"
	fi

	if [ -x "$sdir/setup-roles.sh" ]; then
		tap_diag "running setup-roles.sh"
		"$sdir/setup-roles.sh" >"$work/setup.out" || die "setup-roles.sh failed (exit $?); no rows were run"
		while IFS= read -r line; do
			if [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
				testenv[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
			fi
		done <"$work/setup.out"
	fi
fi

caddy_ip() {
	docker inspect -f "{{(index .NetworkSettings.Networks \"$1\").IPAddress}}" "$caddy_cid"
}

while IFS= read -r line; do
	[[ -z $line || $line == \#* ]] && continue
	IFS=$'\t' read -ra r <<<"$line"
	CUR_ID=${r[${col[id]}]}
	[ "$CUR_ID" == id ] && continue
	lab=$(field r lab lab_test test)
	CUR_METHOD=${r[${col[method]}]}
	path=${r[${col[path]}]}
	headers=$(field r headers)
	estatus=${r[${col[expect_status]}]}
	expect=$(expect_of r)
	CUR_DESC="$CUR_ID [$lab] $CUR_METHOD $path -> $estatus"
	[ "$expect" != "-" ] && CUR_DESC+=" ($expect)"

	if ! classify_row "$(field r site)" "$(field r from)" "$(field r client)"; then
		tap_not_ok "$CUR_DESC" "cannot tell where this row runs: site/from/client are all empty"
		continue
	fi
	if ! CUR_CFG=$(auth_config "$(field r auth)" 2>"$work/auth.err"); then
		tap_not_ok "$CUR_DESC" "auth: $(cat "$work/auth.err")"
		continue
	fi
	if [ "$headers" != "-" ]; then
		IFS='|' read -ra hl <<<"$headers"
		for h in "${hl[@]}"; do
			h=${h//\\/\\\\}
			CUR_CFG+=$'\n'"header = \"${h//\"/\\\"}\""
		done
	fi
	CUR_CFG=${CUR_CFG#$'\n'}
	if ! CUR_BODY=$(body_spec "$(field r body)"); then
		tap_not_ok "$CUR_DESC" "bad body column: $(field r body)"
		continue
	fi
	CUR_HASBODY=0
	[ "$CUR_BODY" != none ] && CUR_HASBODY=1
	# curl labels a --data-binary body application/x-www-form-urlencoded, which
	# OpenSearch rejects with 406, so the type is always stated in the row.
	if [ "$CUR_HASBODY" == 1 ] && ! grep -qiE '^[[:space:]]*content-type:' <<<"${headers//|/$'\n'}"; then
		tap_not_ok "$CUR_DESC" "the row sends a body but no Content-Type header; add one to the headers column"
		continue
	fi
	CUR_RESOLVE=-
	CUR_TARGET=$path

	if [ -n "$plan_only" ]; then
		src=$row_kind
		[ "$row_kind" == proxy ] && src="proxy:$row_site from $row_from"
		cfg_shown=$(sed -E 's/(user = "[^:]*:).*"/\1***"/; s/(ApiKey ).*"/\1***"/' <<<"$CUR_CFG" | paste -sd ';' -)
		tap_ok "$CUR_DESC | $src | cfg: ${cfg_shown:--} | body: $CUR_BODY | expect: $estatus $expect"
		continue
	fi

	case $row_kind in
	node)
		CUR_URL=$node_url
		run_client docker exec -i "$node_cid" bash
		parse_client_output
		;;
	host)
		CUR_URL=$path
		host_request
		;;
	proxy)
		if [ -z "$caddy_cid" ]; then
			tap_skip "$CUR_DESC" "scenario has no $caddy_service service"
			continue
		fi
		siteaddr=$(tenv "${row_site^^}_SITE_ADDRESS") || {
			tap_not_ok "$CUR_DESC" "set ${row_site^^}_SITE_ADDRESS in .env"
			continue
		}
		scheme=https
		[[ $siteaddr == http://* ]] && scheme=http
		siteaddr=${siteaddr#*://}
		sitehost=${siteaddr%%:*}
		siteport=443
		[ "$scheme" == http ] && siteport=80
		[[ $siteaddr == *:* ]] && siteport=${siteaddr##*:}
		net=$project-test-$row_from
		ip=$(caddy_ip "$net")
		CUR_URL=$scheme://$sitehost:$siteport
		CUR_RESOLVE=$sitehost:$siteport:$ip
		run_client docker run --rm -i --network "$net" --entrypoint bash "$node_image"
		parse_client_output
		;;
	esac
	check_expect "$estatus" "$expect"
done <"$expected"

tap_finish
