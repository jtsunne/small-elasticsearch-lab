# es-grow-restore

Growth procedure A, the recommended one: keep the single node as it is, take a snapshot of it into a shared filesystem repository, build a new three-node cluster next to it, restore, compare, and move Caddy over. The old node stays untouched until you decide to remove it, so rollback is pointing Caddy back.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 6 cores / 12 threads, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5 and Caddy 2.11.7 as pinned in `versions.env`. The runbook below ran once, in order, and every step exited 0: steps 0, 1, 2 (`grow-1`), 3, 4 (`grow-1`), 2 `--final`, 4 (`grow-final --replace`), 5. The end-state checks then passed 22 of 22 rows (`COMPOSE_PROFILES=new NODE_SERVICE=es01`, stack kept up), `results/tests/2026-10-29-es-grow-restore.tap`. The step output is `results/tests/2026-10-29-es-grow-restore-steps.log`. One laptop run with 1,001 documents is one data point, not a reference.

Observed (L-G1):

- Before cutover there were two clusters, as intended: es00 and the new cluster reported different `cluster_uuid` values (step 3 output).
- Both snapshots ended `SUCCESS` with the indices `.security-7`, `app-a`, `app-b` and the feature state `security` (step 2 output, both runs).
- Restore plus replica recovery took 5 s for `grow-1` and 5 s for `grow-final` (step 4 output). With 1,001 documents this times the mechanics, not the data; it says nothing about a real index.
- Document counts matched after both restores (`app-a` 1, `app-b` 1000), and the restored indices had 1 replica and `index.blocks.write` `false` (step 4 output; rows `es-grow-restore-03`, `-06`).
- Caddy was back 2 s after it was recreated at cutover (step 5 output).
- Every hypothesis in step 4 held; see the notes there.

Not measured or not tested: the write-blocked window (from `step-2-snapshot.sh --final` to the end of step 5; the step output carries no timestamps), how many client requests fail during the Caddy recreate (no client traffic ran during cutover), `rollback.sh`, decommissioning es00, the second restore without `--replace`, adding `path.repo` to a running single node by restart, and disk sizing.

Operator notes from the run: run `./init-env.sh` before step 0; without `.env` step 0 stops (the first attempt that day did exactly that, an operator error, not a scenario defect). `snapshots/` is a bind-mounted directory that `docker compose down -v` does not delete, and step 2 keeps an existing snapshot of the same name, so remove `snapshots/` (and `.env`) before running the scenario again from step 0.

**Lab only.** es00 and the three new nodes all run on one host; see `es-three-local` for why that gives no fault tolerance.

## Why A is the recommended procedure

- The old node is never reconfigured or restarted during the move (its `path.repo` aside, see step 1). If anything goes wrong on the new cluster, es00 still has every document and Caddy can point back at it.
- The new cluster is built clean: bootstrapped once with `cluster.initial_master_nodes`, transport TLS from the first start, replicas 1 from the first index. None of procedure B's traps (a second bootstrap, a leftover `discovery.type`, a node locked to the wrong cluster UUID) can hit the old data.
- The restore can be rehearsed (snapshot `grow-1`) while the application keeps writing to es00, and timed, before the real cutover.
- The cost: the host runs four nodes for a while, the repository needs room for a full copy, and writes stop between the final snapshot and the cutover. With little data that is seconds to minutes; record it in the lab.

## Files

| File | What it is |
|---|---|
| `compose.yaml` | `es00` (the single node: `es-single`'s configuration plus `path.repo`), `caddy`, and under profile `new` the cluster `es01`..`es03` (as `es-three-local`, plus `path.repo`). All four nodes bind-mount `SNAPSHOT_DIR` at `/usr/share/elasticsearch/snapshots` |
| `Caddyfile` | as `es-three-local`; the upstream list comes from `ES_UPSTREAMS` in `.env` |
| `.env.example` | as `es-single`, plus `SNAPSHOT_DIR` and `ES_UPSTREAMS` |
| `init-env.sh` | writes `.env` with random passwords |
| `certs/gen-certs.sh` | transport certificates for es01..es03, see `es-three-local` |
| `common.sh` | helpers sourced by the scripts: compose command, curl inside a node container as `elastic` (password on stdin), document counts, the guard that tells the two clusters apart, and `wait_ready`, which retries a health wait on 503, 401, 408 and no answer for up to `READY_TIMEOUT` seconds (default 180; 300 in step 4) with one progress line per attempt, because a node can be healthy for compose before its `.security-7` primary is assigned and `elastic` can authenticate (seen in `es-three-local`, 2026-10-29) |
| `step-0-seed.sh` .. `step-5-cutover.sh`, `rollback.sh` | the procedure, one script per step |
| `expected.tsv` | checks of the end state after step 5 |
| `bodies/` | request bodies for `expected.tsv` |

## Runbook

Each script prints what it is about to do (`==>` lines), refuses when a precondition does not hold, and is safe to run twice unless noted. Nothing deletes data on es00. The only deletion anywhere is `step-4-restore.sh --replace`, which deletes `app-*` on the new cluster after checking that it really is the new cluster (cluster name `es-grow-new`, and a `cluster_uuid` different from es00's).

```sh
sudo sysctl -w vm.max_map_count=1048576           # the new cluster runs in production mode
cd scenarios/es-grow-restore
./init-env.sh
./step-0-seed.sh                 # es00 + Caddy, roles, 1000 docs in app-b, app key into .env
./step-1-repo.sh                 # repository grow on es00
./step-2-snapshot.sh             # snapshot grow-1, es00 keeps taking writes
./step-3-new-cluster.sh          # certificates, es01..es03, repository grow read-only there
./step-4-restore.sh grow-1       # rehearsal restore; counts compared; time printed
./step-2-snapshot.sh --final     # writes to es00 blocked from here, snapshot grow-final
./step-4-restore.sh grow-final --replace
./step-5-cutover.sh              # repository handed over, Caddy recreated on es01..es03
COMPOSE_PROFILES=new NODE_SERVICE=es01 ../../tests/run-scenario.sh --keep-up es-grow-restore
```

### Step 0: starting point (`step-0-seed.sh`)

Creates `SNAPSHOT_DIR` if missing (owned by you, group 0, mode 2770, via a root container because only root can set group 0), starts es00 and Caddy, creates the template `app` (replicas 0), role `app_writer`, user `app_x`, indices `app-a` and `app-b`, loads `SEED_DOCS` (default 1000) documents with fixed ids into `app-b`, and creates the app API key as `elastic` with `role_descriptors` and a 30-day expiry, exactly as `es-single` does. The key goes into `.env` as `APP_API_KEY`, so the end-state checks can use it after cutover.

Check: the script prints es00's counts (`app-a 1`, `app-b 1000`).

On a real host es00 is your existing `es-single` node, and step 0 is already done.

### Step 1: repository (`step-1-repo.sh`)

Registers `grow` as type `fs`, `location: grow` (relative to the first `path.repo` entry), on es00, and runs the verify API.

In this lab es00 starts with `path.repo` set. On a real single node it is not set yet, and adding it is the one restart procedure A needs: "first mount the file system to the same location on all master and data nodes. Then add the file system's path or parent directory to the `path.repo` setting in `elasticsearch.yml` for each master and data node. For running clusters, this requires a rolling restart of each node." Source: https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/shared-file-system-repository

Check: the verify call lists es00.

### Step 2: snapshot (`step-2-snapshot.sh [--final]`)

Snapshots `app-*` with `include_global_state: false` and `feature_states: ["security"]`. The security feature state carries the users, roles and API keys from `.security`, so the application's API key keeps working after cutover without a new key. With `include_global_state` false, feature states are restored only when named, which step 4 does. Source: https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-snapshot-restore . That API keys live in `.security` is read from source (`ApiKeyService.java`, v9.5.5), not from a doc page.

Without `--final` it takes `grow-1` while es00 keeps serving writes: a rehearsal. With `--final` it first sets `index.blocks.write: true` on es00's `app-*`, then takes `grow-final`. **From that moment application writes fail** until step 5 or `rollback.sh`. That is the price of a snapshot that is exactly what es00 holds.

Check: the script prints the snapshot state (`SUCCESS`), the indices and the feature states, and es00's counts.

### Step 3: the new cluster (`step-3-new-cluster.sh`)

Generates certificates if `certs/` has none, starts es01..es03 (cluster `es-grow-new`, configured as `es-three-local`), waits for green with three nodes, checks that es01's `cluster_uuid` differs from es00's (two clusters, by design; different `cluster.name` values also keep any node from joining the wrong one), and registers `grow` there with `readonly: true`.

Why read-only: "If you register the same snapshot repository with multiple clusters, only one cluster should have write access to the repository. On other clusters, register the repository as read-only. This prevents multiple clusters from writing to the repository at the same time and corrupting the repository's contents." (shared filesystem page above). Until cutover the writer is es00.

Check: the verify call lists es01..es03, and the snapshot list shows `grow-1`.

### Step 4: restore (`step-4-restore.sh grow-1|grow-final [--replace]`)

Recreates the template `app` on the new cluster with 1 replica (templates are global state, which the snapshot leaves out on purpose so es00's replicas-0 template does not come along), then restores:

```json
POST /_snapshot/grow/<snapshot>/_restore?wait_for_completion=true
{
  "indices": "app-*",
  "include_global_state": false,
  "feature_states": ["security"],
  "index_settings": {"index.number_of_replicas": 1, "index.blocks.write": false}
}
```

- `index_settings` may change any index setting except `index.number_of_shards`, so the restored indices come back with one replica and without the write block that `--final` put on es00. Source: restore API page above. OBSERVED 2026-10-29: `index.blocks.write: false` in `index_settings` overrides the block stored in the `grow-final` snapshot; step 4 printed `blocks.write` `false` and `number_of_replicas` `1` for both indices, and a bulk `create` through Caddy after cutover got 201 (rows `es-grow-restore-06`, `-19`).
- Restoring the security feature state "closes and overwrites the feature's existing indices": the new cluster's users, roles and API keys become es00's. Elastic warns: "Restoring the `security` feature state overwrites system indices used for authentication" and suggests a temporary file-realm superuser so you cannot lock yourself out. Here `elastic` has never had its password changed on either side, so it keeps authenticating with the bootstrap password from each node's keystore after the restore. OBSERVED 2026-10-29: after both restores every later step and the end-state checks authenticated as `elastic` without error. If your `elastic` password was changed through the API on es00, the restored `.security` brings that password along. Source: https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/restore-snapshot
- A restore refuses to overwrite an open index of the same name (FROM TRAINING; the lab run of the second restore without `--replace` would show the error, but the script refuses before that). The second restore therefore needs `--replace`, which deletes `app-*` on the new cluster only, after `assert_new_cluster`.

Then the script waits for green (replica recovery), prints the time, and compares per-index document counts between es00 and the new cluster. After `grow-1` a difference is normal if es00 took writes since; after `grow-final` the script fails on any difference.

Check: counts equal; `number_of_replicas` 1 and no write block on the new indices.

### Step 5: cutover (`step-5-cutover.sh`)

Refuses unless es00's `app-*` are all write-blocked and the counts match, so no write accepted by es00 can be missing on the new cluster. Then:

1. unregisters `grow` on es00 (the files stay) and registers it writable on the new cluster, in that order, so two clusters never hold write access at once;
2. writes `ES_UPSTREAMS=es01:9200 es02:9200 es03:9200` into `.env` and recreates Caddy. Recreating drops connections for a few seconds; the script prints how long. On a real host, edit the Caddyfile and run `caddy reload`, which swaps the config without closing the listener.

Check: run `expected.tsv` as shown above. es00 keeps running, write-blocked, as the rollback target.

### Rollback (`rollback.sh --confirm`)

Valid at any point, as long as es00 still runs. Makes `grow` read-only on the new cluster, registers it writable on es00 again, lifts the write block on es00's `app-*` and points Caddy back at es00. **Documents written to the new cluster after cutover are not copied back**; the script prints both sides' counts so the difference is visible. To bring them back, snapshot the new cluster and restore those indices on es00 under another name, or replay from the application.

To repeat the cutover after a rollback, delete the stale `grow-final` first (`DELETE /_snapshot/grow/grow-final` on es00, as `elastic`): step 2 keeps an existing snapshot of the same name.

### Decommissioning es00

Not scripted. After the new cluster has run for long enough: `docker compose ... stop es00`, keep its volume (and the `grow-final` snapshot) until you are sure, then remove both.

## Traps

| Trap | What happens | Guard |
|---|---|---|
| Both clusters write to the repository | repository corruption, per the shared filesystem page | read-only on the new cluster until step 5; step 5 unregisters on es00 before registering writable on the new side; rollback reverses the order |
| Writes after the final snapshot | lost on the new cluster | `--final` write-blocks es00 first; step 5 refuses unless blocked and counts match |
| Restoring es00's template or persistent settings with `include_global_state: true` | it "completely removes all persistent settings, non-legacy index templates, ingest pipelines, and ILM lifecycle policies" of the new cluster and brings es00's replicas-0 template | `include_global_state: false`; the template is recreated with 1 replica |
| Restoring the security feature state locks you out | possible if `elastic`'s password on es00 differs from what you use | same `ELASTIC_PASSWORD` on both sides; a file-realm superuser on the new cluster for real migrations |
| `path.repo` missing on one node | registering or verifying the repository fails on that node | all three new nodes and es00 mount the same directory at the same path |
| Snapshot directory permissions | the node (uid 1000, gid 0) cannot write | step 0 creates it with group 0 and mode 2770 |
| Disk | the repository holds a full copy; the new cluster holds two copies (replicas 1) | check before step 2 and step 4; this lab does not size it |
| Copying es00's data directory into a new node instead of restoring | the copy carries es00's cluster UUID and node identity; the new node cannot join es-grow-new | the procedure never copies data directories |

## expected.tsv

The end state after step 5. Run it with the new cluster as the node service and the `new` profile, and keep the stack up if you still want es00 for rollback:

```sh
COMPOSE_PROFILES=new NODE_SERVICE=es01 tests/run-scenario.sh --keep-up es-grow-restore
```

The runner's `up --wait` recreates only Caddy (with the test allowlist); `ES_UPSTREAMS` comes from `.env`, so Caddy still points at the new cluster. There is no `setup-roles.sh` on purpose: the runner would run it, and a new key on the new cluster would hide whether the restored key works. The app key comes from `APP_API_KEY` in `.env`.

| Lab test | Rows | Expected |
|---|---|---|
| L-G1 | node rows on es01 | cluster `es-grow-new`, green, 3 nodes; `app-a` and `app-b` green with 1 replica; `app-b` holds exactly 1000 documents; the seed document is present; no write block; template `app` with 1 replica; role `app_writer` and user `app_x` restored; the API key created on es00 authenticates on the new cluster (OBSERVED 2026-10-29, row `es-grow-restore-10`: `authentication_type` `api_key`, name `app-x-key`); `app_x`'s password works; repository `grow` writable; snapshot list recorded |
| L-G1 | proxy rows | the old API key reads and writes through Caddy on the new cluster: a bulk of `create` items accepted (`bodies/bulk-own-create.ndjson`); in `bodies/bulk-own.ndjson` the `index` item gets 403, because the key's `create_doc` does not cover the `index` action (observed 2026-10-29 in `es-single`) |
| L-N1, L-P1, L-P2, L-P4, L-P20 | as `es-single` | unchanged proxy behaviour |

Timings from the 2026-10-29 run: restore and replica recovery 5 s for `grow-1` and 5 s for `grow-final` (printed by step 4), Caddy recreate 2 s (printed by step 5), all with 1,001 documents. Not recorded: the write-blocked window (from `step-2-snapshot.sh --final` to the end of step 5).
