# bad-heap

A deliberately wrong heap for lab test L-M2: `-Xms1536m -Xmx1536m` inside a 2 GiB container. **Not a configuration to copy.** Everything else matches `es-single`, minus Caddy.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 6 cores / 12 threads, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5 as pinned in `versions.env`, through the L-M2 load experiment, not through this scenario's `expected.tsv`. The experiment (now `bench/l-m2.sh`) started this compose file plus `compose.bench.yaml` twice and loaded the same 3,000,000 synthetic documents into each: once as written (1536 MiB heap, label `bad`) and once with `-Xms1g -Xmx1g` (label `control`). Evidence: `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/`; the numbers and the arithmetic are in `results/FINDINGS-2026-10-29.md`, section "L-M2". One laptop run per heap is one data point, not a reference.

`make test SCENARIO=bad-heap` did not run that day: this scenario has no `init-env.sh`, so the runner stops without `.env` (copy `.env.example` first, see "Run"). The heap the node reported in the experiment, 1610612736 bytes, is what row `bad-heap-02` asserts (`bad-heap.json` in the evidence directory).

## Why it is wrong

Elasticsearch sizes the heap at half of container memory for a data node, 1 GiB here, and leaves the rest for direct buffers, metaspace, thread stacks, code cache and the filesystem cache that Lucene reads through (https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod). With 1.5 GiB of heap, about 512 MiB remain for all of that.

## Outcome

Before the run, two outcomes were possible:

1. **OOM kill.** Heap plus off-heap memory crosses 2 GiB under bulk load and the kernel kills the JVM: `docker inspect` shows `"OOMKilled": true`, the container restarts or stays down.
2. **Cache starvation without a kill.** The cgroup reclaims file cache first, so the node survives but gets slower: low `file` in `memory.stat`, higher latency than with a 1 GiB heap.

OBSERVED 2026-10-29, under bulk load only (2 clients, bulk size 1000, dynamic mapping, about 1.3 GiB of index):

- Outcome 1 did not happen for this load: `OOMKilled` false, 0 restarts, `oom_kill` 0 in `memory.events`, every document accepted, no 429.
- The node was slower and under memory pressure: 11,998 docs/s against 18,764 with the 1 GiB heap (36% lower), p99 bulk latency 1,194 ms against 261 ms (4.6 times), maximum 6,468 ms against 1,117 ms. The cgroup hit its limit (`max` in `memory.events`) 72,644 times against 18,949; `file` in `memory.stat` stayed at or below 174 MiB against up to 619 MiB. The container log shows young GC pauses of 1.5 s and 2.6 s with GC overhead warnings.

Caveats that limit what this shows. The data directory was on tmpfs, so the index files lived in RAM and counted under `file` in the container's own memory accounting; `file` there is not page cache over a disk, and the split between cache starvation and GC pressure is not settled. Only bulk load ran; the query side of outcome 2 (latency under search load) is open. `bench/l-m2.sh` refuses tmpfs and is the way to repeat the experiment on a disk.

The off-heap estimate behind both outcomes (300 to 600 MiB) was FROM TRAINING. The first indication from this run (L-M3, partial): `anon` minus heap was about 490 MiB with either heap; see the findings file.

## Run

The heap check (`expected.tsv`):

```sh
cp scenarios/bad-heap/.env.example scenarios/bad-heap/.env   # set a real password; there is no init-env.sh
make test SCENARIO=bad-heap                                  # heap really is 1536 MiB, node stats recorded
```

The load experiment, L-M2, bad heap against a 1 GiB control on the same host, documents and settings:

```sh
make loader
bench/l-m2.sh --out bench/results/<date>-<host-id>-es-9.5.5-lm2 --data-dir /mnt/esbench
```

`l-m2.sh` brings the node up itself (it needs no `.env`; it generates a password per run), records the loader output, cgroup memory samples, the OOM state and the container log, and removes everything afterwards; see `bench/README.md`. The node publishes no port in `compose.yaml`; `compose.bench.yaml` publishes it on `127.0.0.1:9200` for the loader. The query side of L-M2 is not scripted yet.

## expected.tsv

Same format as `../es-single/README.md`. Three rows: cluster health, heap max equals 1610612736 bytes (proves the bad setting took effect), and a recorded `_nodes/stats` snapshot. The OOM or starvation outcome is not an HTTP check: these rows do not reproduce L-M2, `bench/l-m2.sh` does. Not run yet as a TAP file (see "Tested on" above).
