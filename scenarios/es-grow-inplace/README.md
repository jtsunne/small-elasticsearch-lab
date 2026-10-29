# es-grow-inplace

Growth procedure B: turn the existing single node into the first node of a three-node cluster in place, then add two empty nodes. **Rehearsed in this lab only, not an Elastic-published procedure.** No Elastic page documents converting a node started with `discovery.type: single-node` into a multi-node cluster; the steps below follow the bootstrapping and add-node pages plus the Elasticsearch source, and they stay a hypothesis until the lab run (L-G2) passes.

**B is riskier than A (`es-grow-restore`). Prefer A.** Why:

- B changes the only node that holds the data. Every mistake in B happens to the production copy; in A the old node is never touched and rollback is pointing Caddy back.
- B has a point of no return. Once a second node has joined, shards may have moved to it, and there is no in-place way back to a single node. The way back is a restore from the snapshot taken in step 1, which is procedure A after all.
- Between the first join and the replica change (steps 3 and 4) shards have a single copy each, spread over two or three nodes; losing any node in that window loses data.
- B has two ways to end up with two clusters under one name (a node that bootstraps its own cluster, or a node locked to another cluster's UUID). With Caddy balancing over both, writes would split between them; nothing merges them afterwards.
- es01 switches from development mode to production mode: from step 2 on the bootstrap checks are enforced, and a host that ran the single node fine may refuse to start it.

What B saves: no second copy of the data on disk during the move, no restore, and the application keeps one cluster (same `cluster_uuid`, same API key) throughout. Downtime is one restart of es01.

**Tested on: NOT YET TESTED.** The files pass static checks only: `docker compose config` on all three compose files, `caddy validate`, `bash -n` on every script, `tests/run-scenario.sh --plan-only` and a proxy-only run of the Caddyfile. Nothing has run against a real Elasticsearch yet.

**Lab only.** Three nodes on one host; see `es-three-local`.

## Files

| File | What it is |
|---|---|
| `compose.single.yaml` | the starting state: es01 as `es-single` (single-node discovery, no transport TLS) plus `path.repo`, and Caddy on es01 only. Used by step 0 and `rollback.sh` |
| `compose.yaml` | the state after growth: es01 with seed hosts and transport TLS and without `discovery.type`, es02 and es03 joining, Caddy on all three. Same project name and volumes as `compose.single.yaml`. `make up` and `tests/run-scenario.sh` use this file, so start the procedure with step 0, not with `make up` |
| `compose.traps.yaml` | lab traps L-G3 and L-G4, used only by `trap.sh` |
| `Caddyfile` | as `es-three-local`; the compose file sets `ES_UPSTREAMS` |
| `.env.example`, `init-env.sh` | as `es-single`, plus `SNAPSHOT_DIR` |
| `certs/gen-certs.sh` | transport certificates for es01..es04 (es04 is for L-G3), see `es-three-local` |
| `common.sh` | helpers: compose commands per phase, curl inside a node as `elastic` (password on stdin), the cluster UUID guard |
| `step-0-seed.sh` .. `step-6-verify.sh`, `rollback.sh`, `trap.sh` | the procedure and the traps |
| `expected.tsv` | checks of the end state after step 6 |

## Runbook

Each script prints what it is about to do, checks its preconditions and refuses when they do not hold. The scripts keep two invariants: **es01's data volume is never deleted or replaced**, and **no node that reports a cluster UUID other than the one recorded in step 1 stays running or gets traffic.**

```sh
sudo sysctl -w vm.max_map_count=1048576
cd scenarios/es-grow-inplace
./init-env.sh
./step-0-seed.sh               # es01 single node + Caddy, roles, 1000 docs, app key into .env
./step-1-preflight.sh          # host checks, certificates, UUID recorded, snapshot before-grow
#./trap.sh g4 --confirm        # optional L-G4, only here
./step-2-restart-first.sh      # the one restart: es01 leaves single-node mode
./step-3-add-node.sh es02
./step-3-add-node.sh es03
./step-4-replicas.sh           # replicas 1, green
./step-5-caddy.sh              # Caddy on all three
./step-6-verify.sh
#./trap.sh g3 --confirm        # optional L-G3, only here
../../tests/run-scenario.sh --keep-up es-grow-inplace
```

### Step 0: starting point

es01 from `compose.single.yaml`: `es-single`'s node, plus `path.repo` and the snapshot directory. Template `app` with 0 replicas, role, user, 1000 documents in `app-b`, the app API key in `.env`. Refuses if es02 or es03 runs, because it would restart es01 as a single node under a grown cluster.

### Step 1: preflight (nothing on es01 changes yet)

- `vm.max_map_count` at least 262144, warning below the recommended 1048576. From step 2 es01 runs in production mode: "If Elasticsearch is in production mode, any bootstrap checks that fail will cause Elasticsearch to refuse to start." Production mode means the node can "join a cluster via non-loopback addresses", which a node without `discovery.type: single-node` on a Docker network can. Source: https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks
- Certificates for es01..es04 (generated if `certs/` is empty).
- A warning when a data volume for es02 or es03 already exists.
- Records es01's `cluster_uuid` as `GROW_CLUSTER_UUID` and the per-index document counts as `GROW_SEED_COUNTS` in `.env`. If a different UUID was recorded before, it stops: es01 is not the node the procedure started with.
- Registers the fs repository `grow` and takes snapshot `before-grow` (`app-*` plus the security feature state). This is the only way back after step 3.

### Step 2: restart es01 into cluster mode (data loss risk: low; downtime: yes)

Recreates es01 from `compose.yaml` with the same data volume. What changes:

| Before | After | Why |
|---|---|---|
| `discovery.type: single-node` | removed (default `multi-node`) | in single-node mode the node "will elect itself master, and will not join a cluster with any other node", and it rejects joins: "cannot join node with [discovery.type] set to [single-node] discovery" (source, `Coordinator.java`, v9.5.5). See L-G4 for what happens if it stays |
| no seed hosts | `discovery.seed_hosts: es01,es02,es03` | how the nodes find each other. https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/discovery-cluster-formation-settings |
| transport TLS off | on, with the certificates from step 1 | the one thing a single node let you skip: "Transport SSL must be enabled if security is enabled", enforced in production mode. Settings as `es-three-local` |
| roles unset | `master,data,ingest` | as `es-three-local` |
| `cluster.initial_master_nodes` | **never set**, on any node | the cluster was bootstrapped once already, by es01 in single-node mode (source, `ClusterBootstrapService.java`: single-node mode bootstraps with the node itself as the only voter). Elastic: "Do not configure this setting on nodes joining an existing cluster. Do not configure this setting on nodes which are restarting." https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-bootstrap-cluster |

HYPOTHESIS, from the source, not from a doc page: after the restart es01 keeps its committed cluster UUID and its voting configuration of itself, comes up as a one-node cluster in multi-node mode, and accepts joins. The script fails if the UUID changed, and then nothing else must be started.

Check: the script prints the downtime (stop until es01 answers health again), the unchanged UUID, a voting configuration of 1 and the new discovery and TLS settings. Through Caddy, requests fail during that window; L-G2 asks for this number.

### Step 3: add es02, then es03 (data loss risk: high if done wrong)

Starts one node from `compose.yaml` with an **empty** data volume, and checks that it reports the recorded `cluster_uuid`. A node that has not joined yet reports `_na_`; the script waits up to 60 seconds. If the node reports any other UUID, the script stops it at once.

Why empty: "Once an Elasticsearch node has joined an existing cluster, or bootstrapped a new cluster, it will not join a different cluster. Elasticsearch will not merge separate clusters together after they have formed." A node with an old data path is rejected with "This node previously joined a cluster with UUID [...] and is now trying to join a different cluster with UUID [...]. This is forbidden and usually indicates an incorrect discovery or cluster bootstrapping configuration. Note that the cluster UUID persists across restarts and can only be changed by deleting the contents of the node's data path [...] which will also remove any data held by this node." (source, `JoinValidationService.java`, v9.5.5). The documented fix is to stop the node, wipe its data folder, configure seed hosts without `initial_master_nodes`, and restart it (bootstrapping page above).

What a joining node's data path may contain: nothing from another cluster. Never copy es01's data directory to a new node to save the recovery time: the copy carries es01's node identity and cluster state (FROM TRAINING: duplicate node IDs are rejected), and it is not how shards move; the cluster copies shards itself once the node has joined. `elasticsearch-node detach-cluster` can reset a node's cluster UUID, but Elastic warns "Execution of this command can lead to arbitrary data loss" (https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/node-tool); for an empty new node, wiping is simpler and safe.

Guards: a leftover volume for es02 or es03 makes the script refuse unless `--wipe` is given; `--wipe` deletes only that node's volume, and the script refuses `es01` and `esdata01` outright. es03 is refused until es02 runs. The script refuses while es01 still runs in single-node mode.

Check: `_cat/nodes` lists the node; the voting configuration size is printed. HYPOTHESIS: 1 after es02 joins (two master-eligible nodes, "Elasticsearch leaves one of them out of the voting configuration to ensure that it has an odd size") and 3 after es03 joins. https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-voting

Risk in this window: the template still says 0 replicas, and the cluster may move primaries to the new nodes. Until step 4 is green, losing any node can lose the shards on it. Do not stop es01 while only es01 and es02 are in the cluster: with a voting configuration of one, if that voter is es01, the cluster has no master.

### Step 4: replicas (`step-4-replicas.sh`)

Requires three nodes with the recorded UUID and a voting configuration of 3. Prints `_cat/allocation` (replicas double the space `app-*` needs; the guide's sizing page covers the watermarks), sets the template `app` and the existing `app-*` indices to 1 replica (`index.number_of_replicas` is dynamic: https://www.elastic.co/docs/reference/elasticsearch/index-settings/index-modules), and waits up to 300 seconds for green.

Check: green, each `app-*` shard with copies on two nodes; the time to green is printed.

### Step 5: Caddy (`step-5-caddy.sh`)

Recreates Caddy from `compose.yaml`, which lists all three nodes. Refuses unless all three report the recorded UUID: Caddy must never balance across two clusters. The recreate drops connections for a few seconds; on a real host, edit the Caddyfile and `caddy reload`.

### Step 6: verify (`step-6-verify.sh`)

The L-G2 outcome: the recorded `cluster_uuid` on all three nodes, green with three nodes and a voting configuration of 3, and the same per-index document counts as recorded in step 1 (a difference means the application wrote meanwhile, which is fine outside the lab).

### Rollback (`rollback.sh --confirm`)

Only before step 3: puts es01 back on `compose.single.yaml`. Refuses when es02 or es03 runs, when a data volume for either exists (a second node has run, and shards may have moved to it), or when es01's voting configuration has more than one node. After step 3 there is no in-place rollback: build a single node and restore `before-grow` into it, as in `es-grow-restore`. HYPOTHESIS: es01 accepts `discovery.type: single-node` again while its voting configuration is still only itself.

## Which steps can lose data or form a second cluster

| Step or mistake | Consequence | Guard in the scripts |
|---|---|---|
| Deleting or replacing es01's data volume | everything is gone except the snapshot | no script deletes `esdata01`; `step-3-add-node.sh` and `trap.sh` refuse es01 and `esdata01` by name |
| `cluster.initial_master_nodes` on a joining node (L-G3) | the docs call it a risk: "a future misconfiguration may result in bootstrapping a new cluster alongside your existing cluster. It may not be possible to recover from this situation without losing data." A node that bootstraps itself is a second cluster with the same name | not set in `compose.yaml`; step 3 stops any node with a foreign UUID; step 5 refuses to put Caddy in front of mixed UUIDs |
| A new node with a data path from another cluster | rejected at join ("This node previously joined a cluster with UUID ..."); if it had bootstrapped itself and gets traffic, writes split between two clusters | step 1 warns, step 3 refuses without `--wipe` and checks the UUID after start |
| es01 restarted with seed hosts but still `discovery.type: single-node` (L-G4) | from source: es01 starts, logs periodically "This node is a fully-formed single-node cluster with cluster UUID [...], but it is configured as if to discover other nodes and form a multi-node cluster via the [discovery.seed_hosts=...] setting", and rejects joins | step 3 refuses while es01 reports `discovery.type: single-node` |
| Losing a node between step 3 and green in step 4 | shards that only existed on that node are lost | steps run back to back; step 4 waits for green |
| Stopping half or more of the voters | no master, writes blocked (not data loss) | none; the runbook says so |
| Bootstrap checks fail after step 2 | es01 does not start: downtime, not data loss | step 1 checks `vm.max_map_count`; heap and memory lock settings are unchanged from `es-single` |
| Disk too small for replicas | allocation stops at the watermarks; the cluster stays yellow | step 4 prints `_cat/allocation` first |

## Traps (`trap.sh`, lab only)

| Trap | When | What it does | Expected (HYPOTHESIS) |
|---|---|---|---|
| `g4` (L-G4) | between step 1 and step 2 | recreates es01 from `compose.yaml` plus `compose.traps.yaml`, which puts `discovery.type: single-node` back on top of the seed hosts and TLS; starts es02 for 60 seconds | es01 starts (single-node mode skips production mode) and logs the "fully-formed single-node cluster" warning; es02 is rejected with "cannot join node with [discovery.type] set to [single-node] discovery" and reports no cluster UUID. Afterwards es02 and its volume are removed, and step 2 runs normally |
| `g3` (L-G3) | after step 4 | starts es04 with `cluster.initial_master_nodes: es04` and seed hosts es01..es03 | recorded, not asserted: either es04 bootstraps its own one-node cluster (a different `cluster_uuid`, the dangerous outcome) or it finds the elected master first and joins. The docs only say it is a risk. Afterwards es04 and its volume are removed; es04 never gets traffic |

Both write their log to `results/tests/<date>-es-grow-inplace-L-G3.log` or `-L-G4.log`: the API answers and the matching log lines of the nodes.

## expected.tsv

The end state after step 6. `compose.yaml` describes that state, so the runner's `up --wait` changes nothing but the Caddy allowlist:

```sh
tests/run-scenario.sh --keep-up es-grow-inplace
```

There is no `setup-roles.sh`: the API key from step 0 must still work after growth, and the runner would otherwise create a new one. The key comes from `APP_API_KEY` in `.env`.

| Lab test | Rows | Expected |
|---|---|---|
| L-G2 | node rows on es01 | green with three master-eligible nodes, voting configuration 3, no node in single-node mode, `cluster.initial_master_nodes` set on none, transport TLS on all, `app-a` and `app-b` with 1 replica and copies on two nodes, exactly 1000 documents in `app-b`, template with 1 replica, the API key from step 0 still valid, snapshot `before-grow` present |
| L-G2 | proxy rows | reads through Caddy round robin over three nodes, a bulk write accepted |
| L-N1, L-P1, L-P2, L-P4, L-P20 | as `es-single` | unchanged proxy behaviour |

The same `cluster_uuid` on all three nodes is checked by `step-6-verify.sh`, not by `expected.tsv`: the runner's node rows all go to es01. The es01 restart downtime is printed by step 2.
