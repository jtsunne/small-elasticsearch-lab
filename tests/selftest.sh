#!/usr/bin/env bash
# Checks tests/lib.sh without Docker or an engine: TAP output, assertions,
# variable expansion, result classification, and http_request against the
# echo upstream on 127.0.0.1. Needs go (or ECHO_UPSTREAM), curl and jq.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

work=$(mktemp -d)
echo_pid=
cleanup() {
	local rc=$?
	if [ -n "$echo_pid" ]; then
		kill "$echo_pid" 2>/dev/null || true
		wait "$echo_pid" 2>/dev/null || true
	fi
	rm -rf "$work"
	exit "$rc"
}
trap cleanup EXIT

# Inner TAP runs go to a file so the outer TAP stream stays well formed.
inner=$(
	{
		tap_init
		tap_ok "a"
		tap_not_ok "b" "why"
		tap_skip "c" "reason"
		assert_eq x x "eq"
		assert_match abc '^a.c$' "match"
		echo '{"n": 2}' >"$work/j.json"
		assert_jq "$work/j.json" '.n == 3' "jq"
		tap_finish && echo "finish=0" || echo "finish=1"
	} 2>&1
)
outer() { printf '%s\n' "$inner"; }

tap_init
assert_eq "$(outer | grep -c '^ok ')" 4 "inner run: four ok lines (two passes, one skip, eq, match)"
assert_eq "$(outer | grep -c '^not ok ')" 2 "inner run: two not ok lines"
assert_match "$(outer | grep '^ok 3')" '^ok 3 - c # SKIP reason$' "skip uses the TAP SKIP directive"
assert_match "$(outer)" $'\n1\\.\\.6\n' "trailing plan counts every test"
assert_match "$(outer)" 'finish=1' "tap_finish fails when a test failed"
assert_match "$(outer)" '#   why' "diagnostics are indented comments"

export T5_SAMPLE='ApiKey abc'
assert_eq "$(expand_vars 'Authorization: ${T5_SAMPLE}')" "Authorization: ApiKey abc" "expand_vars substitutes"
# shellcheck disable=SC2016
assert_eq "$(expand_vars '$(id) ${T5_SAMPLE} `id`')" '$(id) ApiKey abc `id`' "expand_vars evaluates nothing else"
if expand_vars '${T5_UNSET_VAR}' 2>/dev/null; then
	tap_not_ok "expand_vars fails on an unset variable"
else
	tap_ok "expand_vars fails on an unset variable"
fi
assert_eq "$(expand_vars 'x ${lower}')" 'x ${lower}' "expand_vars leaves lower-case names alone"

assert_eq "$(http_classify 0 404)" 404 "classify: status"
assert_eq "$(http_classify 52 000)" abort "classify: empty reply is abort"
assert_eq "$(http_classify 55 000)" abort "classify: reset while sending is abort"
assert_eq "$(http_classify 56 000)" abort "classify: reset while reading is abort"
assert_eq "$(http_classify 7 000)" error:curl-7 "classify: connection refused is an error"

echo_bin=${ECHO_UPSTREAM:-}
if [ -z "$echo_bin" ]; then
	echo_bin=$work/echo-upstream
	(cd "$here/echo-upstream" && go build -trimpath -o "$echo_bin" .)
fi
"$echo_bin" -addr-file "$work/addr" -log "$work/up.jsonl" 2>"$work/up.err" &
echo_pid=$!
if wait_for 10 test -s "$work/addr"; then
	tap_ok "echo upstream started"
else
	tap_not_ok "echo upstream started" "$(cat "$work/up.err")"
fi
addr=$(cat "$work/addr")
url=http://$addr

HTTP_OUT_DIR=$work/r1
mkdir -p "$HTTP_OUT_DIR"
http_request -t '/app-a/../_cluster/%5Fsettings' -s 127.0.0.2 -H 'X-T: 1' "$url"
assert_eq "$HTTP_RESULT" 200 "http_request: status"
assert_eq "$(http_header x-echo-upstream)" 1 "http_header is case-insensitive"
assert_jq "$HTTP_BODY_FILE" '.request_uri == "/app-a/../_cluster/%5Fsettings"' "request-target is sent verbatim"
assert_jq "$HTTP_BODY_FILE" '.remote_addr | startswith("127.0.0.2:")' "client binds to the requested source address"
assert_jq "$HTTP_BODY_FILE" '.headers["X-T"] == ["1"] and (.headers.Expect == null)' "extra header sent, Expect dropped"

printf 'abcdef' >"$work/body"
HTTP_OUT_DIR=$work/r2
mkdir -p "$HTTP_OUT_DIR"
http_request -X PUT -b "$work/body" -1 -H 'User-Agent:' "$url/x"
assert_jq "$HTTP_BODY_FILE" '.method == "PUT" and .body_bytes == 6 and .proto == "HTTP/1.0"' "method, body and HTTP/1.0"
assert_jq "$HTTP_BODY_FILE" '.headers["User-Agent"] == null' "'Name:' removes a header"

HTTP_OUT_DIR=$work/r3
mkdir -p "$HTTP_OUT_DIR"
http_request -X HEAD "$url/"
assert_eq "$HTTP_RESULT" 200 "HEAD returns without waiting for a body"
assert_eq "$(wc -c <"$HTTP_BODY_FILE" | tr -d ' ')" 0 "HEAD leaves the body file empty"

port=$(free_port)
HTTP_OUT_DIR=$work/r4
mkdir -p "$HTTP_OUT_DIR"
http_request "http://127.0.0.1:$port/"
assert_eq "$HTTP_RESULT" error:curl-7 "free_port returned a port nothing listens on"

tap_finish
