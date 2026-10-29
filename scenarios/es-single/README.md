# es-single

One Elasticsearch 9.5.5 node with authentication on, no node certificates and no published ports, behind Caddy. Caddy terminates TLS and applies an IP allowlist, a path and method allowlist and a body size limit. Applications get a scoped role and an expiring, scoped API key that `elastic` creates at setup.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 6 cores / 12 threads, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5 and Caddy 2.11.7 as pinned in `versions.env`. Result: 83 of 83 rows pass in the explicit heap mode, `results/tests/2026-10-29-es-single.tap`, and 83 of 83 again in the auto-sizing heap mode, `results/tests/2026-10-29-es-single-autoheap.tap` (see "Heap modes (L-M1)"). One laptop run is one data point, not a reference.

The first run the same day passed 78 of 82. Its failures, and what they turned out to be:

- `es-single-07`, `es-single-08` (L-P1): Caddy did abort, but over HTTP/2 curl reports the stream reset as exit 92, which the runner did not count as `abort`. Fixed in the runner.
- `es-single-65` (L-P16): the absolute-form request got the same exit 92; `abort` is now an accepted outcome of the row.
- `es-single-57` (L-P12): the row assumed `create_doc` allows a bulk `index` item. Elasticsearch rejects it with 403. The row was split, see "`create_doc` and the bulk `index` action".

Not tested: the IP allowlist with Docker's userland proxy (see "IP allowlist" below), the ufw variant of L-N1, `compose.bench.yaml` and every benchmark.

## Files

| File | What it is |
|---|---|
| `compose.yaml` | `es01` (1 CPU, 2 GiB, 1 GiB heap) and `caddy` |
| `Caddyfile` | TLS, IP allowlist, path and method allowlist, 20 MB body limit |
| `.env.example` | every variable compose needs; copy it or run `init-env.sh` |
| `init-env.sh` | writes `.env` with random alphanumeric passwords, mode 600 |
| `setup-roles.sh` | index template, test indices, role `app_writer`, user `app_x`, and the app API key, all created as `elastic` |
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

`setup-roles.sh` runs curl inside `es01` against `127.0.0.1:9200`, because the node has no published port and Caddy does not proxy `_security`. Passwords go to that curl on stdin and through a curl config read from a pipe, never on a command line, where `ps` on the host would show them. The script first waits for cluster health and retries 503, 401, 408 and no answer for up to `READY_TIMEOUT` seconds (default 180), printing one line per attempt: right after `compose up --wait` the node is healthy before the `.security-7` primary is assigned, and until then even `elastic` gets 503 `failed to retrieve password hash for reserved user [elastic]` (seen in the first lab run, 2026-10-29, on `es-three-local`).

For benchmarks, `bench/run.sh` adds `compose.bench.yaml`. The bind-mounted data directory must be writable by uid 1000 or gid 0 inside the container; if the host user is not uid 1000, `chgrp 0` the directory and give the group write access.

## Settings and why

| Setting | Why | Source |
|---|---|---|
| `discovery.type=single-node` | one node; also the reason bootstrap checks are not enforced and transport TLS can stay off | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks |
| `xpack.security.enabled=true`, `http.ssl` and `transport.ssl` false | authentication on. TLS is terminated by Caddy; Caddy-to-node traffic stays on the host-local bridge. Setting any `xpack.security.*` turns off security auto-configuration, which is intended | https://www.elastic.co/docs/deploy-manage/security/set-up-minimal-security , https://www.elastic.co/docs/deploy-manage/security/secure-cluster-communications |
| Settings as environment variables by their dotted names | the image accepts the setting name as the variable name | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-configure |
| `ES_JAVA_OPTS=-Xms1g -Xmx1g` | equals what auto-sizing picks for 2 GiB; set so the OpenSearch scenarios, which do not auto-size, run the same heap. Elastic: "The ES_JAVA_OPTS variable overrides all other JVM options. We do not recommend using ES_JAVA_OPTS in production." In production keep the default sizing or use a file in `jvm.options.d/`. `ES_HEAP_OPTS=` (empty) in `.env` restores auto-sizing; L-M1 runs in both modes, see "Heap modes" | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod |
| `bootstrap.memory_lock=true` with `memlock: -1` | one of the documented ways to keep the heap out of swap | same page, "Disable swapping" |
| `nofile 65535` | the documented ulimit for open files | same page |
| `vm.max_map_count=1048576` | host kernel setting, cannot be set per container | same page |
| No `node.processors` | Elastic says processors are detected and that `node.processors` helps under a cgroup quota, but not that the quota is read. Observed on 2026-10-29: with `cpus: 1` the node reports `allocated_processors` 1, write pool 1, search pool 2 (rows `es-single-03`, `es-single-04`), so it does not need to be set here | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/thread-pool-settings |
| Healthcheck greps for `missing authentication credentials` | as in the official compose file; needs no password | https://github.com/elastic/elasticsearch/blob/main/docs/reference/setup/install/docker/docker-compose.yml |
| Role `app_writer`: `read` and `create_doc` on `app-*`, no cluster privileges | `create_doc` allows new documents only and never overwrites: the bulk `create` action and `POST /<index>/_doc` without an id. The bulk `index` action is rejected even without an id, see "`create_doc` and the bulk `index` action". Without `manage_own_api_key` the app user cannot create API keys | https://www.elastic.co/docs/reference/elasticsearch/security-privileges |
| App API key created by `elastic` with `expiration` and `role_descriptors` | see "The application API key" below | https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key |
| Index template `app`: 1 shard, 0 replicas | one node cannot host a replica; with the default of 1 replica every `app-*` index stays yellow | https://www.elastic.co/docs/reference/elasticsearch/index-settings/index-modules |

## Heap modes (L-M1)

L-M1 runs twice, once per mode, with the same `expected.tsv`. The mode is chosen by `ES_HEAP_OPTS` in `.env`, which compose substitutes into `ES_JAVA_OPTS`:

| Mode | `.env` | `ES_JAVA_OPTS` in the container | Rows | Result |
|---|---|---|---|---|
| explicit (default) | no `ES_HEAP_OPTS` line, or the line commented out as in `.env.example` | `-Xms1g -Xmx1g` | `L-M1`: heap max assertion and the recorded `_nodes/jvm` arguments | OBSERVED 2026-10-29: heap max 1073741824 bytes, recorded `input_arguments` contain `-Xms1g` and `-Xmx1g` (rows `es-single-02`, `es-single-78`, body in `results/tests/2026-10-29-es-single/es-single-78.json`) |
| auto-sizing | `ES_HEAP_OPTS=` (empty value) | empty | the same `L-M1` rows | OBSERVED 2026-10-29: heap max 1073741824 bytes as well, and the recorded `input_arguments` contain `-Xms1024m` and `-Xmx1024m`, which Elasticsearch added itself; no `-Xms1g` or `-Xmx1g` (rows `es-single-02`, `es-single-78` in `results/tests/2026-10-29-es-single-autoheap.tap`, body in `results/tests/2026-10-29-es-single-autoheap/es-single-78.json`). Apart from the spelling of those two flags the JVM arguments of the two modes are identical, including `-XX:MaxDirectMemorySize=536870912` |

All other rows run in the explicit mode; they do not depend on the heap mode, and running them again in auto mode is harmless. A variable named `ES_HEAP_OPTS` in the shell that runs `make` or `tests/run-scenario.sh` overrides `.env`, so unset it before the explicit run. `make test` creates the containers and removes them with their volumes afterwards, so each run starts with the heap mode in `.env` at that moment; with `make up`, run `make down` before switching, because `ES_JAVA_OPTS` is read only when the container is created.

```sh
make test SCENARIO=es-single                                  # explicit mode
echo 'ES_HEAP_OPTS=' >> scenarios/es-single/.env              # switch to auto-sizing
make test SCENARIO=es-single                                  # auto mode
sed -i '/^ES_HEAP_OPTS=/d' scenarios/es-single/.env           # back to explicit
```

The auto-mode expectation rests on two sources, neither a measurement: the JVM settings page says "the total memory available to Elasticsearch means the amount of memory available within the container" (https://www.elastic.co/docs/reference/elasticsearch/jvm-settings), and `MachineDependentHeap.java` on the `main` branch gives a data node 50% of available memory at 1 GiB and above, 40% below (https://github.com/elastic/elasticsearch/blob/main/distribution/tools/server-cli/src/main/java/org/elasticsearch/server/cli/MachineDependentHeap.java). The 9.5 branch was not checked; the 2026-10-29 auto run gave 1 GiB in a 2 GiB container, which matches the 50% rule, for this one container size only.

## The application API key

`setup-roles.sh` creates the key as `elastic`, in the same step that creates the role and the user. The exact request:

```json
POST /_security/api_key
{
  "name": "app-x-key",
  "expiration": "30d",
  "role_descriptors": {
    "app_x_key": {
      "indices": [
        {"names": ["app-*"], "privileges": ["read", "create_doc"]}
      ]
    }
  }
}
```

The response's `encoded` field is the value for `Authorization: ApiKey <encoded>`; `setup-roles.sh` prints it as `APP_API_KEY=...` or writes it with `--key-out FILE` (mode 600). The `elastic` password reaches curl inside `es01` on stdin and through a curl config read from a pipe, never through argv, and is used only by this script.

What the create API key page says, and why it shapes the request (https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key):

- "By default, API keys never expire." Hence `expiration`.
- With `role_descriptors` "the resultant permissions are an intersection of API keys permissions and the authenticated user's permissions"; without them the key gets "a point in time snapshot of permissions" of its creator. The creator here is `elastic`, so the `role_descriptors` are the key's only limit. Never send this request without them: the result would be a superuser key.
- The app key has no cluster privileges, so it cannot create keys either (row `L-P4`); even a key that could would get one without privileges: "the derived API key cannot have any privileges".

The trade-off against the app user creating its own key:

- A leaked app password can no longer mint keys. `app_writer` has no cluster privileges, so `POST /_security/api_key` as `app_x` gets 403 (row `L-P4`, node).
- The key is scoped to `read` and `create_doc` on `app-*` and expires after 30 days.
- `elastic` is needed only for setup and rotation. The key's owner is `elastic`, so `GET /_security/api_key` and the invalidate API as `app_x` do not see or touch it; whoever rotates it needs `elastic` or a user with `manage_api_key`.
- The cost: the key's owner is a superuser, so a mistake in `role_descriptors` (an empty object, a typo in the index pattern that widens it) is not caught by a narrower owner role. Rows `L-P3` (node) check that the stored key carries exactly the `app_x_key` descriptor and an expiration, and `L-P4` rows check what the key cannot do.

Rotation: run `setup-roles.sh --key-out FILE` again. It creates a new key with the same name and leaves the role, user and indices as they are. The old key stays valid until it expires; to end it at once, invalidate it as `elastic` by id (from `GET /_security/api_key?name=app-x-key`):

```json
DELETE /_security/api_key
{"ids": ["<old key id>"]}
```

Source: https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-invalidate-api-key ; a user with only `manage_own_api_key` could invalidate only keys it owns, and `app_x` owns none.

## `create_doc` and the bulk `index` action

Observed in the first lab run (2026-10-29, Elasticsearch 9.5.5), with a key or user that has only `read` and `create_doc` on `app-*`. The bulk rows are in `results/tests/2026-10-29-es-single.tap` (`es-single-57`, `es-single-83`); the three direct `_doc` and `_create` requests were made by hand and have no row:

| Request | Result |
|---|---|
| bulk `create` action, no `_id` | 201 |
| `POST /app-a/_doc` without an id (direct to the node; Caddy does not pass `_doc`) | 201 |
| bulk `index` action, no `_id` | 403 for that item inside a 200 bulk response: `action [indices:data/write/index:op_type/index] is unauthorized ... this action is granted by the index privileges [create,index,write,all]` |
| `PUT /app-a/_doc/<id>` (direct to the node) | 403 |
| `_create/<id>` with an id that already exists (direct to the node) | 409 |

Elasticsearch authorizes a bulk item by its operation type, not by whether the id is generated: an `index` item is `op_type/index` even without `_id`, and `create_doc` covers only `op_type/create`. A client whose bulk helper sends `index` actions by default must be configured to send `create`. Granting `index` or `write` instead makes `index` items work but also allows overwriting any existing document by id, which is what `create_doc` exists to prevent. Rows `L-P12` check both bodies: `bodies/bulk-own-create.ndjson` (only `create`, all 201) and `bodies/bulk-own.ndjson` (`create` 201, `index` 403 with `op_type/index` in the reason).

## Caddy, and what it does not do

- **Order.** Everything runs inside one `route`, which keeps the written order. Without it Caddy sorts directives, `handle` and `reverse_proxy` run before `abort`, and a top-level `abort @denied` does not protect the proxied paths. Sources: https://caddyserver.com/docs/caddyfile/directives (directive order), https://caddyserver.com/docs/caddyfile/directives/route .
- **Matching the raw URI.** `path` and `path_regexp` match a decoded, cleaned path (https://caddyserver.com/docs/caddyfile/matchers), but `reverse_proxy` sends the request URI as received. In the proxy-only run, a `path_regexp` version of this file matched `/secret/../app-a/_search`, `/_cluster/settings/../../app-a/_search` and `//app-a/_search` and forwarded them unchanged. The matchers therefore use `expression` on `{http.request.uri}`, the raw path and query, so the checked string is exactly what the node receives. Encoded characters (even `%5F`), dot segments, double slashes, upper case, commas, wildcards, `_all`, date math and `cluster:index` all get 404. Clients that send canonical paths are not affected.
- **Allowed:** `GET|POST /app-<name>/_search`, `GET|POST /app-<name>/_count`, `POST|PUT /app-<name>/_bulk`, with any query string. Everything else gets 404 from Caddy, including `_msearch`, `_async_search`, `_pit`, scroll, `_doc`, `_mapping` and `GET /` (no version banner).
- **The allowlist is a speed bump, not access control.** A `_bulk` body names its own `_index`, so Caddy passes `POST /app-a/_bulk` with `{"create":{"_index":"secret"}}` and only the role stops it (L-P12). Expensive queries (aggregations, `runtime_mappings`, scripts) pass every proxy rule (L-P13).
- **IP allowlist.** `remote_ip` is the immediate TCP peer (https://caddyserver.com/docs/caddyfile/matchers). HYPOTHESIS, not tested by the 2026-10-29 run (its clients sit on separate Docker networks, not on the host): with Docker's userland proxy enabled (the default), connections from the host's own loopback to a published port arrive from the bridge gateway, not from 127.0.0.1, while external connections keep their source address. If the gateway is in `ALLOWED_CIDRS`, every local process is allowed. Do not add Docker ranges to the list without checking what Caddy logs as `remote_ip`.
- **Body size.** `request_body max_size 20MB` gives 413 (https://caddyserver.com/docs/caddyfile/directives/request_body). 20MB is 20,000,000 bytes. The limit applies only to proxied paths; other paths get 404 without reading the body.
- `X-HTTP-Method-Override` is removed before proxying. Elasticsearch is not known to honour it (FROM TRAINING); removing it only keeps the method the matcher checked equal to the method the node sees.
- HTTP/3 is off (`protocols h1 h2`), so Caddy does not advertise a UDP port that compose does not publish.
- Caddy 2.11.1 or later is required (CVE-2026-27587, path matcher bypass with `%xx` patterns, https://github.com/advisories/GHSA-g7pc-pc7g-h8jh). `versions.env` pins 2.11.7.

## What this scenario covers

| Lab test | Rows in `expected.tsv` | Note |
|---|---|---|
| L-M1 heap 1 GiB | `L-M1` | run in both heap modes, see "Heap modes (L-M1)" |
| L-C1 processors and thread pools | `L-C1` | observed 1, write 1, search 2 on 2026-10-29 |
| L-S1 system shards | `L-S1` | recorded, not asserted. 2026-10-29, right after setup: 5 shards, 3 of them system (`.security-7`, ILM history, deprecation log data stream), `results/tests/2026-10-29-es-single/es-single-05.json`. The comparison with Kibana is in `es-single-kibana` |
| L-N1 port 9200 not published | `L-N1` | `127.0.0.1:9200` refused from the host on 2026-10-29 (`es-single-06`). The ufw variant of L-N1 is manual, not in this file, and not yet run |
| L-P1 to L-P10, L-P12 to L-P20 | `L-P*` | `L-P3` and `L-P4` include the API key rows: the app user cannot create a key, the key cannot create one either, the key authenticates as an API key owned by `elastic`, and the stored key has an expiration and only the `app_x_key` descriptor. L-P11 (raw or decoded path upstream) belongs to the proxy-only harness in `tests/`; the run above showed Caddy forwards the raw path |
| L-M2, L-M3, L-W1, L-W2, L-B* | none | `bad-heap`, benchmark runs and the watermark procedure |

Rows with site `node` go straight to `es01:9200` on the compose network, bypassing Caddy, to show which layer stops a request: `GET /_cluster/settings` with the app key gets 404 from Caddy and 403 from the node.

Expectations that were hypotheses before the lab run, and what the run on 2026-10-29 showed (`results/tests/2026-10-29-es-single.tap`):

- `_nodes/os` reports `allocated_processors` 1 under `cpus: 1` (plan 0.1 item 7). OBSERVED, `es-single-03`.
- A bulk `create` into `app-new`, which matches `app-*` but does not exist, gets 403, because `create_doc` does not include index creation (`create_index` or `auto_configure` would). OBSERVED: per-item 403, `es-single-60`.
- `GET /_security/_authenticate` with the app key returns `authentication_type` `api_key`, `api_key.name` `app-x-key` and `username` `elastic` (the owner). OBSERVED, `es-single-81`.
- Creating an API key as `app_x`, or with the app key, gets 403 with `security_exception`. OBSERVED, `es-single-79`, `es-single-80`.
- The absolute-form request `GET http://es01:9200/_cluster/settings` does not reach the node. Caddy may answer 400, 404, 421 or 200, or send no response, as long as no cluster settings come back. The proxy-only run (HTTP/1.1) returned an empty 200 because the host does not match the site. OBSERVED in both lab runs (HTTPS, so HTTP/2): no response at all (curl exit 92, a stream reset), which counts as `abort` (`es-single-65`).

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
| `expect_status` | HTTP status, alternatives joined with `\|`, `abort` (no HTTP response: connection closed, or the HTTP/2 stream reset; see `tests/README.md`) or `refused` (TCP connection refused) |
| `expect` | `-`, `contains:<text>`, `!contains:<text>`, `jq:<expression>` (`jq -e` on the response body), or `record` (keep the body as evidence, assert only the status) |

## Threat model, short

Covers: the node is reachable only through Caddy; only listed client addresses reach Caddy's routes; requests without valid credentials get 401; an app key can read and add documents in `app-*` and nothing else: no overwrite, no delete, no other index, no cluster settings, no security APIs; keys expire.

Does not cover: a leaked app key or password within its own scope (it reads all of `app-*` and adds documents until it expires; the app password alone cannot mint keys); expensive queries; anything running on the host; Kibana users (see `es-single-kibana`); traffic between Caddy and the node, which is plaintext on the Docker bridge.
