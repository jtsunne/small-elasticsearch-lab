# es-single-kibana

The `es-single` scenario plus Kibana 9.5.5. Kibana talks to Elasticsearch directly on the compose network as `kibana_system` and is exposed through the same Caddy, behind the same IP allowlist. Read `../es-single/README.md` first; this file only lists what is different.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 12 logical CPUs, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5, Kibana 9.5.5 and Caddy 2.11.7 as pinned in `versions.env`. Result: 90 of 91 rows pass, `results/tests/2026-10-29-es-single-kibana.tap`. The one failure, `es-single-kibana-01`, asserted green with a single-shot `GET /_cluster/health` while Kibana was still creating its system indices: at that instant one primary was unassigned and the status was yellow. Every later row passed. The row now waits for green with `wait_for_status=green&timeout=60s`, as `es-three-local` does; that form has not been run on this scenario yet.

The first run the same day passed 81 of 89. Its failures, and what they turned out to be:

- `es-single-kibana-07`, `-08` (L-P1) and `-79`, `-80` (L-K2): Caddy did abort, but over HTTP/2 curl reports the stream reset as exit 92, which the runner did not count as `abort`. Fixed in the runner.
- `es-single-kibana-65` (L-P16): the absolute-form request got the same exit 92; `abort` is now an accepted outcome of the row.
- `es-single-kibana-57` (L-P12): the row assumed `create_doc` allows a bulk `index` item; Elasticsearch rejects it with 403. The row was split (new row `es-single-kibana-90`).
- `es-single-kibana-83`, `-84` (L-K3): Kibana answered 400 because `/api/console/proxy` is an internal route; see "The console proxy is an internal route". The rows now send `x-elastic-internal-origin`, and row `es-single-kibana-91` keeps the 400.

Not tested: L-K1 (manual, below), L-M1 in auto-sizing mode, Kibana with `KIBANA_MEM_LIMIT=2g` or with alerting in use, and Kibana in front of a three-node cluster.

## Differences from es-single

| Item | What | Source |
|---|---|---|
| `kibana-setup` service | one-shot container (Elasticsearch image, for its curl) that sets the `kibana_system` password through `POST /_security/user/kibana_system/_password`; `kibana` waits for it to exit 0. Same approach as the official compose file. Passwords must be alphanumeric, which the official setup also requires, so neither the JSON body nor the curl config needs escaping | https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-change-password , https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-compose |
| `ELASTICSEARCH_HOSTS=http://es01:9200`, `ELASTICSEARCH_USERNAME=kibana_system` | Kibana goes straight to the node, not through Caddy. Kibana refuses `elastic` as its connection user (from Kibana source, not the docs) | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-kibana-with-docker |
| `SERVER_PUBLICBASEURL` | the URL users type, with port when it is not 443, no trailing slash | https://www.elastic.co/docs/reference/kibana/configuration-reference/general-settings |
| `XPACK_SECURITY_ENCRYPTIONKEY`, `XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY`, `XPACK_REPORTING_ENCRYPTIONKEY` | at least 32 characters each. Without a saved-objects key Kibana generates one per start and some features, alerting among them, are unavailable. `init-env.sh` generates all three; keep them stable, because a new saved-objects key makes existing encrypted objects unreadable. `bin/kibana-encryption-keys generate` is the official generator if you prefer it | https://www.elastic.co/docs/reference/kibana/configuration-reference/security-settings , https://www.elastic.co/docs/reference/kibana/configuration-reference/reporting-settings , https://www.elastic.co/docs/reference/kibana/commands/kibana-encryption-keys |
| `mem_limit: ${KIBANA_MEM_LIMIT:-1g}` | 1 GiB as in the official compose file. Elastic recommends "at least 2 GB" with alerting, reporting, detection rules or SLOs. Since 9.4 the container Node.js heap defaults to 75% of container memory, up to 4096 MB. Elasticsearch (2 GiB) plus Kibana (1 to 2 GiB) plus Caddy and the OS need a host of about 4 GB | https://www.elastic.co/docs/deploy-manage/production-guidance/kibana-configure-memory |
| Kibana healthcheck | `curl -s -I http://localhost:5601` returns `302 Found`, as in the official compose file | official docker-compose.yml |
| Second Caddy site `KIBANA_SITE_ADDRESS` | IP allowlist and TLS only; Kibana's login does authentication | |

## Run

```sh
scenarios/es-single-kibana/init-env.sh
make up SCENARIO=es-single-kibana       # waits for kibana-setup to finish and Kibana to be healthy
scenarios/es-single-kibana/setup-roles.sh --key-out /tmp/app-key.env
make test SCENARIO=es-single-kibana
make down SCENARIO=es-single-kibana
```

Kibana is at `https://kibana.localhost:8443`, log in as `elastic` for the lab. Set `KIBANA_MEM_LIMIT=2g` before using alerting.

## Heap modes (L-M1)

Same as `es-single`: L-M1 runs twice with the same `expected.tsv`, and the mode comes from `ES_HEAP_OPTS` in this directory's `.env`. Kibana's memory is unaffected.

| Mode | `.env` | `ES_JAVA_OPTS` | Rows | Expected |
|---|---|---|---|---|
| explicit (default) | no `ES_HEAP_OPTS` line, or commented out | `-Xms1g -Xmx1g` | `L-M1` | OBSERVED 2026-10-29: heap max 1073741824 bytes; recorded `input_arguments` contain `-Xmx1g` (`es-single-kibana-02`, `es-single-kibana-85`) |
| auto-sizing | `ES_HEAP_OPTS=` (empty value) | empty | the same `L-M1` rows | NOT YET RUN. HYPOTHESIS: heap max 1073741824 bytes, half of the 2 GiB container, with no `-Xmx1g` recorded |

All other rows run in the explicit mode. Switch by adding or deleting the `ES_HEAP_OPTS=` line before `make test SCENARIO=es-single-kibana`; an `ES_HEAP_OPTS` variable in the shell overrides `.env`. The sources and the reasoning behind the auto-mode expectation are in `../es-single/README.md`, "Heap modes (L-M1)".

## The application API key

`setup-roles.sh` is identical to the one in `es-single`. It creates the app key as `elastic`, with an expiration and `role_descriptors`; `app_writer` has no cluster privileges, so `app_x` cannot create keys. The exact request:

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

Trade-off: a leaked app password can no longer mint keys; the key is scoped to `read` and `create_doc` on `app-*` and expires after 30 days; `elastic` is needed only for setup and rotation (run `setup-roles.sh` again, then invalidate the old key with `DELETE /_security/api_key` and `{"ids": ["<old key id>"]}`). Because the owner is a superuser, `role_descriptors` are the key's only limit, and the `L-P3` and `L-P4` node rows check them. Source: https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key ; details in `../es-single/README.md`, "The application API key".

## Things to know

- **Kibana bypasses the Elasticsearch path allowlist.** Anyone who can log in to Kibana has a full Elasticsearch client in Dev Tools (`/api/console/proxy`), limited only by their own Elasticsearch roles: Kibana sends the console request to `es01:9200` directly, with the logged-in user's credentials, so the Caddy allowlist in front of the `es` site never sees it. The allowlist protects the Elasticsearch site, not Kibana's console; whoever reaches the Kibana site and can log in gets every Elasticsearch API their role allows, `_cluster/settings`, `_security` and `_snapshot` included. OBSERVED on 2026-10-29: through Kibana, `elastic` read `_cluster/settings` (200, body contains `persistent`, row `es-single-kibana-83`) although Caddy answers 404 for that path on the `es` site (`es-single-kibana-14`); `app_x` was refused with 401 or 403 and no settings (`es-single-kibana-84`; the TAP does not record which of the two statuses it was). Give Kibana users roles as narrow as API keys, keep `elastic` for setup, and restrict the Kibana site's `ALLOWED_CIDRS` as tightly as the Elasticsearch site's.
- **The console proxy is an internal route.** In both lab runs (2026-10-29, Kibana 9.5.5) `POST /api/console/proxy` with basic auth and `kbn-xsrf` answered 400 `uri [/api/console/proxy] with method [post] exists but is not available with the current configuration`. VERIFIED from the Kibana v9.5.5 source: the route (`src/platform/plugins/shared/console/server/routes/api/console/proxy/index.ts`) declares no `access`, so it defaults to `internal` (`src/core/packages/http/router-server-internal/src/request.ts`, `getAccess`); `server.restrictInternalApis` defaults to `true` (`src/core/packages/http/server-internal/src/http_config.ts`); and a post-auth handler (`lifecycle_handlers.ts`, `createRestrictInternalRoutesPostAuthHandler`) answers exactly that 400 to an internal route unless the request carries the header `x-elastic-internal-origin` (any value) or the query parameter `elasticInternalOrigin`. The route is not versioned, so no `elastic-api-version` header is needed. The header is not a security boundary: any client can send it, and Kibana's own browser client sets `x-elastic-internal-origin: Kibana` on every request (`src/core/packages/http/browser-internal/src/fetch.ts`). Rows `es-single-kibana-83` and `-84` send `x-elastic-internal-origin: Kibana` and passed in the second run; row `es-single-kibana-91` keeps the observed 400 without it and passed too.
- **`create_doc` rejects the bulk `index` action.** The app key and `app_x` have `create_doc`, which allows bulk `create` items and `POST /<index>/_doc` without an id, but answers 403 to a bulk `index` item even without `_id` (`indices:data/write/index:op_type/index`, granted only by `create`, `index`, `write` or `all`; observed 2026-10-29, Elasticsearch 9.5.5). Clients whose bulk helper sends `index` by default must send `create`; granting `index` or `write` instead also allows overwriting documents. Rows `L-P12` check `bodies/bulk-own-create.ndjson` (all 201) and `bodies/bulk-own.ndjson` (`create` 201, `index` 403). Details in `../es-single/README.md`, "`create_doc` and the bulk `index` action".
- **Secrets in environment variables are visible.** Kibana's Docker image turns environment variables into command-line arguments, and the Kibana docs warn they are "visible through the ps command". That covers `ELASTICSEARCH_PASSWORD` and the three encryption keys. Acceptable for a single-user lab host; on a shared host put them in the Kibana keystore instead.
- **L-K1 (Kibana refuses `elastic`) is manual,** because it is a start failure, not an HTTP check:

  ```sh
  ELASTIC_PASSWORD=$(grep -m1 '^ELASTIC_PASSWORD=' scenarios/es-single-kibana/.env | cut -d= -f2-)
  docker compose --project-directory scenarios/es-single-kibana --env-file versions.env \
    --env-file scenarios/es-single-kibana/.env -f scenarios/es-single-kibana/compose.yaml \
    run --rm --no-deps -e ELASTICSEARCH_USERNAME=elastic -e ELASTICSEARCH_PASSWORD=$ELASTIC_PASSWORD kibana
  ```

  NOT YET RUN. Expected (HYPOTHESIS, from Kibana source): Kibana exits during config validation with a message that the value "elastic" is forbidden. Record the exact text. The password does appear on this command line; use a throwaway lab password.

## What this scenario covers

Everything `es-single` covers (the same `L-*` rows, including the API key rows and both heap modes of L-M1, run against this stack), plus:

| Lab test | Rows | Note |
|---|---|---|
| L-S1 with Kibana | `L-S1` | shards and all indices including hidden ones, recorded. 2026-10-29, right after setup and while Kibana was still starting: 36 shards (35 started, 1 initializing), 34 of them not `app-a` or `secret`, and 53 indices including hidden ones (`results/tests/2026-10-29-es-single-kibana/es-single-kibana-05.json`, `-78.json`). Without Kibana the same query returned 5 shards (`es-single`). A snapshot during startup, not a settled count |
| L-K2 | `L-K2` | observed 2026-10-29: denied client aborted (`-79`, `-80`); allowed client gets `/api/status` with `available` and `/login` 200 (`-81`, `-82`) |
| L-K3 (added, not in the plan matrix) | `L-K3` | observed 2026-10-29: Dev Tools console proxy reaches `_cluster/settings` for `elastic`, not for `app_x` |
| L-K1 | manual, see above | not yet run |

Hypotheses in these rows, all OBSERVED on 2026-10-29 (`results/tests/2026-10-29-es-single-kibana.tap`): the unauthenticated `/api/status` body contains `available` once Kibana is ready (`-81`); Kibana accepts HTTP basic credentials on `/api/console/proxy` with `kbn-xsrf` and `x-elastic-internal-origin` headers (`-83`); `app_x`, which has no Kibana privileges, gets 401 or 403 there (`-84`). Still open: which of 401 or 403 `app_x` gets, and whether that comes from the missing `console` Kibana privilege or from Elasticsearch.
