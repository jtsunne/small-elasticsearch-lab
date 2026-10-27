# es-single-kibana

The `es-single` scenario plus Kibana 9.5.5. Kibana talks to Elasticsearch directly on the compose network as `kibana_system` and is exposed through the same Caddy, behind the same IP allowlist. Read `../es-single/README.md` first; this file only lists what is different.

**Tested on: NOT YET TESTED.** Static checks only: `docker compose config`, `caddy validate`, `bash -n`, a proxy-only run of the Caddyfile. No Kibana or Elasticsearch has been started from these files.

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

## Things to know

- **Kibana bypasses the Elasticsearch path allowlist.** Anyone who can log in to Kibana has a full Elasticsearch client in Dev Tools (`/api/console/proxy`), limited only by their own Elasticsearch roles. Row `L-K3` in `expected.tsv` shows `_cluster/settings` through Kibana as `elastic` (expected 200) and as `app_x` (expected 401 or 403). Give Kibana users roles as narrow as API keys, and keep `elastic` for setup.
- **Secrets in environment variables are visible.** Kibana's Docker image turns environment variables into command-line arguments, and the Kibana docs warn they are "visible through the ps command". That covers `ELASTICSEARCH_PASSWORD` and the three encryption keys. Acceptable for a single-user lab host; on a shared host put them in the Kibana keystore instead.
- **L-K1 (Kibana refuses `elastic`) is manual,** because it is a start failure, not an HTTP check:

  ```sh
  ELASTIC_PASSWORD=$(grep -m1 '^ELASTIC_PASSWORD=' scenarios/es-single-kibana/.env | cut -d= -f2-)
  docker compose --project-directory scenarios/es-single-kibana --env-file versions.env \
    --env-file scenarios/es-single-kibana/.env -f scenarios/es-single-kibana/compose.yaml \
    run --rm --no-deps -e ELASTICSEARCH_USERNAME=elastic -e ELASTICSEARCH_PASSWORD=$ELASTIC_PASSWORD kibana
  ```

  Expected (HYPOTHESIS, from Kibana source): Kibana exits during config validation with a message that the value "elastic" is forbidden. Record the exact text. The password does appear on this command line; use a throwaway lab password.

## What this scenario covers

Everything `es-single` covers (the same `L-*` rows, run against this stack), plus:

| Lab test | Rows | Note |
|---|---|---|
| L-S1 with Kibana | `L-S1` | shards and all indices including hidden ones, recorded |
| L-K2 | `L-K2` | denied client: aborted; allowed client: `/api/status` and `/login` answer |
| L-K3 (added, not in the plan matrix) | `L-K3` | Dev Tools console proxy reaches `_cluster/settings` for `elastic`, not for `app_x` |
| L-K1 | manual, see above | |

Hypotheses in these rows: the unauthenticated `/api/status` body contains `available` once Kibana is ready (the docs say unauthenticated callers get a redacted body with the overall level); Kibana accepts HTTP basic credentials on `/api/console/proxy` with a `kbn-xsrf` header; `app_x`, which has no Kibana privileges, gets 401 or 403 there.
