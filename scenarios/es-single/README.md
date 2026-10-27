# es-single

One Elasticsearch 9.5.5 node with authentication on, no node certificates and no published ports, behind Caddy. Caddy terminates TLS and applies an IP allowlist, a path and method allowlist and a body size limit. Applications get a scoped role and an expiring, scoped API key.

**Tested on: NOT YET TESTED.** The files pass static checks only: `docker compose config`, `caddy validate`, `bash -n`, a proxy-only run of the Caddyfile against an echo upstream, and `setup-roles.sh` against a fake node. Nothing here has run against a real Elasticsearch yet. Every expectation in `expected.tsv` was written before the lab run and may be wrong.

## Files

| File | What it is |
|---|---|
| `compose.yaml` | `es01` (1 CPU, 2 GiB, 1 GiB heap) and `caddy` |
| `Caddyfile` | TLS, IP allowlist, path and method allowlist, 20 MB body limit |
| `.env.example` | every variable compose needs; copy it or run `init-env.sh` |
| `init-env.sh` | writes `.env` with random alphanumeric passwords, mode 600 |
| `setup-roles.sh` | index template, test indices, role `app_writer`, user `app_x`, API key |
| `expected.tsv` | the checks the lab runner executes, format below |
| `bodies/` | request bodies referenced from `expected.tsv` |
| `compose.bench.yaml` | benchmark override: node on `127.0.0.1:9200`, data under `$BENCH_DATA_DIR`, no Caddy |

## Run

Host prerequisite, once. Elasticsearch requires it in production mode; with `discovery.type=single-node` it is not enforced, but set it anyway:

```sh
sudo sysctl -w vm.max_map_count=1048576
```

```sh
scenarios/es-single/init-env.sh
make up SCENARIO=es-single
scenarios/es-single/setup-roles.sh --key-out /tmp/app-key.env
make test SCENARIO=es-single
make down SCENARIO=es-single        # deletes the volumes
```

Caddy serves `https://es.localhost:8443` with its internal CA. For curl, copy the root out with `docker compose -p es-single cp caddy:/data/caddy/pki/authorities/local/root.crt /tmp/caddy-root.crt` and pass `--cacert /tmp/caddy-root.crt`. On a real host set `CADDY_BIND=0.0.0.0`, ports 80 and 443 and a public DNS name in `ES_SITE_ADDRESS`, and Caddy obtains a public certificate.

`setup-roles.sh` runs curl inside `es01` against `127.0.0.1:9200`, because the node has no published port and Caddy does not proxy `_security`. Passwords go to that curl on stdin and through a curl config read from a pipe, never on a command line, where `ps` on the host would show them.

For benchmarks, `bench/run.sh` adds `compose.bench.yaml`. The bind-mounted data directory must be writable by uid 1000 or gid 0 inside the container; if the host user is not uid 1000, `chgrp 0` the directory and give the group write access.

## Settings and why

| Setting | Why | Source |
|---|---|---|
| `discovery.type=single-node` | one node; also the reason bootstrap checks are not enforced and transport TLS can stay off | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks |
| `xpack.security.enabled=true`, `http.ssl` and `transport.ssl` false | authentication on. TLS is terminated by Caddy; Caddy-to-node traffic stays on the host-local bridge. Setting any `xpack.security.*` turns off security auto-configuration, which is intended | https://www.elastic.co/docs/deploy-manage/security/set-up-minimal-security , https://www.elastic.co/docs/deploy-manage/security/secure-cluster-communications |
| Settings as environment variables by their dotted names | the image accepts the setting name as the variable name | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-configure |
| `ES_JAVA_OPTS=-Xms1g -Xmx1g` | equals what auto-sizing picks for 2 GiB; set so the OpenSearch scenarios, which do not auto-size, run the same heap. Elastic: "The ES_JAVA_OPTS variable overrides all other JVM options. We do not recommend using ES_JAVA_OPTS in production." In production keep the default sizing or use a file in `jvm.options.d/`. `ES_HEAP_OPTS=` (empty) in `.env` restores auto-sizing for L-M1 | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod |
| `bootstrap.memory_lock=true` with `memlock: -1` | one of the documented ways to keep the heap out of swap | same page, "Disable swapping" |
| `nofile 65535` | the documented ulimit for open files | same page |
| `vm.max_map_count=1048576` | host kernel setting, cannot be set per container | same page |
| No `node.processors` | Elastic says processors are detected and that `node.processors` helps under a cgroup quota, but not that the quota is read; L-C1 decides whether it must be set | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/thread-pool-settings |
| Healthcheck greps for `missing authentication credentials` | as in the official compose file; needs no password | https://github.com/elastic/elasticsearch/blob/main/docs/reference/setup/install/docker/docker-compose.yml |
| Role `app_writer`: `read` and `create_doc` on `app-*`, cluster `manage_own_api_key` | `create_doc` allows new documents only (bulk `create`, or `index` with an auto-generated id) and never overwrites; `manage_own_api_key` is the minimum for creating an API key | https://www.elastic.co/docs/reference/elasticsearch/security-privileges , https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key |
| API key with `expiration` and `role_descriptors` | keys never expire by default; a key's privileges are the intersection of its `role_descriptors` and its owner's privileges. A key created by `elastic` without `role_descriptors` is a superuser key, so the app user creates its own | create API key page above |
| Index template `app`: 1 shard, 0 replicas | one node cannot host a replica; with the default of 1 replica every `app-*` index stays yellow | https://www.elastic.co/docs/reference/elasticsearch/index-settings/index-modules |

## Caddy, and what it does not do

- **Order.** Everything runs inside one `route`, which keeps the written order. Without it Caddy sorts directives, `handle` and `reverse_proxy` run before `abort`, and a top-level `abort @denied` does not protect the proxied paths. Sources: https://caddyserver.com/docs/caddyfile/directives (directive order), https://caddyserver.com/docs/caddyfile/directives/route .
- **Matching the raw URI.** `path` and `path_regexp` match a decoded, cleaned path (https://caddyserver.com/docs/caddyfile/matchers), but `reverse_proxy` sends the request URI as received. In the proxy-only run, a `path_regexp` version of this file matched `/secret/../app-a/_search`, `/_cluster/settings/../../app-a/_search` and `//app-a/_search` and forwarded them unchanged. The matchers therefore use `expression` on `{http.request.uri}`, the raw path and query, so the checked string is exactly what the node receives. Encoded characters (even `%5F`), dot segments, double slashes, upper case, commas, wildcards, `_all`, date math and `cluster:index` all get 404. Clients that send canonical paths are not affected.
- **Allowed:** `GET|POST /app-<name>/_search`, `GET|POST /app-<name>/_count`, `POST|PUT /app-<name>/_bulk`, with any query string. Everything else gets 404 from Caddy, including `_msearch`, `_async_search`, `_pit`, scroll, `_doc`, `_mapping` and `GET /` (no version banner).
- **The allowlist is a speed bump, not access control.** A `_bulk` body names its own `_index`, so Caddy passes `POST /app-a/_bulk` with `{"create":{"_index":"secret"}}` and only the role stops it (L-P12). Expensive queries (aggregations, `runtime_mappings`, scripts) pass every proxy rule (L-P13).
- **IP allowlist.** `remote_ip` is the immediate TCP peer (https://caddyserver.com/docs/caddyfile/matchers). HYPOTHESIS, to confirm in the lab: with Docker's userland proxy enabled (the default), connections from the host's own loopback to a published port arrive from the bridge gateway, not from 127.0.0.1, while external connections keep their source address. If the gateway is in `ALLOWED_CIDRS`, every local process is allowed. Do not add Docker ranges to the list without checking what Caddy logs as `remote_ip`.
- **Body size.** `request_body max_size 20MB` gives 413 (https://caddyserver.com/docs/caddyfile/directives/request_body). 20MB is 20,000,000 bytes. The limit applies only to proxied paths; other paths get 404 without reading the body.
- `X-HTTP-Method-Override` is removed before proxying. Elasticsearch is not known to honour it (FROM TRAINING); removing it only keeps the method the matcher checked equal to the method the node sees.
- HTTP/3 is off (`protocols h1 h2`), so Caddy does not advertise a UDP port that compose does not publish.
- Caddy 2.11.1 or later is required (CVE-2026-27587, path matcher bypass with `%xx` patterns, https://github.com/advisories/GHSA-g7pc-pc7g-h8jh). `versions.env` pins 2.11.7.

## What this scenario covers

| Lab test | Rows in `expected.tsv` | Note |
|---|---|---|
| L-M1 heap 1 GiB | `L-M1` | as configured this checks the explicit heap; run once with `ES_HEAP_OPTS=` to check auto-sizing |
| L-C1 processors and thread pools | `L-C1` | expected 1, write 1, search 2; if it fails, set `node.processors=1` and record it |
| L-S1 system shards | `L-S1` | recorded, not asserted |
| L-N1 port 9200 not published | `L-N1` | the ufw variant of L-N1 is manual and not in this file |
| L-P1 to L-P10, L-P12 to L-P20 | `L-P*` | L-P11 (raw or decoded path upstream) belongs to the proxy-only harness in `tests/`; the run above showed Caddy forwards the raw path |
| L-M2, L-M3, L-W1, L-W2, L-B* | none | `bad-heap`, benchmark runs and the watermark procedure |

Rows with site `node` go straight to `es01:9200` on the compose network, bypassing Caddy, to show which layer stops a request: `GET /_cluster/settings` with the app key gets 404 from Caddy and 403 from the node.

Expectations that are hypotheses, not documented behaviour:

- `_nodes/os` reports `allocated_processors` 1 under `cpus: 1` (plan 0.1 item 7).
- A bulk `create` into `app-new`, which matches `app-*` but does not exist, gets 403, because `create_doc` does not include index creation (`create_index` or `auto_configure` would).
- The absolute-form request `GET http://es01:9200/_cluster/settings` does not reach the node. Caddy may answer 400, 404, 421 or 200, as long as no cluster settings come back; the proxy-only run returned an empty 200 because the host does not match the site.

## expected.tsv format

Tab-separated, one header line, one check per line, no empty fields (`-` means none). The runner in `tests/` owns the final contract; these files are written in this format.

| Column | Values |
|---|---|
| `id` | unique, `<scenario>-NN` |
| `test` | lab test id from the plan (`L-P4`), or `health` |
| `site` | `es` (through Caddy, ES site address), `kibana` (through Caddy, Kibana site address), `node` (direct to `es01:9200` inside the compose network), `host` (`path` is a full URL opened from the host) |
| `from` | `allowed` or `denied`: a client whose address is inside or outside `ALLOWED_CIDRS`; `-` for `node` and `host` |
| `auth` | `none`, `elastic` (password from `.env`), `app_user` (`app_x` with `APP_PASSWORD`), `app_key` (`APP_API_KEY` from `setup-roles.sh --key-out`), `bad_key` (well-formed but unknown key) |
| `method` | HTTP method |
| `path` | sent verbatim (`curl --path-as-is`, percent-encoding untouched); a value starting with `http://` is sent as an absolute-form request target |
| `headers` | `-` or one `Name: value` header |
| `body` | `-`, `@<file>` relative to the scenario directory, `inline:<text>`, or `bytes:<n>` (n zero bytes) |
| `expect_status` | HTTP status, alternatives joined with `\|`, `abort` (connection closed without a response) or `refused` (TCP connection refused) |
| `expect` | `-`, `contains:<text>`, `!contains:<text>`, `jq:<expression>` (`jq -e` on the response body), or `record` (keep the body as evidence, assert only the status) |

## Threat model, short

Covers: the node is reachable only through Caddy; only listed client addresses reach Caddy's routes; requests without valid credentials get 401; an app key can read and add documents in `app-*` and nothing else: no overwrite, no delete, no other index, no cluster settings, no security APIs; keys expire.

Does not cover: a leaked app key or password within its own scope (it reads all of `app-*` and adds documents until it expires, and the app user can mint new keys of the same scope); expensive queries; anything running on the host; Kibana users (see `es-single-kibana`); traffic between Caddy and the node, which is plaintext on the Docker bridge.
