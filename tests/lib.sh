# Shared helpers for the test runners: TAP output, assertions, curl wrapper.
# Source it from bash; it sets no shell options of its own.
#
# TAP: version 13 with a trailing plan, so a runner does not have to count
# its tests up front. tap_finish prints the plan and returns 1 when any test
# failed.

TAP_COUNT=0
TAP_FAILED=0
TAP_SKIPPED=0

tap_init() {
	TAP_COUNT=0
	TAP_FAILED=0
	TAP_SKIPPED=0
	echo "TAP version 13"
}

tap_diag() {
	local line
	while IFS= read -r line; do
		printf '# %s\n' "$line"
	done <<<"$*"
}

tap_ok() {
	TAP_COUNT=$((TAP_COUNT + 1))
	printf 'ok %d - %s\n' "$TAP_COUNT" "$1"
}

# tap_not_ok DESC [DIAG...]: each DIAG argument becomes one or more # lines.
tap_not_ok() {
	TAP_COUNT=$((TAP_COUNT + 1))
	TAP_FAILED=$((TAP_FAILED + 1))
	printf 'not ok %d - %s\n' "$TAP_COUNT" "$1"
	shift
	local d
	for d in "$@"; do
		tap_diag "  $d"
	done
}

tap_skip() {
	TAP_COUNT=$((TAP_COUNT + 1))
	TAP_SKIPPED=$((TAP_SKIPPED + 1))
	printf 'ok %d - %s # SKIP %s\n' "$TAP_COUNT" "$1" "$2"
}

tap_finish() {
	printf '1..%d\n' "$TAP_COUNT"
	printf '# tests %d, failed %d, skipped %d\n' "$TAP_COUNT" "$TAP_FAILED" "$TAP_SKIPPED"
	[ "$TAP_FAILED" -eq 0 ]
}

assert_eq() {
	local actual=$1 expected=$2 desc=$3
	if [ "$actual" == "$expected" ]; then
		tap_ok "$desc"
	else
		tap_not_ok "$desc" "expected: $expected" "actual:   $actual"
	fi
}

# assert_match ACTUAL ERE DESC
assert_match() {
	local actual=$1 re=$2 desc=$3
	if [[ $actual =~ $re ]]; then
		tap_ok "$desc"
	else
		tap_not_ok "$desc" "expected to match: $re" "actual: $actual"
	fi
}

# assert_jq FILE EXPR DESC: passes when `jq -e EXPR` is true on FILE.
assert_jq() {
	local file=$1 expr=$2 desc=$3 out
	if out=$(jq -e "$expr" "$file" 2>&1); then
		tap_ok "$desc"
	else
		tap_not_ok "$desc" "jq -e $expr" "result: ${out:-<empty>}" "body: $(head -c 300 "$file" 2>/dev/null)"
	fi
}

# http_classify CURL_EXIT STATUS: abort when the server closed the connection
# without an HTTP response (Caddy's abort directive), the status otherwise.
# 52 is an empty reply, 56 a reset while reading, 55 a reset while curl was
# still sending a large body.
http_classify() {
	local rc=$1 status=$2
	case $rc in
	0) printf '%s' "$status" ;;
	52 | 55 | 56) printf 'abort' ;;
	*) printf 'error:curl-%s' "$rc" ;;
	esac
}

# http_request [options] URL
#   -X METHOD        request method (default GET)
#   -H 'Name: v'     header, repeatable; 'Name:' removes a header curl adds
#   -b FILE          request body from FILE (sent as is)
#   -t TARGET        request-target sent verbatim on the request line; no
#                    dot-segment removal, no re-encoding, absolute form allowed
#   -s ADDR          bind the client socket to this local address
#   -1               use HTTP/1.0
#   -k               do not verify TLS certificates
#   -c FILE          CA file for TLS verification
#   -o DIR           where to write body and headers (default: HTTP_OUT_DIR or a temp dir)
# Sets HTTP_RESULT (status code, "abort" or "error:curl-N"), HTTP_STATUS,
# HTTP_CURL_EXIT, HTTP_BODY_FILE, HTTP_HEADERS_FILE, HTTP_CURL_ERR.
http_request() {
	local method=GET body= target= src= http10= insecure= cafile= outdir=${HTTP_OUT_DIR:-}
	local -a hdrs=()
	local OPTIND=1 opt
	while getopts 'X:H:b:t:s:1kc:o:' opt; do
		case $opt in
		X) method=$OPTARG ;;
		H) hdrs+=(-H "$OPTARG") ;;
		b) body=$OPTARG ;;
		t) target=$OPTARG ;;
		s) src=$OPTARG ;;
		1) http10=1 ;;
		k) insecure=1 ;;
		c) cafile=$OPTARG ;;
		o) outdir=$OPTARG ;;
		*) return 2 ;;
		esac
	done
	shift $((OPTIND - 1))
	local url=${1:?http_request: URL required}
	if [ -z "$outdir" ]; then
		outdir=$(mktemp -d)
	fi
	HTTP_BODY_FILE=$outdir/body
	HTTP_HEADERS_FILE=$outdir/headers
	local errfile=$outdir/curl.err
	: >"$HTTP_BODY_FILE"
	: >"$HTTP_HEADERS_FILE"

	# --path-as-is and --request-target keep curl from normalising what the
	# test is trying to send. Expect is dropped so a large body is sent in one
	# go and the response to it is the proxy's verdict, not a 100 Continue.
	local -a args=(--silent --show-error --path-as-is --max-time "${HTTP_MAX_TIME:-20}"
		-H 'Expect:' -o "$HTTP_BODY_FILE" -D "$HTTP_HEADERS_FILE"
		-w '%{http_code}')
	# curl -X HEAD would wait for a body that never comes.
	if [ "$method" == HEAD ]; then
		args+=(--head)
	else
		args+=(-X "$method")
	fi
	[ -n "$target" ] && args+=(--request-target "$target")
	[ -n "$src" ] && args+=(--interface "$src")
	[ -n "$http10" ] && args+=(--http1.0)
	[ -n "$insecure" ] && args+=(--insecure)
	[ -n "$cafile" ] && args+=(--cacert "$cafile")
	[ -n "$body" ] && args+=(--data-binary "@$body")
	args+=("${hdrs[@]}")

	local code rc=0
	code=$(curl "${args[@]}" "$url" 2>"$errfile") || rc=$?
	[ "$method" == HEAD ] && : >"$HTTP_BODY_FILE"
	HTTP_CURL_EXIT=$rc
	HTTP_STATUS=${code:-000}
	HTTP_CURL_ERR=$(head -c 500 "$errfile")
	HTTP_RESULT=$(http_classify "$rc" "$HTTP_STATUS")
}

# http_header NAME: value of the last NAME header in HTTP_HEADERS_FILE.
http_header() {
	local name=$1
	tr -d '\r' <"$HTTP_HEADERS_FILE" | awk -v n="$name" '
		BEGIN { n = tolower(n) }
		{ i = index($0, ":"); if (i > 0 && tolower(substr($0, 1, i - 1)) == n) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v) } }
		END { if (v != "") print v }'
}

# expand_vars STRING: replaces ${NAME} with the value of environment variable
# NAME. Only [A-Z0-9_] names are expanded and nothing is evaluated, so table
# cells cannot run commands. An unset variable is an error.
expand_vars() {
	local s=$1 out= name rest
	while [[ $s == *'${'* ]]; do
		out+=${s%%'${'*}
		rest=${s#*'${'}
		if [[ $rest =~ ^([A-Z0-9_]+)\}(.*)$ ]]; then
			name=${BASH_REMATCH[1]}
			s=${BASH_REMATCH[2]}
			if [ -z "${!name+set}" ]; then
				echo "expand_vars: \${$name} is not set" >&2
				return 1
			fi
			out+=${!name}
		else
			out+='${'
			s=$rest
		fi
	done
	printf '%s' "$out$s"
}

# wait_for TIMEOUT_S CMD...: runs CMD every 0.2 s until it succeeds.
wait_for() {
	local timeout=$1 deadline
	shift
	deadline=$((SECONDS + timeout))
	until "$@" >/dev/null 2>&1; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			return 1
		fi
		sleep 0.2
	done
}

# tcp_open HOST PORT: true when something accepts connections there.
tcp_open() {
	(exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
}

# free_port: a TCP port on 127.0.0.1 that nothing listens on right now.
free_port() {
	local p i
	for i in $(seq 1 50); do
		p=$((20000 + RANDOM % 40000))
		if ! tcp_open 127.0.0.1 "$p"; then
			echo "$p"
			return 0
		fi
	done
	echo "free_port: no free port found" >&2
	return 1
}
