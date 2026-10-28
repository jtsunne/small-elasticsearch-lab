# os-single-dashboards

The `os-single` scenario plus OpenSearch Dashboards 3.9.0, on its own site behind the same Caddy and the same IP allowlist. Everything in `../os-single/README.md` applies here; read it first. This file covers only what Dashboards adds.

**Tested on: NOT YET TESTED.** Nothing in this directory has been run against a real OpenSearch node or Dashboards. Static checks only. Every expectation in `expected.tsv` is a hypothesis until the lab run records it.

## What Dashboards adds

- **A third internal user, `kibanaserver`.** Dashboards logs in to OpenSearch with it for its own system work; people log in to Dashboards with their own users (`admin` here). `kibanaserver` is mapped to the built-in `kibana_server` role in `roles_mapping.yml`, as the image does. The image ships it with the password `kibanaserver` ([3.9.0.0 config](https://github.com/opensearch-project/security/blob/3.9.0.0/config/internal_users.yml)); here its hash comes from `KIBANASERVER_PASSWORD` like the other users.
- **Our own `opensearch_dashboards.yml`.** The image file "works with the demo security configuration", and a mounted file "replaces the default file entirely" ([Dashboards docker](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/docker/)). It points at `https://os01:9200` with `opensearch.ssl.verificationMode: full` and the lab CA ([Dashboards TLS](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/tls/)). Demo mode does not verify the node certificate; this does, and the node certificate has `os01` in its SAN for that reason.
- **Secrets through `${VAR}`.** Dashboards replaces `${VAR}` in its YAML from the environment and refuses to start when the variable is missing ([read_config.ts at 3.9.0](https://github.com/opensearch-project/OpenSearch-Dashboards/blob/3.9.0/packages/osd-config/src/raw/read_config.ts)). `KIBANASERVER_PASSWORD` and `DASHBOARDS_COOKIE_SECRET` are deliberately not names the image entrypoint converts to command-line flags (`OPENSEARCH_PASSWORD` would be, and would then sit in the process list; [Dashboards entrypoint](https://github.com/opensearch-project/opensearch-build/blob/main/docker/release/config/opensearch-dashboards/opensearch-dashboards-docker-entrypoint-default.x.sh)).
- **The session cookie secret.** `opensearch_security.cookie.password` defaults to the fixed string `security_cookie_default_password` and must be at least 32 characters ([security-dashboards-plugin at 3.9.0.0](https://github.com/opensearch-project/security-dashboards-plugin/blob/3.9.0.0/server/index.ts)). Keeping the default means every such install encrypts its session cookies with a public password. `init-security.sh` refuses a `*_SECRET` shorter than 32 characters or still set to the `.env.example` value.
- **`opensearch_security.cookie.secure: true`.** Browsers reach Dashboards over HTTPS through Caddy, so the cookie must be marked secure even though Caddy talks to Dashboards over plain HTTP on the compose network ([Dashboards TLS](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/tls/)).
- **Multitenancy off.** One team, one tenant; fewer moving parts and fewer system indices.
- **Memory.** `mem_limit: 1g`, `cpus: 1`, and a V8 heap of 640 MB through `NODE_OPTIONS`, which the Dashboards launcher appends after `config/node.options` ([use_node at 3.9.0](https://github.com/opensearch-project/OpenSearch-Dashboards/blob/3.9.0/scripts/use_node)). This is a starting point, not a measured number. The Dashboards docs recommend "four CPU cores and 8 GB of RAM" in the context of startup timeouts ([install Dashboards](https://docs.opensearch.org/latest/install-and-configure/install-dashboards/index/)); whether 1 GiB is enough on this version is for the lab to show (check `OOMKilled` and startup time). Host budget for this scenario: 2 GiB node, 1 GiB Dashboards, Caddy, the OS.

## The proxy does not protect the API once Dashboards is exposed

The API site has a path allowlist; the Dashboards site cannot have one, because Dashboards needs its whole URL space. Dev Tools sends any request to OpenSearch through `/api/console/proxy` on behalf of the logged-in user. So an allowlisted client with a Dashboards login reaches every API that user's roles allow, `_cluster`, `_plugins/_security` and all, without touching the API site's rules. `expected.tsv` shows both sides: `app_x` gets 403 from OpenSearch for `_cluster/settings` through the console proxy, `admin` gets 200. Exposing Dashboards makes OpenSearch roles the only access control; that was true before, now it is also obvious.

## Run

```sh
cd scenarios/os-single-dashboards
cp .env.example .env          # passwords, KIBANASERVER_PASSWORD, DASHBOARDS_COOKIE_SECRET, both site addresses, ALLOWED_CIDRS
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
| `compose.bench.yaml` | as in `os-single`, plus `OPENSEARCH_HOSTS=["http://os01:9200"]` for `osd01`, because the benchmark switches the node to plain HTTP; Dashboards keeps running and its load is part of the host load |

## expected.tsv

Format as in `../os-single/README.md`, plus site `dashboards` (through Caddy, `DASHBOARDS_SITE_ADDRESS`) and auth `kibanaserver/KIBANASERVER_PASSWORD` (the runner's generic `user/VAR` form). Rows 01 to 62 are the `os-single` checks. The added rows: `kibanaserver` authenticates and has `kibana_server` (L-O2); a non-allowlisted peer is aborted on the Dashboards site, an allowlisted one gets the login page (L-K2); `/api/status` is 401 without credentials, 200 for `admin`, 401 for `kibanaserver:kibanaserver`; the console proxy rows described above.

## Not verified (needs the lab run)

In addition to the `os-single` list: that Dashboards 3.9.0 starts with this file and 1 GiB, that `/app/login`, `/api/status` and `/api/console/proxy` answer as `expected.tsv` says (in particular whether `/api/status` requires authentication with the security plugin), that basic auth headers work against the Dashboards API, that the healthcheck's `curl` exists in the Dashboards image, and that `OPENSEARCH_HOSTS` in the bench override wins over the mounted YAML.

Static checks done when this was written: `docker compose config` (base and with `compose.bench.yaml`), `caddy fmt` / `caddy validate` / `caddy adapt` with Caddy 2.11.7, the proxy-only matrix against the API site (`tests/run-proxy-matrix.sh --engine os`, 93 of 93 rows), a local Caddy run showing that a non-allowlisted peer is aborted on both sites and an allowlisted one is proxied to the Dashboards upstream, `gen-certs.sh` and `init-security.sh` (stub `docker`) runs, `bash -n`, YAML, JSON and TSV well-formedness.
