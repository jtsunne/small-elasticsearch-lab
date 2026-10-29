# es-three-local

Three Elasticsearch 9.5.5 nodes, es01, es02 and es03, all master-eligible data nodes, with transport TLS between them and the same Caddy in front as `es-single`. Used for the quorum and failure tests of the guide's page 3 (L-T1, L-T2) and as the target topology of the two growth scenarios.

**LAB ONLY. Three nodes on one host give no real fault tolerance.** They share one CPU, one memory pool, one disk and one kernel; when the host goes, all three go. This scenario shows how quorum, master election and replica allocation behave, nothing more. A real three-node cluster needs three hosts, or at least three separate failure domains.

**Tested on 2026-10-29**, host `laptop-6c32g-nvme-01` (the author's laptop: Linux, cgroup v2, 12 logical CPUs, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5 and Caddy 2.11.7 as pinned in `versions.env`. Results: `expected.tsv` 30 of 30 (`results/tests/2026-10-29-es-three-local.tap`); `fault-test.sh` 15 of 15 (`results/tests/2026-10-29-es-three-local-fault.tap`, run with `FAULT_WRITE_TIMEOUT=100`). `fault-test.sh` also passed 15 of 15 with the default 30 s timeout the same day; that TAP is not in `results/`. `certs/gen-certs.sh` ran as part of `make test`.

The first run the same day passed 4 of 29 rows. What the failures turned out to be:

- `es-three-local-01` to `-13` and every row that needs the app key or app user (25 rows): a startup race. `compose up --wait` reported the nodes healthy while the `.security-7` primary was still unassigned, so `setup-roles.sh`'s single health call as `elastic` got 503 `failed to retrieve password hash for reserved user [elastic]`, setup stopped, no app key was created, and the runner did not notice. Fixed: `setup-roles.sh` retries until `READY_TIMEOUT`, and the runner stops when setup fails.
- On a cluster left running after that run, 27 of 29 passed. The two failures were `es-three-local-16` (L-P1, HTTP/2 abort seen as curl exit 92, a runner fix) and `es-three-local-28` (L-P12, `create_doc` rejects the bulk `index` item; the row was split, new row `es-three-local-30`).
- `fault-test.sh` passed 15 of 15 in the first run too, but its L-T2 write check saw no HTTP response and did not record why. The second run recorded the cause, see "Fault tests" below.

Startup of three 1-CPU nodes on this laptop held the host at about 70% CPU (the coordinator's observation during the run, not a recorded measurement).

Not tested: L-T3, L-T4, L-T5 (other topologies), Kibana with three nodes, network partitions, and anything that needs separate hosts.

## Files

| File | What it is |
|---|---|
| `compose.yaml` | es01, es02, es03 (each 1 CPU, 2 GiB, 1 GiB heap) and `caddy` |
| `Caddyfile` | `es-single`'s Caddyfile with three upstreams, round robin and passive health checks |
| `.env.example` | every variable compose needs; copy it or run `init-env.sh` |
| `init-env.sh` | writes `.env` with random alphanumeric passwords, mode 600 |
| `certs/gen-certs.sh` | CA and per-node transport certificates with `elasticsearch-certutil`, run in the pinned image; outputs are git-ignored; refuses to overwrite |
| `setup-roles.sh` | as in `es-single`, but the index template and indices get 1 replica and the script waits for green with 3 nodes. The wait retries 503, 401, 408 and no answer for up to `READY_TIMEOUT` seconds (default 180), one progress line per attempt: in the first lab run (2026-10-29) the nodes were healthy right after `compose up --wait` while the `.security-7` primary was still unassigned, and the first health call as `elastic` got 503 `failed to retrieve password hash for reserved user [elastic]`; seconds later all three nodes were up |
| `fault-test.sh` | L-T1 and L-T2: stops the elected master, then a second node, checks what still works, brings both back; TAP output |
| `expected.tsv` | checks for `tests/run-scenario.sh`: formation, roles, voting configuration, TLS, replica placement, a subset of the proxy rows |
| `bodies/` | request bodies referenced from `expected.tsv` |

There is no `compose.bench.yaml`. Three nodes sharing one host's CPU and disk measure the host, not a three-node cluster, so the benchmark contract of `bench/run.sh` does not apply and `run.sh` refuses this scenario.

## Run

Host prerequisite. With more than one node the cluster runs in production mode and the bootstrap checks are enforced, so a low value stops the nodes from starting:

```sh
sudo sysctl -w vm.max_map_count=1048576
```

```sh
scenarios/es-three-local/init-env.sh
scenarios/es-three-local/certs/gen-certs.sh        # needs Docker; writes certs/*.pem
make up SCENARIO=es-three-local
scenarios/es-three-local/setup-roles.sh --key-out /tmp/app-key.env
make down SCENARIO=es-three-local                  # deletes the volumes

make test SCENARIO=es-three-local                  # expected.tsv; up, setup, checks, down -v
scenarios/es-three-local/fault-test.sh             # L-T1, L-T2; brings the stack up and down itself
```

`make test` runs `certs/gen-certs.sh` itself when `certs/` holds no `.pem`. `fault-test.sh` does the same, and also runs `init-env.sh` when `.env` is missing. The host needs about 7 GiB free for the three nodes (3 x 2 GiB limit) plus Caddy.

## Settings and why

| Setting | Why | Source |
|---|---|---|
| `discovery.seed_hosts: es01,es02,es03` | the addresses of the master-eligible nodes; the port defaults to 9300. Each node lists all three, itself included, so one value serves every node | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/discovery-cluster-formation-settings |
| `cluster.initial_master_nodes: es01,es02,es03` | needed once, to bootstrap a brand-new cluster, with the same list on every node. Elastic: "After the cluster has formed, remove the `cluster.initial_master_nodes` setting from each node's configuration and never set it again for this cluster." It stays here only because every lab run starts from empty volumes, as in Elastic's own compose example. Left in, each node logs at start and every 12 hours "this node is locked into cluster UUID [...] but [cluster.initial_master_nodes] is set to ...; remove this setting to avoid possible data loss caused by subsequent cluster bootstrap attempts" (source, v9.5.5). On a real cluster remove it after the first start | https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-bootstrap-cluster , https://github.com/elastic/elasticsearch/blob/v9.5.5/server/src/main/java/org/elasticsearch/cluster/coordination/ClusterBootstrapService.java |
| `node.roles: master,data,ingest` | all three master-eligible, so the cluster survives the loss of any one; `data` covers every data tier. Unset, a node also gets `ml`, `remote_cluster_client` and `transform`, which a small cluster does not need. Given as one comma-separated string because it is an environment variable; the form works, each node reported exactly `data`, `ingest`, `master` on 2026-10-29 (`es-three-local-03`) | https://www.elastic.co/docs/deploy-manage/distributed-architecture/clusters-nodes-shards/node-roles |
| Three master-eligible nodes | the voting configuration needs a majority; with three, any one may fail. "If there is an even number, Elasticsearch leaves one of them out of the voting configuration to ensure that it has an odd size", and "you must not stop half or more of the nodes in the voting configuration at the same time". New master-eligible nodes join the voting configuration automatically | https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-voting |
| `xpack.security.transport.ssl.enabled: true` | required: "If you enable Elasticsearch security features, unless you have a trial license, you must configure SSL/TLS for internode-communication." Without it a production-mode node refuses to start with "Transport SSL must be enabled if security is enabled." `es-single` could skip this only because `discovery.type: single-node` keeps it out of production mode | https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks |
| `.key`, `.certificate`, `.certificate_authorities` | PEM key, certificate and trusted CA for the transport layer; `client_authentication` stays at its default `required`, so both sides of a connection present a certificate | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/security-settings |
| `verification_mode: certificate` | checks the chain to the CA and the validity dates, not the host name. The default `full` also matches the host name or IP against the certificate, and nodes connect to each other's published IP, which Docker assigns at start. The CA signs nothing but these nodes, so a valid chain identifies a node of this cluster. Elastic's compose example uses the same mode | security settings page above, https://github.com/elastic/elasticsearch/blob/v9.5.5/docs/reference/setup/install/docker/docker-compose.yml |
| `xpack.security.http.ssl.enabled: false` | as in `es-single`: Caddy terminates TLS, and Caddy-to-node traffic stays on the host-local bridge. Elastic lists HTTP TLS as "optional (but recommended)" and transport TLS as "required for multi-node clusters". The token service, whose bootstrap check needs HTTP TLS, defaults to off when HTTP TLS is off | https://www.elastic.co/docs/deploy-manage/security/secure-cluster-communications , security settings page above |
| `ELASTIC_PASSWORD` on every node | the image writes it into the node's keystore as `bootstrap.password`. The entrypoint says it "is only required for the first node in a cluster", but which node first handles the `elastic` user is not known, so all three get the same value, as in Elastic's compose example. Once the `elastic` password is changed through the API it lives in `.security` and the bootstrap password no longer matters | https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/built-in-users , https://github.com/elastic/elasticsearch/blob/v9.5.5/distribution/docker/src/docker/bin/docker-entrypoint.sh |
| `ES_JAVA_OPTS=-Xms1g -Xmx1g`, `ES_HEAP_OPTS` switch | as in `es-single`, see its "Heap modes" section. Production mode enforces "initial heap size [X] not equal to maximum heap size [Y]", which this value passes | bootstrap checks page above |
| `bootstrap.memory_lock`, `memlock: -1`, `nofile 65535` | as in `es-single`; in production mode a failed lock stops the node: "memory locking requested for elasticsearch process but memory is not locked" | bootstrap checks page above |
| Template `app` and test indices with 1 replica | `index.number_of_replicas` is dynamic, default 1. "Elasticsearch will never assign a replica to the same node as the primary shard", so every shard has copies on two different nodes and green is possible | https://www.elastic.co/docs/reference/elasticsearch/index-settings/index-modules , https://www.elastic.co/docs/troubleshoot/elasticsearch/red-yellow-cluster-status |
| `cluster.routing.allocation.same_shard.host` left `false` | it forbids copies on distinct nodes with the same network address; each container has its own address, so it changes nothing here. On real hosts that each run several nodes, set it to `true` | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/cluster-level-shard-allocation-routing-settings |
| Certificate files mounted one by one, `create_host_path: false` | the CA key never enters a container; a missing file makes `up` fail instead of Docker creating an empty directory in its place | Compose file reference, long volume syntax, https://docs.docker.com/reference/compose-file/services/#volumes |

## Certificates

`certs/gen-certs.sh` runs `elasticsearch-certutil` from the pinned image as root in a throwaway container, with the same commands as Elastic's compose example:

```sh
bin/elasticsearch-certutil ca --silent --pem --out ca.zip
bin/elasticsearch-certutil cert --silent --pem --ca-cert ca/ca.crt --ca-key ca/ca.key --in instances.yml --out nodes.zip
```

`instances.yml` lists each node with `dns: [<node>, localhost]` and `ip: [127.0.0.1]`. The script unpacks both archives and writes `ca.pem`, `ca-key.pem`, `es0N.pem` and `es0N-key.pem`. Node keys are owned by you with group 0 and mode 640, because the node process runs as uid 1000, gid 0; the CA key has mode 600 and is never mounted into a container. Certificates are valid for 1095 days, the certutil default. Source: https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/certutil .

The script ran on 2026-10-29 as part of `make test` and the nodes formed a cluster with its certificates (`es-three-local-07`, `-08`). The archive layout (`ca/ca.crt`, `<name>/<name>.crt`) comes from Elastic's compose example and from `CertificateTool.java`, and `unzip` being present in the image from that compose example, not from a run.

A node added later needs a certificate signed by the same CA: run certutil `cert` with `--ca-cert certs/ca.pem --ca-key certs/ca-key.pem` for the new name. The script refuses to run while `certs/` holds any `.pem`, so it never replaces the CA under a running cluster.

## Caddy with three upstreams

The Caddyfile is `es-single`'s, unchanged in structure: one `route`, the IP allowlist first, the raw-URI `expression` matchers, `request_body max_size 20MB`, `respond 404` for everything else. `scenarios/es-single/README.md` explains each part. What differs:

- `ES_UPSTREAMS` holds a space-separated list (default `es01:9200 es02:9200 es03:9200`). Caddy expands `{$VAR}` before it splits the line into tokens, so one variable becomes three upstreams. Checked with `caddy adapt` on Caddy 2.11.7: three `dial` entries, with and without the variable set.
- `lb_policy round_robin` spreads requests over the nodes.
- `lb_try_duration 5s`: when the chosen node does not accept the connection, Caddy tries another. Caddy: "If the connection to the upstream failed, a retry is always allowed"; once a request has reached an upstream, only GET is retried by default, so a `_bulk` is never sent twice. https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- `fail_duration 30s` turns on passive health checks: a failed request keeps that node out of rotation for 30 seconds. There is no `unhealthy_status`: a 503 from a node without a master would otherwise take every node out of rotation at once.
- L-T1: with a node stopped, Caddy kept answering. OBSERVED on 2026-10-29: six searches in a row through Caddy all got 200 with the elected master stopped (fault TAP check 5, in both fault runs). That clients see no error is observed; the mechanism (the stopped service name no longer resolves, Caddy counts a failed connection and retries on another node) is still a HYPOTHESIS, because Caddy's logs were not recorded.

## Fault tests (`fault-test.sh`)

`tests/run-scenario.sh` can only send requests, so stopping nodes lives in this script. It starts the stack with `ALLOWED_CIDRS` set to a client network it creates (`FAULT_CLIENT_SUBNET`, default `10.231.3.0/24`), sends proxy requests from a throwaway container on that network, and node requests through `docker compose exec`, with secrets on stdin as in `setup-roles.sh`. TAP goes to stdout and to `results/tests/<date>-es-three-local-fault.tap`.

| Stage | Check | Expected | Basis |
|---|---|---|---|
| baseline | health, bulk through Caddy, elected master | green, 3 nodes, bulk accepted, master is one of es01..es03 | |
| L-T1: stop the elected master | a survivor reports a new master within 60s | yes; the time is recorded. OBSERVED 2026-10-29: a new master at the first poll after `docker compose stop` returned (0 s, in all three fault runs) | voting page: with three voters, all but one may fail |
| L-T1 | six searches through Caddy | all 200. OBSERVED 2026-10-29 | Caddy retry above |
| L-T1 | bulk create through Caddy | accepted. OBSERVED 2026-10-29 | a majority of voters is present |
| L-T1 | green again within 180s | yes, time recorded. The surviving copy of each shard is primary; a replica of each is rebuilt on the other survivor once `index.unassigned.node_left.delayed_timeout` has passed (FROM TRAINING: default 1m). OBSERVED 2026-10-29: yellow right after the loss (3 or 4 unassigned shards), green 48 to 50 s later in three runs. That clock starts after the six searches and the bulk write, not at the stop, so the time from the stop to green is longer and was not measured; it is consistent with a 1 minute delay but does not prove it. The TAP diagnostic says "after the master change", which overstates where the clock starts | HYPOTHESIS for the delay; the timing is observed |
| L-T2: stop a second node | the last node reports no master within 60s | yes. OBSERVED 2026-10-29, 0 to 1 s | voting page: two of three voters gone |
| L-T2 | cluster health with `master_timeout=5s` | 503. OBSERVED 2026-10-29: 503 `master_not_discovered_exception` | source: the no-master block carries `SERVICE_UNAVAILABLE` |
| L-T2 | search through Caddy | recorded, not asserted. OBSERVED 2026-10-29: 200 with hits, answered by the last node from its local shard copy (`_shards.total` 1, successful 1). `cluster.no_master_block` defaults to `write`: "Read operations succeed, based on the last known cluster configuration. This situation may result in partial reads of stale data" | https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/discovery-cluster-formation-settings |
| L-T2 | bulk create through Caddy | not acknowledged (anything but 200 with `errors: false`); the TAP diagnostics record the curl exit code and its meaning, status, curl `time_total`, wall-clock seconds, curl's error message and the body. Client timeout `FAULT_WRITE_TIMEOUT` (default 30 s). OBSERVED 2026-10-29, settling the earlier open question: Elasticsearch holds the blocked write for about 60 s and then answers 503 `cluster_block_exception` with reason `blocked by: [SERVICE_UNAVAILABLE/2/no master];` (curl exit 0, `time_total` 60.0 s, with `FAULT_WRITE_TIMEOUT=100`, fault TAP check 10). With the default 30 s client timeout the client gives up first and sees nothing: curl exit 28, status 000, 0 bytes, `time_total` 30.0 s. Caddy did not drop the connection. The first run's "no HTTP response" was this client timeout. A client with a timeout under 60 s never learns why its write failed; it only sees a timeout | source v9.5.5: `NoMasterBlockService.java`, `ClusterBlockException.java` |
| recovery | both nodes started again | green with 3 nodes within 300s; the L-T1 write present, the L-T2 write absent; one `cluster_uuid` on all three. OBSERVED 2026-10-29: green 48 to 50 s after the start, all four checks pass | |

## expected.tsv

Format as in `tests/README.md`. Node rows run inside es01, the first `es<N>` service.

| Lab test | Rows | Note |
|---|---|---|
| `L-T0` (formation; a label of this file, not a plan id) | three named nodes; roles exactly `data,ingest,master` on each; voting configuration of 3; an elected master; transport TLS on everywhere; `_ssl/certificates` and the coordination metadata recorded; app-a and secret with copies on two different nodes; all shards recorded | the voting configuration is read from `metadata.cluster_coordination.last_committed_config`. OBSERVED 2026-10-29: the field exists and lists three node ids (`results/tests/2026-10-29-es-three-local/es-three-local-05.json`) |
| `L-M1`, `L-C1` | heap 1 GiB and 1 allocated processor on every node | OBSERVED 2026-10-29 on all three nodes (`es-three-local-09`, `-10`) |
| `L-N1` | 9200 and 9300 closed on the host | no node publishes a port; both refused on 2026-10-29 (`-14`, `-15`) |
| `L-P1`, `L-P2`, `L-P3`, `L-P4`, `L-P7`, `L-P12`, `L-P20` | a subset of `es-single`'s proxy rows | three identical searches in a row go round robin over all three nodes. `L-P12`: a bulk of `create` items (`bodies/bulk-own-create.ndjson`) is accepted; in `bodies/bulk-own.ndjson` the `create` item gets 201 and the `index` item 403, because `create_doc` does not cover the `index` action even without an id (observed 2026-10-29; see `../es-single/README.md`, "`create_doc` and the bulk `index` action"). The full bypass matrix runs in proxy-only mode against this Caddyfile: `tests/run-proxy-matrix.sh scenarios/es-three-local/Caddyfile` |
| L-T1, L-T2 | none | `fault-test.sh` |
| L-T3 (two nodes plus a voting-only tiebreaker), L-T4 (two master-eligible nodes), L-T5 (five nodes, sequential loss) | none | other topologies, not in this scenario |

## What this scenario does not show

- Fault tolerance of real hardware: one host, one disk, one kernel.
- Network partitions: all nodes share one Docker bridge, and nothing here splits it.
- Disk sizing: all copies of the data sit on one disk, and replicas double what each index needs.
- Kibana with three nodes (`elasticsearch.hosts` listing all three).
