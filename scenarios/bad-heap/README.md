# bad-heap

A deliberately wrong heap for lab test L-M2: `-Xms1536m -Xmx1536m` inside a 2 GiB container. **Not a configuration to copy.** Everything else matches `es-single`, minus Caddy.

**Tested on: NOT YET TESTED.** This scenario was not part of the 2026-10-29 lab run (see the top-level README for what ran); its files have had static checks only (`docker compose config`). L-M2 is open, and so is L-M3, which needs the same kind of loaded run.

## Why it is wrong

Elasticsearch sizes the heap at half of container memory for a data node, 1 GiB here, and leaves the rest for direct buffers, metaspace, thread stacks, code cache and the filesystem cache that Lucene reads through (https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod). With 1.5 GiB of heap, about 512 MiB remain for all of that.

## Expected outcome (HYPOTHESIS, to be confirmed or refuted by the lab run)

One of two things, and the run must record which:

1. **OOM kill.** Heap plus off-heap memory crosses 2 GiB under bulk load and the kernel kills the JVM: `docker inspect` shows `"OOMKilled": true`, the container restarts or stays down.
2. **Cache starvation without a kill.** The cgroup reclaims file cache first, so the node survives but query latency turns into disk latency: low `file` in `memory.stat`, higher read I/O and p99 than `es-single` at the same data size.

The page explains the result; it does not get to assume it. The off-heap estimate behind both outcomes (300 to 600 MiB) is FROM TRAINING and is replaced by L-M3.

## Run

```sh
cp scenarios/bad-heap/.env.example scenarios/bad-heap/.env   # set a real password
make up SCENARIO=bad-heap
make test SCENARIO=bad-heap                                  # heap really is 1536 MiB, node stats recorded
LOADER_PASSWORD=... bench/run.sh --engine es --scenario bad-heap ...   # load and queries, see bench/README.md
docker inspect "$(docker compose -p bad-heap ps -q es01)" --format '{{.State.OOMKilled}} {{.RestartCount}}'
make down SCENARIO=bad-heap
```

`bench/run.sh` records cgroup `memory.stat` and the OOM state in its result directory; compare with an `es-single` run on the same host and data size. The node publishes no port in `compose.yaml`; `compose.bench.yaml` publishes it on `127.0.0.1:9200` for the loader.

## expected.tsv

Same format as `../es-single/README.md`. Three rows: cluster health, heap max equals 1610612736 bytes (proves the bad setting took effect), and a recorded `_nodes/stats` snapshot. The OOM or starvation outcome is not an HTTP check and is read from the benchmark records.
