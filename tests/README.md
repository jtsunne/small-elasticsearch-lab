# tests

Scenario and proxy test harness. Everything prints TAP (version 13, plan at the end) and exits non-zero when a test fails.

| File | What it is |
|---|---|
| `lib.sh` | TAP output, assertions, a curl wrapper that sends the request-target verbatim, `${VAR}` expansion without eval |
| `selftest.sh` | Checks `lib.sh` against the echo upstream; no Docker |
| `echo-upstream/` | Go stdlib HTTP server: answers 200 with a JSON record of the raw request-target, decoded path, method, headers and body length, and logs the same record |
| `proxy-matrix.tsv` | The proxy bypass matrix (plan 5.4, L-P1 to L-P20) for Elasticsearch and OpenSearch paths |
| `run-proxy-matrix.sh` | Runs the matrix against a Caddyfile with a local Caddy and the echo upstream (no Docker), or against a running scenario (`--lab`) |
| `run-scenario.sh` | `up --wait`, setup, a scenario's `expected.tsv`, `down -v` |
| `fixtures/` | Caddyfiles that pin known behaviour, request bodies for the matrix |

## Proxy-only mode

```sh
GOBIN=$PWD/bin go install github.com/caddyserver/caddy/v2/cmd/caddy@v2.11.7
CADDY=$PWD/bin/caddy tests/run-proxy-matrix.sh tests/fixtures/Caddyfile.fixed
CADDY=$PWD/bin/caddy tests/run-proxy-matrix.sh scenarios/es-single/Caddyfile
CADDY=$PWD/bin/caddy tests/run-proxy-matrix.sh --engine os --env-file scenarios/os-single/.env.example scenarios/os-single/Caddyfile
```

The runner adapts the Caddyfile to JSON and changes values, never structure: every `reverse_proxy` dials the echo upstream (upstream TLS settings are dropped, so the Caddy-to-node TLS hop is not tested here), every `remote_ip` and `client_ip` range becomes `127.0.0.2/32`, each server listens on `127.0.0.1` on a free high port with automatic HTTPS off, and the admin endpoint is disabled. The allowed client sends from `127.0.0.2`, the denied client from `127.0.0.3`. The `Host` header is the tested server's only site host, or, with several, the only one starting with `<engine>.` (`es.`, `os.`); `127.0.0.1` when it has none. Any other case stops with exit 2 and the list of hosts instead of guessing; pass `--host NAME` then. On Linux the whole of `127.0.0.0/8` is local, so no interface setup is needed. Loopback aliases were chosen over `X-Forwarded-For` with `trusted_proxies` because that would test a different matcher (`client_ip`) than the one the scenarios use.

A response carrying the echo upstream's `X-Echo-Upstream` header counts as `upstream`. Each request carries an `X-Matrix-Id` header, so the upstream log shows whether a request arrived even when the client got something else. Backend expectations are not checked in this mode; the summary says how many were left for the lab. All processes are killed on exit; the work directory is kept and printed when a test fails.

`--lab URL` sends the same rows to a running scenario's Caddy and checks the backend column. `APP_AUTH` must hold the `Authorization` value of the app credential. Denied-client rows need `--denied-from IP` (a local address the allowlist does not contain) and are skipped without it.

## `proxy-matrix.tsv` format

Tab-separated, 13 columns, one header line, `#` lines are comments, `-` means empty (no cell may be blank).

| Column | Meaning |
|---|---|
| `id` | Unique row id, sent as `X-Matrix-Id` |
| `lab` | Plan test id (`L-P1` ...) |
| `engine` | `es`, `os` or `any`; `--engine` selects the rows |
| `client` | `allowed` or `denied` |
| `method` | Request method |
| `target` | Request-target, sent verbatim (no dot-segment removal, no re-encoding; absolute form allowed). `{HOST}` becomes the site host |
| `headers` | `Name: value` items separated by `\|`; `${VAR}` is expanded from the environment; `Name:` removes a header curl would add; the item `HTTP/1.0` switches the protocol version |
| `body` | `-`, a file under `fixtures/bodies/`, or `fill:N` (N bytes of `x`) |
| `proxy` | What the client gets from the proxy: `upstream`, `abort`, a status Caddy generates itself (`404`, `413`), `!upstream` (anything that is not an upstream answer); alternatives with `\|` |
| `upstream` | Checks on what the upstream received, `;`-separated: `target=` (raw request-target, `@sent` for the sent one), `method=`, `proto=`, `body_bytes=`, `body_error=`, `header:Name=`. On a row whose `proxy` is not `upstream`, checks here mean the upstream is expected to see part of the request (a body cut off at the size limit); `-` there means it must see nothing |
| `backend` | Lab mode only: the engine's answer, `NNN`, `4xx`, or `bulk-item-403` (200 with every bulk item 403) |
| `layer` | Which layer stops the request: `caddy`, `engine`, `none` (passes every layer, documented as not covered) |
| `note` | Free text, printed on failure |

## Fixtures

| File | Expected result in proxy-only mode |
|---|---|
| `fixtures/Caddyfile.broken` | Fails. Top-level `abort @denied` next to `handle` blocks: Caddy sorts `handle` before `abort`, so a non-allowlisted client reaches `/app-a/_search` and `/app-a/_bulk` (P01a to P01c, P16e) and gets 404 instead of an abort on other paths |
| `fixtures/Caddyfile.plan` | Fails 8 rows. The plan's corrected Caddyfile, verbatim: the allowlist works, but `path_regexp` sees the decoded, cleaned path while `reverse_proxy` forwards the raw one, so `/_security/../app-a/_search`, `//app-a/_search`, `/app-a%2F_search` and encoded variants reach the upstream as written (P07e/f/k/l/m/n, P11a/b) |
| `fixtures/Caddyfile.fixed` | Passes. The plan's handle nesting with the route matchers on the raw URI (`{http.request.uri}` in an `expression` matcher) |

Observed with Caddy 2.11.7 in proxy-only mode, not yet in the lab: an `abort` closes the connection without a response (curl exit 52, 55 or 56); `reverse_proxy` forwards the raw request-target, percent-encoding and dot segments included; an absolute-form request is forwarded in origin form; an HTTP/1.0 client is forwarded as HTTP/1.1. Over the 20 MB `request_body` limit the client gets 413, but Caddy has already streamed the first 20000000 bytes to the upstream, which then sees the request end early (`unexpected EOF`). Whether Elasticsearch and OpenSearch discard such a truncated request is a lab question.

## `expected.tsv` format (scenarios)

Tab-separated, one header line, `#` lines are comments, `-` means none. Columns are found by header name, so their order is free; rows run top to bottom (setup rows first).

| Column | Values |
|---|---|
| `id` | Unique within the file |
| `test` | Plan test id, or `setup`, `health`. Also accepted as `lab` or `lab_test` |
| `site` | `node` (curl inside the node container against `127.0.0.1:9200`; HTTP or HTTPS is probed once, the certificate is not verified), `host` (curl on the host; `path` is a full URL), or a proxy site name such as `es`, `os`, `kibana`, whose address is `<SITE>_SITE_ADDRESS` from `.env` |
| `from` | `allowed` or `denied` for proxy sites, `-` otherwise. Also accepted as `client` |
| `auth` | `none`; `elastic` (`ELASTIC_PASSWORD`); `admin` (`ADMIN_PASSWORD`); `app_user` (user `APP_USER` from the environment or `.env`, default `app_x`; `APP_PASSWORD`); `app_key` (`ApiKey` with `APP_API_KEY`); `bad_key` (a well-formed invalid API key); `demo_<user>` (password equal to the user name); generic forms `user/VAR` (password from `VAR`), `user=password`, `apikey/VAR` |
| `method` | Request method |
| `path` | Request-target, sent verbatim |
| `headers` | `Name: value` items separated by `\|` |
| `body` | `-`, a file relative to the scenario (`@bodies/x.json` or `bodies/x.json`), `bytes:N` or `zeros:N` (N bytes), `inline:TEXT` |
| `expect_status` | A status, `abort` (connection closed without a response), `refused` (connection refused); alternatives with `\|` |
| `expect` | `-`, `jq:EXPR` (`jq -e` on the body), `contains:TEXT`, `!contains:TEXT`, `record` (body saved next to the TAP file). A column named `expect_jq` holding a bare jq expression is accepted instead |
| `note` | Optional free text |

Variables come from the environment first, then the scenario's `.env`, then `KEY=VALUE` lines printed by `setup-roles.sh`.

## `run-scenario.sh`

```sh
make test SCENARIO=es-single
tests/run-scenario.sh --plan-only os-single   # parse and show each row, no Docker
```

It refuses when the Docker daemon is unreachable, then:

1. runs `init-env.sh` if `.env` is missing, `certs/gen-certs.sh` if `certs/` has no `.pem`, `init-security.sh` if present;
2. exports every variable in `TEST_ALLOWLIST_VARS` (default `ALLOWED_CIDRS ALLOW_CIDRS`) as `TEST_ALLOWED_SUBNET` (default `10.231.1.0/24`) and runs `docker compose up -d --wait`;
3. creates two networks, `<project>-test-allowed` and `<project>-test-denied` (`TEST_DENIED_SUBNET`, default `10.231.2.0/24`), and connects the `caddy` service to both;
4. runs `setup-roles.sh` if present and keeps the `KEY=VALUE` lines it prints;
5. runs the rows; proxy-site rows come from a throwaway container on the allowed or denied network (the node image, which has curl and bash), with the site name resolved to Caddy's address on that network;
6. removes the networks and runs `down -v`, unless `--keep-up`.

Client containers are used instead of host requests because Caddy's `remote_ip` sees the immediate TCP peer: through Docker's userland proxy a request from the host arrives from the bridge gateway, so a denied client on the host is not possible. Credentials reach curl as a config on stdin, never through argv. The TAP output is also written to `results/tests/<date>-<scenario>.tap`, recorded bodies to `results/tests/<date>-<scenario>/`.

Status: `run-scenario.sh` and `--lab` mode have not run against Docker or an engine yet. Proxy-only mode, `selftest.sh`, `--plan-only` on every `expected.tsv` and the echo upstream tests have run.
