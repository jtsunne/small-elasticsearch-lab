# os-single

One OpenSearch 3.9.0 node with the security plugin on, the demo configuration off, its own CA, node and admin certificates generated with openssl, HTTPS on the node, and Caddy in front with an IP allowlist, a path and method allowlist and a body size limit. It is the OpenSearch counterpart of `es-single` and the scenario behind the "OpenSearch differences" block of the guide's security page.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 12 logical CPUs, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with OpenSearch 3.9.0 and Caddy 2.11.7 as pinned in `versions.env`. Result: 62 of 62 rows pass, `results/tests/2026-10-29-os-single.tap`.

The first run the same day passed 48 of 62. Its failures, and what they turned out to be:

- `os-single-01`, `-02`, `-12`, `-13`, `-15`, `-44`, `-45` (setup, L-O3, L-P12, L-P13): the body rows sent no `Content-Type`, curl labelled them `application/x-www-form-urlencoded`, and OpenSearch answered 406. The rows now name the type, and the runner refuses a body row without one.
- `os-single-20`, `-21`, `-47`, `-48`, `-58` (L-P3, L-P15): 404 `index_not_found_exception` for `app-a`, a cascade of the failed index creation in row 01.
- `os-single-17`, `-18` (L-P1): Caddy did abort, but over HTTP/2 curl reports the stream reset as exit 92, which the runner did not count as `abort`. Fixed in the runner.

Not tested: L-O1 (no transport certificates, a separate variant), `init-security.sh --apply` (`securityadmin.sh`), `compose.bench.yaml` and every benchmark, and an `app_writer` without `indices:data/write/index` (a create-only role like the Elasticsearch scenarios' `create_doc`).

## How this differs from es-single

Be clear about this before copying anything: OpenSearch is not Elasticsearch with a different image name.

- **Certificates on day one, even for one node.** "TLS is optional for the REST layer and mandatory for the transport layer" ([TLS settings](https://docs.opensearch.org/latest/security/configuration/tls/)). Elasticsearch lets a single node run with security on and no certificates; OpenSearch documents no such exception. `es-single` has no certificates; this scenario cannot work without `certs/gen-certs.sh`. Whether the plugin refuses to start without transport certificates on `discovery.type: single-node` is lab test L-O1, not yet run (the 2026-10-29 run used certificates).
- **HTTPS on the node, too.** `securityadmin.sh` "requires SSL/TLS HTTP to be enabled for your OpenSearch cluster" ([securityadmin](https://docs.opensearch.org/latest/security/configuration/security-admin/)). So the node serves HTTPS and Caddy connects to it over HTTPS, verifying the lab CA. This deviates from the plan's "HTTP TLS off on the node", which `securityadmin.sh` rules out. The certificate exists anyway for transport, so HTTPS costs nothing extra to set up.
- **The demo configuration is off and must stay off.** The image entrypoint runs `install_demo_configuration.sh` unless `DISABLE_INSTALL_DEMO_CONFIG=true` ([entrypoint](https://github.com/opensearch-project/opensearch-build/blob/main/docker/release/config/opensearch/opensearch-docker-entrypoint-default.x.sh)). The demo certificates and keys are public.
- **The image's own users are demo users.** The security plugin's default `internal_users.yml` contains `admin`, `kibanaserver`, `readall`, `logstash`, `snapshotrestore` and others with publicly known bcrypt hashes ([3.9.0.0 config](https://github.com/opensearch-project/security/blob/3.9.0.0/config/internal_users.yml)). Disabling the demo installer does not remove them. This scenario mounts its own `internal_users.yml`, `roles.yml` and `roles_mapping.yml` over the image files; `expected.tsv` checks that the demo passwords no longer work.
- **`OPENSEARCH_INITIAL_ADMIN_PASSWORD` does nothing here.** Only the demo installer reads it, and this scenario disables the installer (same entrypoint). Its strength rules (8 to 100 characters, upper, lower, digit, special, a zxcvbn "strong" score; [demo configuration](https://docs.opensearch.org/latest/security/configuration/demo-configuration/)) are not applied to passwords in `internal_users.yml`, and nothing on the node checks them. `init-security.sh` requires at least 16 characters and refuses the `.env.example` values; choose long random passwords.
- **The heap is not sized from the container.** OpenSearch "defaults to -Xms1g -Xmx1g", and that "takes precedence over" container-aware sizing ([install, important settings](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/index/)). Elasticsearch sizes the heap from `mem_limit`. `compose.yaml` sets `OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g` explicitly so that the 2 GiB container gets the same 1 GiB heap as `es-single`. Change `mem_limit` and you must change this too.
- **No API keys.** The application authenticates as an internal user (`app_x`) mapped to a scoped role (`app_writer`). An API token feature for OpenSearch 3.x was not evaluated for this scenario.
- **`vm.max_map_count`**: the OpenSearch docs ask for at least 262144 ([docker](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/docker/)); the Elasticsearch docs now say 1048576. A host set up for the Elasticsearch scenarios satisfies both.

## Files

| File | What it is |
|---|---|
| `compose.yaml` | `os01` (1 CPU, 2 GiB, 1 GiB heap, no published ports) and `caddy` (published on `CADDY_BIND` with `CADDY_HTTP_PORT` / `CADDY_HTTPS_PORT`, loopback by default) |
| `opensearch.yml` | Node and security plugin settings, mounted over the image file |
| `certs/gen-certs.sh` | Root CA, `os01` node certificate (SAN `os01`, `localhost`, `127.0.0.1`; server and client auth), `admin` client certificate; checks the DNs against `opensearch.yml`. Outputs are git-ignored |
| `internal_users.yml.example` | Template with `admin` and `app_x`; `init-security.sh` renders it to `security/internal_users.yml` (git-ignored) |
| `roles.yml`, `roles_mapping.yml` | `app_writer` (search and append in `app-*`, nothing else) and the mappings; they replace the image files and their demo mappings |
| `init-security.sh` | Renders the users file with bcrypt hashes from `hash.sh`; `--apply` loads changes with `securityadmin.sh` |
| `Caddyfile` | The allowlisted proxy, see below |
| `.env.example` | Passwords, site address, allowlist, bind addresses |
| `init-env.sh` | Writes `.env` from `.env.example` with random 32-character passwords, mode 600; refuses to overwrite an existing `.env` |
| `expected.tsv` | Checks for the lab runner, format below |
| `bodies/` | Request bodies used by `expected.tsv` |
| `compose.bench.yaml` | Benchmark override for `bench/run.sh` |

## Run

Requirements as in the top-level README: Linux, cgroup v2, Docker Engine with the Compose v2 plugin, `vm.max_map_count` of at least 262144.

```sh
cd scenarios/os-single
./init-env.sh                 # or cp .env.example .env; then set OS_SITE_ADDRESS, ALLOWED_CIDRS
certs/gen-certs.sh            # once; --force regenerates everything including the CA
./init-security.sh            # renders security/internal_users.yml, needs Docker for hash.sh
cd ../.. && make up SCENARIO=os-single
```

The container runs as uid 1000 and reads the keys and the rendered users file through bind mounts with mode 0600. Both scripts print a `chown` hint when you are not uid 1000.

On the first start the plugin creates its security index from the mounted files, because `plugins.security.allow_default_init_securityindex: true` (the docs' own custom-configuration example sets it; [docker](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/docker/)). After that the files are not read again: "If you make changes to the configuration files in `config/opensearch-security`, OpenSearch does not automatically apply these changes" ([securityadmin](https://docs.opensearch.org/latest/security/configuration/security-admin/)). To change a password or a role later:

```sh
scenarios/os-single/init-security.sh          # after editing .env, re-render the users file
scenarios/os-single/init-security.sh --apply  # securityadmin.sh -f ... -t internalusers|roles|rolesmapping
```

`--apply` overwrites users, roles and mappings created through the REST API or Dashboards. It loads one type at a time with `-f`/`-t`, so the image's `config.yml`, action groups and tenants in the index are not touched. `hash.sh -env VAR` reads the password from the environment so it never appears in a process list (option in [Hasher.java at 3.9.0.0](https://github.com/opensearch-project/security/blob/3.9.0.0/src/main/java/org/opensearch/security/tools/Hasher.java)).

Stop and delete the data: `make down SCENARIO=os-single`. The volume holds the security index, so after `down -v` the next start initializes it again from the files.

## Settings that are not obvious

| Setting | Why | Source |
|---|---|---|
| `DISABLE_INSTALL_DEMO_CONFIG=true` | Without it the entrypoint installs the demo certificates and users | [docker](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/docker/), entrypoint above |
| `DISABLE_PERFORMANCE_ANALYZER_AGENT_CLI=true` | The entrypoint otherwise starts the Performance Analyzer agent, a second JVM in the same 2 GiB limit | entrypoint above |
| `OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g` | No container-aware heap sizing | [install](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/index/) |
| `bootstrap.memory_lock: true` with `memlock` unlimited, `nofile` 65536 | As the official compose example | [docker](https://docs.opensearch.org/latest/install-and-configure/install-opensearch/docker/) |
| `plugins.security.ssl.http.enabled=true` in `compose.yaml` | Required by `securityadmin.sh`; set as an environment variable (the entrypoint turns `a.b=c` variables into `-Ea.b=c`) so that `compose.bench.yaml` can override it | [securityadmin](https://docs.opensearch.org/latest/security/configuration/security-admin/), entrypoint above |
| PKCS#8 keys | The plugin reads PKCS#8 only | [TLS settings](https://docs.opensearch.org/latest/security/configuration/tls/) |
| Node certificate with `serverAuth, clientAuth` | Transport TLS certificates act as client and server | [TLS settings](https://docs.opensearch.org/latest/security/configuration/tls/) |
| `plugins.security.nodes_dn`, `plugins.security.authcz.admin_dn` | RFC 2253 order, no spaces, no wildcards for `admin_dn`; `gen-certs.sh` fails if the DNs drift | [TLS settings](https://docs.opensearch.org/latest/security/configuration/tls/), [generate certificates](https://docs.opensearch.org/latest/security/configuration/generate-certificates/) |
| Transport hostname verification left at its default (on) | The SAN covers `os01`. On one node there is no node-to-node traffic, so this only matters when the cluster grows | [TLS settings](https://docs.opensearch.org/latest/security/configuration/tls/) |
| `app_writer`: cluster `indices:data/write/bulk`; on `app-*` index `read`, `indices:data/write/index`, `indices:data/write/bulk*`, `indices:admin/mapping/put` | Not the `write` or `crud` groups, which include update and delete; no `indices:admin/create` | [default action groups](https://docs.opensearch.org/latest/security/access-control/default-action-groups/), [permissions](https://docs.opensearch.org/latest/security/access-control/permissions/) |

## Caddy

Same structure as `es-single`: one `route` block, which keeps the written order, so the `abort` for peers outside `ALLOWED_CIDRS` runs first. Without `route` Caddy sorts `reverse_proxy` and `handle` before `abort` whatever the order in the file, and a top-level `abort @denied` does not protect the proxied paths. After the allowlist only `GET|POST /app-*/_search|_count` and `POST|PUT /app-*/_bulk` reach the node; everything else gets 404 from Caddy, including `/`, `_cluster`, `_cat`, `_nodes`, `_plugins/_security`, the legacy `_opendistro/_security` paths, `_plugins/_sql` and point in time.

The route matchers are `expression` matchers on `{http.request.uri}`, the raw request-target, not `path_regexp`. `path` and `path_regexp` match a decoded, dot-cleaned path, while `reverse_proxy` forwards the raw one: with `path_regexp`, `/_plugins/_security/../app-a/_search`, `//app-a/_search` or `/app-a%2F_search` match the app route and reach the node exactly as written. The proxy-only matrix in `tests/` showed this with Caddy 2.11.7 (rows P07e/f/k/l/m/n and P11a/b). With raw-URI matching, any encoding, dot segment or doubled slash is a 404, including harmless ones such as `/app-a/%5Fsearch`; clients that send canonical paths are unaffected. `X-HTTP-Method-Override` is removed before proxying; it is not access control, it only keeps the upstream request equal to what the method matcher saw.

Differences from the Elasticsearch Caddyfile: the upstream is `https://os01:9200`, verified with `tls_trust_pool file` against the lab CA mounted at `/etc/caddy/os-root-ca.pem` (`OS_CA_FILE` overrides the path; Caddy reads the file when it loads the config, so `caddy validate` fails without it) ([reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#tls_trust_pool)); the server name defaults to the upstream host, `os01`, which is in the certificate. The site address and the allowlist come from the environment (`OS_SITE_ADDRESS`, `ALLOWED_CIDRS`); Compose refuses to start when either is unset or empty. The `{$VAR:default}` defaults in the Caddyfile (`os.localhost`, `127.0.0.1/32`, `https://os01:9200`) exist so that CI and the proxy-only harness can load the file without an `.env`. An empty `ALLOWED_CIDRS` given to Caddy directly aborts every request (checked with a local Caddy 2.11.7: the empty matcher adapts to `"remote_ip":{}`, matches nothing, and `not` of it matches everything).

What the proxy does not do: a `_bulk` body can name any index (the role stops it, test L-P12); scripted and expensive queries pass every rule (L-P13); query string parameters are not filtered, so `?scroll=1m` on an allowed `_search` opens a scroll context even though `/_search/scroll` is blocked. Caddy is a speed bump for mistakes; OpenSearch roles are the access control.

## expected.tsv

Same format as `es-single/expected.tsv` (the runner in `tests/` owns the contract): tab-separated, one header line, one check per line, run top to bottom (the `setup` rows create the indices later rows use), `-` means none.

| Column | Values |
|---|---|
| `id` | unique, `os-single-NN` |
| `test` | lab test id from the plan (`L-O2`, `L-P12`), `setup` or `health` |
| `site` | `os` (through Caddy, `OS_SITE_ADDRESS`) or `node` (direct to `https://os01:9200` inside the compose network, trusting `certs/root-ca.pem`, bypassing Caddy) |
| `from` | `allowed` or `denied`: a client whose address is inside or outside `ALLOWED_CIDRS`; `-` for `node` |
| `auth` | `none`; `admin` (`ADMIN_PASSWORD`); `app_user` (user `APP_USER`, `app_x`, with `APP_PASSWORD`); `demo_admin`, `demo_kibanaserver`, `demo_readall` (the demo user with its well-known password, which is the user name, for the checks that the demo users are gone) |
| `method`, `path` | sent verbatim (`curl --path-as-is`, percent-encoding untouched) |
| `headers` | `-` or `Name: value` headers joined with `\|`. A row with a body must name its `Content-Type` here (`application/json` or `application/x-ndjson`); the runner refuses a body row without one |
| `body` | `-`, `@<file>` relative to the scenario directory, or `bytes:<n>` (n bytes); sent as is, the file extension sets no type |
| `expect_status` | HTTP status, alternatives joined with `\|`, or `abort` (no HTTP response: connection closed, or the HTTP/2 stream reset; see `tests/README.md`) |
| `expect` | `-` or `jq:<expression>` (`jq -e` on the response body) |

OpenSearch checks `Content-Type` strictly. curl labels a `--data-binary` body `application/x-www-form-urlencoded` when no type is given, and OpenSearch answers 406 `Content-Type header [application/x-www-form-urlencoded] is not supported`. In the first lab run (2026-10-29, OpenSearch 3.9.0) the body rows had no `Content-Type`: both index creations failed with 406 and every later row that needs `app-a` cascaded. Elasticsearch accepted the same requests, so the omission only showed here. Requests without a body (`POST /app-a/_count`, `DELETE /app-a`) send no `Content-Type` and are not affected.

What the rows check, by lab test:

- L-O2: no anonymous access (401 on `/` at the node); `admin` from the rendered users file has `all_access`; `admin:admin`, `kibanaserver:kibanaserver` and `readall:readall` are rejected.
- L-O3: `app_x` is mapped to `app_writer`; `_bulk` into `app-a` works; a `_bulk` item with `"_index":"secret"` gets 403 inside a 200 response; `secret/_search`, creating `app-b` and deleting `app-a` get 403. The same foreign `_bulk` through Caddy is L-P12: Caddy passes it, only the role stops it. OBSERVED 2026-10-29: `bodies/bulk-own.ndjson`, an `index` action without `_id`, is accepted for `app_x` (`errors: false`, `os-single-12`), because this role grants `indices:data/write/index`; an `index` item naming `secret` gets a per-item 403 at the node and through Caddy (`os-single-13`, `os-single-44`). It was also the first document in `app-a`, so `app_writer` is sufficient for a bulk write that adds a dynamic mapping; whether each of its permissions is necessary was not tested.
- L-M1: heap max is exactly 1 GiB. L-C1: `allocated_processors` is 1 with `cpus: 1`. Both OBSERVED 2026-10-29 (`os-single-09`, `os-single-10`), so `node.processors` is not needed here.
- L-P1 to L-P20 except L-P11 and L-P16: non-allowlisted peers are aborted even with valid credentials; allowlisted without credentials get 401 from OpenSearch; admin paths, encoded, case, dot-segment (also in front of an app route, such as `/secret/../app-a/_search`), doubled-slash, comma, wildcard and date-math variants get 404 from Caddy even with admin credentials; a scripted aggregation passes every layer (not covered); a 21 MB body gets 413; `X-HTTP-Method-Override: DELETE` has no effect (the index still has documents afterwards); `_msearch`, point in time, asynchronous search, scroll, single-document writes, `_delete_by_query`, `DELETE` and `/` get 404.
- L-P11 (raw or decoded path upstream) and L-P16 (absolute-form request line) need the echo upstream and a raw socket and belong to `tests/proxy-matrix.tsv`. L-O1 (no certificates) needs a deliberately broken variant and is not a row here.

L-P14 needs a live upstream: in a local check with an unreachable upstream, a 21 MB body got 502, not 413, because Caddy failed to dial before it read the body.

## Benchmarks

`compose.bench.yaml` is the override `bench/run.sh --engine os` requires. It publishes the node on `127.0.0.1:9200`, switches the node to plain HTTP so that the loader and `run.sh` talk to it exactly as they talk to Elasticsearch, replaces the data volume with a bind mount of `$BENCH_DATA_DIR`, and keeps Caddy from starting (`profiles: [proxy]`). Authentication stays on: `run.sh` logs in as `admin` with `LOADER_PASSWORD`, which must be `ADMIN_PASSWORD` from `.env`. `BENCH_DATA_DIR` must be writable by uid 1000. HTTP TLS is off only in the benchmark, so the numbers do not include TLS cost on either engine.

## Verified by the lab run, and not

Shown by the run on 2026-10-29: the node starts with these files and serves HTTPS; the security index initializes from the mounted files (`admin` has `all_access`, `os-single-04`; the demo passwords are rejected, `-05` to `-07`); the healthcheck lets `compose up --wait` complete; `init-security.sh` and its `hash.sh` output produce users that authenticate; `app_writer` is sufficient for `_bulk` with dynamic mapping; every row of `expected.tsv`.

Still not verified: that `compose.bench.yaml`'s override of `plugins.security.ssl.http.enabled` switches the node to plain HTTP; that `securityadmin.sh -h os01 -p 9200` (`init-security.sh --apply`) works with this certificate; which `app_writer` permissions are strictly necessary; L-O1.

Static checks done when this was written: `docker compose config` with `.env.example` (base and with `compose.bench.yaml`), `caddy fmt` / `caddy validate` / `caddy adapt` with Caddy 2.11.7, the proxy-only matrix (`tests/run-proxy-matrix.sh --engine os`, 93 of 93 rows), `gen-certs.sh` run and its output verified with `openssl verify` and a TLS handshake, `init-security.sh` run against a stub `docker`, `bash -n`, YAML, JSON and TSV well-formedness.
