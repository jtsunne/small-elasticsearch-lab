# bad-heap

A deliberately wrong heap for lab test L-M2: `-Xms1536m -Xmx1536m` inside a 2 GiB container. **Not a configuration to copy.** Everything else matches `es-single`, minus Caddy.

**Tested on 2026-10-29**, host `laptop-6c16g-nvme-01` (the author's laptop: Linux, cgroup v2, 6 cores / 12 threads, about 15.5 GiB RAM, Docker 29.9.1, Compose 5.6.0), with Elasticsearch 9.5.5 as pinned in `versions.env`, through the L-M2 load experiment, not through this scenario's `expected.tsv`. `bench/l-m2.sh` started this compose file plus `compose.bench.yaml` as a pair of runs, with the data directory on disk (btrfs), and loaded the same 3,000,000 synthetic documents into each: once as written (1536 MiB heap, label `bad`) and once with `-Xms1g -Xmx1g` (label `control`). It did this twice: with the container's swap left at the Docker default, so the container could swap (`bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-disk/`, bad first), and with swap disabled for the container (`bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-noswap/`, control first). The numbers and the arithmetic are in `results/FINDINGS-2026-10-29.md`, section "Page 1: sizing", L-M2. An earlier pair with the data directory on tmpfs (`bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/`) is superseded, see below. One laptop run per heap is one data point, not a reference.

`make test SCENARIO=bad-heap` did not run that day: this scenario has no `init-env.sh`, so the runner stops without `.env` (copy `.env.example` first, see "Run"). The heap the node reported in the experiment, 1610612736 bytes, is what row `bad-heap-02` asserts (`bad-heap.json` in the evidence directory).

## Why it is wrong

Elasticsearch sizes the heap at half of container memory for a data node, 1 GiB here, and leaves the rest for direct buffers, metaspace, thread stacks, code cache and the filesystem cache that Lucene reads through (https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod). With 1.5 GiB of heap, about 512 MiB remain for all of that.

## Outcome

Before the run, two outcomes were possible:

1. **OOM kill.** Heap plus off-heap memory crosses 2 GiB under bulk load and the kernel kills the JVM: `docker inspect` shows `"OOMKilled": true`, the container restarts or stays down. **Observed for bulk ingest with swap disabled** for the container; **refuted for bulk ingest with swap available**.
2. **Cache starvation without a kill.** The cgroup reclaims file cache first, so the node survives but gets slower: low `file` in `memory.stat`, higher latency than with a 1 GiB heap. **Observed for bulk ingest with swap available**, where the node also swapped; the query side is open.

Which one happens depends on swap. With swap, degradation; without swap, an OOM kill within seconds of the first load. The heap is 75% of the container's memory and is resident from startup (`-Xms` equal to `-Xmx`, `-XX:+AlwaysPreTouch`, `bootstrap.memory_lock`), so the container starts at its limit: in the swap-disabled run it sat at 98.9% of its 2 GiB before the first bulk request was acknowledged.

### With swap disabled

OBSERVED 2026-10-29, `LM2_SWAP=off` (`mem_limit` and `memswap_limit` both 2g, `memory.swap.max` 0 inside the container), data directory on disk, same load, one run per heap, control first:

- The 1536 MiB heap was OOM-killed: `OOMKilled` true, exit code 137, 13.8 s after the load started. 58,000 documents were acknowledged before; the loader counted the remaining 2,942,000 as `transport_error`. Its docs/s figure (645.8) is an artefact of the dead node, not a throughput.
- Memory at the first sample, in the second the load started: `anon` 2,112,102,400 bytes (98.4% of 2,147,483,648), cgroup usage from node stats 2,123,268,096 bytes (98.9%), 23.1 MiB left. Ten seconds later usage was 99.9% (1.4 MiB left), `heap_used_percent` had gone from 30 to 52, `max` in `memory.events` was 240, and no young GC had run between the two samples. The next sample found the container gone.
- The 1 GiB control completed: 9,161.9 docs/s, p99 1,579.9 ms, no OOM kill, 52 young GCs taking 859 ms in total, no old GC, `swapcached` and swap 0 throughout.

### With swap available

OBSERVED 2026-10-29, Docker's default swap for the container (host `vm.swappiness` 150), data directory on disk, bulk load only (2 clients, bulk size 1000, dynamic mapping, about 1.3 GiB of index), one run per heap, bad first:

- No OOM kill: `OOMKilled` false, 0 restarts, `oom_kill` 0 in `memory.events`, every document accepted, no 429, in both runs.
- The node was slower: 6,453.8 docs/s against 9,091.1 with the 1 GiB heap (29% lower), wall time 464.8 s against 330.0 s, p99 bulk latency 2,320.1 ms against 831.1 ms (2.8 times), maximum 6,953.0 ms against 4,202.1 ms; the median was the same (178.1 against 179.3 ms).
- It was starved of memory outside the heap: `file` in `memory.stat` stayed at or below 154.5 MiB against up to 509.6 MiB (0.30 times), the cgroup hit its limit (`max` in `memory.events`) 54,631 times against 17,117 (3.2 times), and up to 178.1 MiB of memory outside the locked heap went to swap, which the control run never used. Part of the 154.5 MiB of `file` may be swap cache rather than index data (see the findings file).
- No GC pressure was logged: neither full container log has a `[gc]` overhead or collection line. The GC monitor logs only above its thresholds, and GC time was not sampled.

So for ingest with swap available the mechanism observed is memory pressure outside the heap (page cache reclaim and swapping), not GC. Whether part of the bad run's `file` was swap cache was not sampled in that run; it does not change the conclusion, since without swap the same configuration was killed.

The p99 comparison is weak: the 1 GiB control's p99 was 831.1 ms in the swap-default pair and 1,579.9 ms in the swap-disabled pair (1.9 times) with the same throughput (0.8% apart), so a factor of about 1.9 in p99 is run-to-run noise on this laptop. The 29% throughput loss and the OOM kill are well outside it.

Limits, both settings: one run per configuration and order on one laptop, the node on 1 CPU, thermal and filesystem state not controlled; synthetic 670-byte documents with dynamic mapping; ingest only. Latency under search load with this heap, the part of outcome 2 that matters most for queries, has not been measured. Only 1536 MiB in 2 GiB was tested; whether a smaller overshoot (for example 1280m) also fails or degrades is not known.

The earlier tmpfs-backed pair is kept only as a method warning: with the data directory on tmpfs the index lived in RAM and counted under `file` in the container's own memory, so its memory figures do not show page cache, and its throughput (11,998 and 18,764 docs/s) and GC pauses were not reproduced on disk. `bench/l-m2.sh` refuses tmpfs because of it.

The off-heap estimate behind both outcomes (300 to 600 MiB) was FROM TRAINING. The indication from these runs (L-M3, partial): `anon` minus heap was about 480 to 510 MiB with either heap under bulk load, in both pairs; see the findings file.

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

## Reproduce

The two recorded pairs, by `bench/l-m2.sh` (parameters in each directory's `run.txt`; the defaults of the script are the values used). The data directory path was not recorded; use a directory on a disk filesystem, not tmpfs.

```sh
make loader
# swap available (Docker default), bad first: the -disk result
bench/l-m2.sh --out bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-disk --data-dir <dir-on-disk>
# swap disabled for the container, control first: the -noswap result
LM2_SWAP=off LM2_ORDER=control,bad bench/l-m2.sh --out bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-noswap --data-dir <dir-on-disk>
```

A rerun needs a new `--out` directory. The first, tmpfs-backed pair came from an ad hoc predecessor of the script and cannot be reproduced with it, since `l-m2.sh` refuses tmpfs.

`l-m2.sh` brings the node up itself (it needs no `.env`; it generates a password per run), records the loader output, cgroup memory samples, the OOM state and the container log, and removes everything afterwards; see `bench/README.md`. The node publishes no port in `compose.yaml`; `compose.bench.yaml` publishes it on `127.0.0.1:9200` for the loader. The query side of L-M2 is not scripted yet.

## expected.tsv

Same format as `../es-single/README.md`. Three rows: cluster health, heap max equals 1610612736 bytes (proves the bad setting took effect), and a recorded `_nodes/stats` snapshot. The OOM or starvation outcome is not an HTTP check: these rows do not reproduce L-M2, `bench/l-m2.sh` does. Not run yet as a TAP file (see "Tested on" above).
