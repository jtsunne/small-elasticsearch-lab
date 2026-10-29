# os-single-dashboards

The `os-single` scenario plus OpenSearch Dashboards 3.9.0, on its own site behind the same Caddy and the same IP allowlist. Everything in `../os-single/README.md` applies here; read it first. This file covers only what Dashboards adds.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 12 logical CPUs, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with OpenSearch 3.9.0, OpenSearch Dashboards 3.9.0 and Caddy 2.11.7 as pinned in `versions.env`. Result: 70 of 70 rows pass, `results/tests/2026-10-29-os-single-dashboards.tap`.

The first run the same day passed 55 of 70. Its failures were the same 14 rows as in `os-single` (missing `Content-Type` and its cascade, and the HTTP/2 abort seen as curl exit 92), plus `os-single-dashboards-64` (L-K2, the same exit 92 on the Dashboards site). See `../os-single/README.md` for each.

Not tested: Dashboards memory use and startup time with `mem_limit: 1g` (the run shows it starts and answers; `OOMKilled` and timings were not recorded), `compose.bench.yaml`, and the items listed for `os-single`.

## What Dashboards adds

- **A third internal user, `kibanaserver`.** Dashboards logs in to OpenSearch with it for its own system work; people log in to Dashboards with their own users (`admin` here). `kibanaserver` is mapped to the built-in `kibana_server` role in `roles_mapping.yml`, as the image does. The image ships it with the password `kibanaserver` ([3.9.0.0 config](https://github.com/opensearch-project/security/blob/3.9.0.0/config/internal_users.yml)); here its hash comes from `KIBANASERVER_PASSWORD` like the other users.
- **Our own `opensearch_dashboards.yml`.** The image file "works with the demo security configuration", and a mounted file "replaces the default file entirely" ([Dashboards docker](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/docker/)). It points at `https://os01:9200` with `opensearch.ssl.verificationMode: full` and the lab CA ([Dashboards TLS](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/tls/)). Demo mode does not verify the node certificate; this does, and the node certificate has `os01` in its SAN for that reason.
- **Secrets through `${VAR}`.** Dashboards replaces `${VAR}` in its YAML from the environment and refuses to start when the variable is missing ([read_config.ts at 3.9.0](https://github.com/opensearch-project/OpenSearch-Dashboards/blob/3.9.0/packages/osd-config/src/raw/read_config.ts)). `KIBANASERVER_PASSWORD` and `DASHBOARDS_COOKIE_SECRET` are deliberately not names the image entrypoint converts to command-line flags (`OPENSEARCH_PASSWORD` would be, and would then sit in the process list; [Dashboards entrypoint](https://github.com/opensearch-project/opensearch-build/blob/main/docker/release/config/opensearch-dashboards/opensearch-dashboards-docker-entrypoint-default.x.sh)).
- **The session cookie secret.** `opensearch_security.cookie.password` defaults to the fixed string `security_cookie_default_password` and must be at least 32 characters ([security-dashboards-plugin at 3.9.0.0](https://github.com/opensearch-project/security-dashboards-plugin/blob/3.9.0.0/server/index.ts)). Keeping the default means every such install encrypts its session cookies with a public password. `init-security.sh` refuses a `*_SECRET` shorter than 32 characters or still set to the `.env.example` value.
- **`opensearch_security.cookie.secure: true`.** Browsers reach Dashboards over HTTPS through Caddy, so the cookie must be marked secure even though Caddy talks to Dashboards over plain HTTP on the compose network ([Dashboards TLS](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/tls/)).
- **Multitenancy off.** One team, one tenant; fewer moving parts and fewer system indices.
- **Memory.** `mem_limit: 1g`, `cpus: 1`, and a V8 heap of 640 MB through `NODE_OPTIONS`, which the Dashboards launcher appends after `config/node.options` ([use_node at 3.9.0](https://github.com/opensearch-project/OpenSearch-Dashboards/blob/3.9.0/scripts/use_node)). This is a starting point, not a measured number. The Dashboards docs recommend "four CPU cores and 8 GB of RAM" in the context of startup timeouts ([install Dashboards](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/index/)); whether 1 GiB is enough on this version is for the lab to show (check `OOMKilled` and startup time). Host budget for this scenario: 2 GiB node, 1 GiB Dashboards, Caddy, the OS.

## The proxy does not protect the API once Dashboards is exposed

The API site has a path allowlist; the Dashboards site cannot have one, because Dashboards needs its whole URL space. Dev Tools sends any request to OpenSearch through `/api/console/proxy` on behalf of the logged-in user. So an allowlisted client with a Dashboards login reaches every API that user's roles allow, `_cluster`, `_plugins/_security` and all, without touching the API site's rules. `expected.tsv` shows both sides, OBSERVED on 2026-10-29: `app_x` gets 403 for `_cluster/settings` through the console proxy (`os-single-dashboards-69`), `admin` gets 200 with the cluster settings (`-70`), although Caddy answers 404 for `_cluster` paths on the API site. Unlike Kibana 9.5.5, Dashboards 3.9.0 accepted these console requests with only `osd-xsrf: true` and basic auth; no internal-origin header was needed. Exposing Dashboards makes OpenSearch roles the only access control; that was true before, now it is also obvious.

## Run

```sh
cd scenarios/os-single-dashboards
./init-env.sh                 # random passwords, KIBANASERVER_PASSWORD, DASHBOARDS_COOKIE_SECRET; then set both site addresses, ALLOWED_CIDRS
certs/gen-certs.sh
./init-security.sh            # hashes admin, app_x and kibanaserver
cd ../.. && make up SCENARIO=os-single-dashboards
```

Caddy serves the API on `OS_SITE_ADDRESS` and Dashboards on `DASHBOARDS_SITE_ADDRESS` (`os.localhost` and `dashboards.localhost` with Caddy's internal CA by default, on `127.0.0.1:8443`). Log in to Dashboards as `admin`. `osd01` has no published port; `caddy` waits for the node to be healthy and for `osd01` to have started.

## Files

Same as `os-single` (each scenario is self-contained, so the shared files are copies; `opensearch.yml` differs only in `cluster.name`), plus:

| File | What it is |
|---|---|
| `opensearch_dashboards.yml` | Dashboards configuration, mounted over the image file |
| `compose.yaml` | adds `osd01` and the `DASHBOARDS_SITE_ADDRESS` for Caddy |
| `Caddyfile` | the `os-single` API site unchanged, plus the Dashboards site: allowlist, body limit, no path rules (`DASHBOARDS_UPSTREAM` overrides `osd01:5601`) |
| `internal_users.yml.example`, `roles_mapping.yml` | add `kibanaserver` and its `kibana_server` mapping |
| `.env.example` | adds `KIBANASERVER_PASSWORD`, `DASHBOARDS_COOKIE_SECRET`, `DASHBOARDS_SITE_ADDRESS` |
| `init-env.sh` | as in `os-single`; `DASHBOARDS_COOKIE_SECRET` gets 48 random alphanumeric characters |
| `compose.bench.yaml` | as in `os-single`, plus `OPENSEARCH_HOSTS=["http://os01:9200"]` for `osd01`, because the benchmark switches the node to plain HTTP; Dashboards keeps running and its load is part of the host load |

## expected.tsv

Format as in `../os-single/README.md`, plus site `dashboards` (through Caddy, `DASHBOARDS_SITE_ADDRESS`) and auth `kibanaserver/KIBANASERVER_PASSWORD` (the runner's generic `user/VAR` form). Rows 01 to 62 are the `os-single` checks. The added rows: `kibanaserver` authenticates and has `kibana_server` (L-O2); a non-allowlisted peer is aborted on the Dashboards site, an allowlisted one gets the login page (L-K2); `/api/status` is 401 without credentials, 200 for `admin`, 401 for `kibanaserver:kibanaserver`; the console proxy rows described above.

Every row with a body names its `Content-Type` in the `headers` column. Without it curl sends `application/x-www-form-urlencoded`, which OpenSearch rejects with 406; in the first lab run (2026-10-29) that failed the index creation rows and cascaded into every row that needs `app-a`. See `../os-single/README.md`.

## Verified by the lab run, and not

Shown by the run on 2026-10-29, in addition to the `os-single` list: Dashboards 3.9.0 starts with this file and `mem_limit: 1g`; the healthcheck lets `compose up --wait` complete; `/app/login` is aborted for a non-allowlisted peer and answers 200 for an allowlisted one (`-64`, `-65`); `/api/status` requires authentication with the security plugin (401 without credentials, `-66`; 200 for `admin`, `-67`; 401 for `kibanaserver:kibanaserver`, `-68`); basic auth works against the Dashboards API; the console proxy rows above.

Still not verified: memory headroom and startup time at 1 GiB, and that `OPENSEARCH_HOSTS` in the bench override wins over the mounted YAML.

Static checks done when this was written: `docker compose config` (base and with `compose.bench.yaml`), `caddy fmt` / `caddy validate` / `caddy adapt` with Caddy 2.11.7, the proxy-only matrix against the API site (`tests/run-proxy-matrix.sh --engine os`, 93 of 93 rows), a local Caddy run showing that a non-allowlisted peer is aborted on both sites and an allowlisted one is proxied to the Dashboards upstream, `gen-certs.sh` and `init-security.sh` (stub `docker`) runs, `bash -n`, YAML, JSON and TSV well-formedness.
