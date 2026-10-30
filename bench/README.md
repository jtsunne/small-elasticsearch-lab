# bench

Benchmark tooling for the sizing page of the guide. The loader's `bulk` command ran against a real Elasticsearch 9.5.5 node for the first time on 2026-10-29 (L-M2, see "Validation status"); everything else here has been tested against fake HTTP servers only, and `run.sh` has only been exercised with a stubbed `docker` command and a fake node. Benchmark results (L-B1 to L-B4): not yet measured.

| Path | What it is |
|---|---|
| `loader/` | Go, standard library only. `loader bulk` indexes NDJSON through `_bulk`, `loader search` runs a query set through `_search`. Same requests for Elasticsearch and OpenSearch. |
| `queries/` | Fixed query sets per corpus. |
| `mappings/es/`, `mappings/os/` | Create-index bodies, one file per corpus and mapping profile. |
| `fetch-corpus.sh` | Downloads and verifies a corpus into `bench/corpus/` (git-ignored). |
| `host-info.sh` | Prints the host record. |
| `run.sh` | Orchestrates size steps and repetitions, writes a result directory. |
| `l-m2.sh` | Lab test L-M2: the same bulk load into `scenarios/bad-heap` with a too-large and a correct heap, see below. |
| `results/` | One directory per run series, see below. |

## Validation status

Validated against a live engine, 2026-10-29, host `laptop-6c16g-nvme-01`, Elasticsearch 9.5.5, single node with security on: `loader bulk` with basic auth as `elastic`, plain HTTP on `127.0.0.1:9200`, 2 clients, bulk size 1000, NDJSON on stdin (`-input -`), an index created by the first bulk request (no `-mapping`), `-label`, `-out` (one JSON line per request) and `-summary` (CSV). Three pairs of runs of 3,000,000 documents each. In the five runs whose node stayed up: every document accepted, no failed request, no 429, no retry, and `index_docs` in the summary equals `docs.count` from `_cat/indices` afterwards. In the sixth the node was OOM-killed mid-load: the loader counted every later request as `transport_error` documents, kept going until its input ended, exited 0, and reported `index_docs` and `store_bytes` as -1 with the failed calls on stderr. Evidence: `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-disk/` and `-lm2-noswap/` (by `l-m2.sh`) and `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/` (tmpfs, superseded).

Still unvalidated against a live engine: everything on OpenSearch; `loader search` and the query sets; `-mapping`, `-recreate`, `-refresh-interval` and `-setting` (index creation from the profiles below); `-max-store-bytes` and `-max-docs`; `-skip-docs`, `-repeat` and compressed input; `-ca` and `-insecure` (no TLS endpoint was used); the 429 retry path (no 429 happened); `fetch-corpus.sh`; `run.sh`.

The mapping profiles and query sets are **unvalidated**: they parse and their variables resolve (checked by `go test`), but none has been sent to Elasticsearch 9.5.5 or OpenSearch 3.9.0. Points that need a live check:

- `http_logs-logsdb.json` sets `index.mode: logsdb` with `index.mapping.source.mode: stored`, because synthetic `_source` is not available on the free Basic licence. Whether 9.5.5 accepts the explicit `stored` mode together with `logsdb` on Basic is not verified.
- `http_logs` documents carry `@timestamp` as epoch seconds. The `keyword` and `logsdb` profiles map it as `date` with `format: epoch_second`; the `dynamic` profile leaves it to dynamic mapping, which makes it a `long`. The `range-terms-agg` query uses plain numbers so that it works on both; that this holds on both engines is not verified.
- All explicit profiles use `dynamic: strict`, so a document with an unexpected field is rejected and shows up as a `strict_dynamic_mapping_exception` count rather than being indexed silently.
- `index.requests.cache.enable: false` in every profile, so that repeated aggregations measure work, not the shard request cache.
- OpenSearch profiles are the same files as the Elasticsearch ones. OpenSearch has no `logsdb` index mode; no OpenSearch equivalent is offered, and `run.sh` refuses `--mapping logsdb` with `--engine os`.

## l-m2.sh

```sh
make loader
bench/l-m2.sh --out bench/results/<date>-<host-id>-es-9.5.5-lm2 --data-dir /mnt/esbench
```

Lab test L-M2 (plan 5.3): does a 1536 MiB heap in a 2 GiB container get OOM-killed under bulk load, or does it survive and starve? The script starts `scenarios/bad-heap` with `compose.bench.yaml` twice under its own compose project names, once with the "bad" heap and once with the "control" heap, generates the same synthetic documents for both (awk, fixed seed, about 670 bytes each, dynamic mapping, default refresh), loads them with `loader bulk`, and records per label: the heap the node reports (the run stops if it is not the requested one), the loader summary and per-request lines, cgroup memory samples (`anon`, `file`, `shmem`, `file_mapped`, `swapcached`, `memory.events`, `memory.swap.current`, `memory.swap.max`), node stats samples in `<label>-nodestats.jsonl` (see below), the final OOM and restart state, `_cat/indices`, the last 30 container log lines, and the whole container log under `raw/` (git-ignored). `run.txt` holds the parameters, the awk implementation (gawk and mawk generate different documents from the same seed) and the filesystem type of the data directory.

Parameters are environment variables whose defaults are the values of the 2026-10-29 run: `LM2_DOCS` 3000000, `LM2_SEED` 42, `LM2_CLIENTS` 2, `LM2_BULK_SIZE` 1000, `LM2_BAD_HEAP` 1536m, `LM2_CONTROL_HEAP` 1g, `LM2_TIMEOUT` 1500 s, `LM2_SAMPLE_S` 10 s; the node's CPU comes from `BENCH_ES_CPUSET` (default 1) in `compose.bench.yaml`. `l-m2.sh -h` lists them.

Two controls were added after the disk-backed 2026-10-29 run; their defaults reproduce it:

- `LM2_SWAP=default|off` (default `default`). `off` adds `mem_limit: 2g` and `memswap_limit: 2g` for `es01` to the generated override, so the container gets no swap. The Compose spec states that `memswap_limit` equal to `mem_limit` means the container has no access to swap; on cgroup v2, runc writes `memswap_limit` minus `mem_limit` to `memory.swap.max`, which gives 0. The script does not rely on that: it reads `memory.swap.max` inside the container at the start of each run, writes it to `run.txt` (`<label>_memory_swap_max`), and stops if `LM2_SWAP=off` and the value is not 0.
- `LM2_ORDER=bad,control|control,bad` (default `bad,control`), the order of the two runs.

`run.txt` also records `order`, `LM2_SWAP`, the host's `vm.swappiness` and one `swap_device` line per `swapon --show` entry. Every `LM2_SAMPLE_S` seconds during the load, and once more after it, the script asks the node for `GET /_nodes/stats/jvm,os` filtered to the young and old GC collection counts and times, `heap_used_percent` and `os.cgroup.memory` (if the node reports it), as `elastic` with the password on curl's stdin, and writes one JSON line per attempt to `<label>-nodestats.jsonl`. An attempt the node does not answer is a line with `"ok":false`, the curl exit code and the HTTP status, not a gap. At the end of each run `run.txt` gets the number of answered and unanswered samples and the young and old GC count and time deltas over the answered samples (a counter reset, from a restarted JVM, is noted). If the node is OOM-killed during the load, the loader records transport errors until its input ends or `LM2_TIMEOUT` stops it, the samplers record the failures, the final state and logs are captured as usual, and the script goes on with the next configuration.

What the swap-disabled rerun controlled for: the disk run had the bad run swap up to 178 MiB while the control run never swapped, could not tell page cache from swap cache because `swapcached` was not sampled, always ran bad first, and had no GC data during the load because the node logs nothing below the GC monitor's thresholds. With `LM2_SWAP=off` the bad heap can no longer move memory to swap, so the difference to the control run is page cache reclaim, GC and an OOM kill if one happens; `swapcached` separates swap cache from page cache in `file`; `LM2_ORDER=control,bad` reverses the order of the first pair, which exposes an order effect (thermal state, btrfs state) if the result moves; the node stats lines give GC counts and times sampled during the load. It is still one run per configuration on one laptop. The rerun, as run (the data directory path was not recorded):

```sh
LM2_SWAP=off LM2_ORDER=control,bad bench/l-m2.sh --out bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-noswap --data-dir <dir-on-disk>
```

Its outcome: the bad heap was OOM-killed 13.8 s into the load, the control completed; see `results/FINDINGS-2026-10-29.md`, L-M2.

It refuses to start, listing everything missing, without Linux and cgroup v2, a reachable Docker daemon and Compose v2, the loader binary, `vm.max_map_count` of 1048576, a free `127.0.0.1:9200`, a new `--out` directory, and a `--data-dir` that is writable and not on tmpfs or ramfs. The first 2026-10-29 pair kept its data on tmpfs, which put the index files into the container's memory accounting; the script exists so the run could be repeated on a disk. The data directory must be writable by uid 1000 or gid 0 inside the container (see `scenarios/es-single/README.md`).

The `elastic` password is generated per run, kept in a mode 600 file inside a private temporary directory for compose, passed to curl on stdin and to the loader through `LOADER_PASSWORD`, and removed on exit. On exit, normal or not, the script also removes its containers, networks and the two data directories (keep them with `--keep-data`).

Status: ran end to end twice, 2026-10-29 on `laptop-6c16g-nvme-01` with the data directory on btrfs: `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-disk/` (defaults, before `LM2_SWAP`, `LM2_ORDER` and the node stats sampler existed) and `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-noswap/` (`LM2_SWAP=off LM2_ORDER=control,bad`); findings in `results/FINDINGS-2026-10-29.md`. The second run exercised the additions live against Docker and Elasticsearch 9.5.5: `memory.swap.max` read 0 inside both containers, the order was honoured, `swapcached` and `memory.swap.max` were sampled, and the node stats sampler recorded GC counters under the collector names `young` and `old`, `heap_used_percent` and `os.cgroup.memory`, with the summary in `run.txt`. The mid-run OOM path also ran for real: the bad node was OOM-killed during the load, the loader counted transport errors until its input ended, the samplers recorded the unanswered attempts (`"ok":false`, curl exit 7), and the script recorded the final state (`oom=true`, exit 137), the logs and the failed `_cat/indices`, removed the containers and networks, and finished cleanly. Not exercised yet: a counter reset from a restarted JVM (the node did not restart), mawk. It writes no `host.txt`; capture one with `host-info.sh` next to the run. The earlier pair in `bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/` came from its ad hoc predecessor with the data on tmpfs and is kept only as a method anti-example.

## Corpora

`fetch-corpus.sh http_logs --accept-terms` or `fetch-corpus.sh geonames`. File names, document counts and sizes are taken from the official Rally track definitions; the files are downloaded from `https://rally-tracks.elastic.co`. Each file is checked for compressed size, then SHA-256, then decompressed size and line count.

Neither project publishes content checksums. The first download must be run with `--record-checksums`, which writes `bench/corpus.sha256` (trust on first use); commit that file, and every later download is verified against it.

`http_logs` licence: the OpenSearch benchmark project removed its hosted copy pending a data-licence review; the Rally hosting still served it on 2026-10-26. The data comes from the 1998 World Cup web server logs under a Hewlett-Packard copyright notice. Check the terms before using it, which is why the script asks for `--accept-terms`. `geonames` is CC BY 3.0.

Corpus sizes: `http_logs` is about 33.4 GB of raw JSON in seven files, `geonames` 3.55 GB in one. On-disk size after indexing is not raw size, so the 30 GB step may not be reachable with one pass of `http_logs`; `run.sh` records when a step ran out of corpus. `--repeat N` reads the corpus N times; this is synthetic replication (identical documents again, with new auto-generated ids), and any result that uses it must say so.

## Loader

```sh
cd bench/loader && go build -o loader .
export LOADER_PASSWORD=...
./loader bulk -url http://127.0.0.1:9200 -user elastic -index bench-http_logs \
  -mapping ../mappings/es/http_logs-keyword.json -recreate -refresh-interval 30s \
  -input ../corpus/http_logs/documents-181998.json -bulk-size 1000 -clients 1 \
  -max-store-bytes 1000000000 -out bulk.jsonl -summary summary.csv
./loader search -url http://127.0.0.1:9200 -user elastic -index bench-http_logs \
  -queries ../queries/http_logs.json -concurrency 4 -duration 5m -warmup 30s \
  -out search.jsonl -summary summary.csv
```

`-ca FILE` trusts a lab CA, `-insecure` skips verification. Run `loader bulk -h` and `loader search -h` for all flags.

Definitions, so results can be read without the code:

- **Service time**: from writing the request to reading the whole response body, for the final attempt. Time spent in 429 backoff is not included. p50, p90 and p99 use the nearest-rank method over successful requests only; failed requests are counted by type instead.
- **docs/s, bytes/s**: documents accepted by the engine and their source bytes (without bulk action lines), divided by the wall time of the load.
- **429 handling**: a whole-request 429 is retried by the client with exponential backoff (100 ms doubling, capped at 5 s), at most `-max-retries` times. Item-level 429s inside a `_bulk` response are retried for those documents only, with the same bound. Every 429 is counted (`http_429`, `item_429`); documents still rejected after the last retry count as `es_rejected_execution_exception`.
- **Error types**: the `error.type` of the item or response where there is one, prefixed with `http_<status>/` for whole-request failures; `transport_error` for connection failures and timeouts; `malformed_response` for bodies that do not parse or do not match the request; `shard_failure/<type>` and `timed_out` for partial search results, which count as failures because their service time is not comparable. A circuit breaker trip shows up as `http_429/circuit_breaking_exception`.
- **Stop on store size**: `-max-store-bytes` polls `GET <index>/_stats/store` every `-store-poll` (5 s) and stops reading input when the primary store reaches the target, so it overshoots by up to one poll interval of ingest. Merges change the store size continuously, and unrefreshed data is not counted until the next refresh.

Output: one JSON line per request with `-out`, one CSV row per run (and per query for `search`, plus an `all` row) with `-summary`, and the same summary as JSON on stdout.

## run.sh

```sh
bench/run.sh --engine es --host-id laptop-6c16g-nvme-01 --host-class laptop --data-fs /mnt/esbench
bench/run.sh --engine es --host-id laptop-6c16g-nvme-01 --data-fs /mnt/esbench --mode sweep --reps 3
```

`steps` mode (default) runs, for each repetition on a freshly reset cluster: ingest to 1, 10 and 30 GB of primary store with fixed bulk size, clients and refresh interval (L-B1), and after each step the query set at each concurrency level for the given duration (L-B2), with an optional cold-cache pass (`--cold`: container restart, plus `drop_caches` only if passwordless sudo is available, recorded either way). `sweep` mode runs the L-B1 sweep: bulk size 100, 500, 1000 and 5000, one and two clients, refresh 1 s and 30 s, each to `--sweep-gb` GB on a recreated index. The mixed load (L-B3) and the disk expansion series (L-B4) are not automated yet.

`run.sh` refuses to start and lists every missing prerequisite: Linux with cgroup v2, a reachable Docker daemon, Compose v2, `vm.max_map_count` (1048576 for Elasticsearch, 262144 for OpenSearch), a dedicated, writable filesystem mounted exactly at `--data-fs` and not on the root device, AC power if the host has a battery, the scenario's compose files, the corpus, the mapping profile, `LOADER_PASSWORD`, and `curl`, `jq`, `findmnt`, `sha256sum`.

Contract with the scenarios: next to `compose.yaml`, a scenario used for benchmarks provides `compose.bench.yaml`, an override that publishes the node on `127.0.0.1` only and stores its data under `$BENCH_DATA_DIR` (set by `run.sh` to `<data-fs>/bench-<engine>`). The benchmark talks to the node directly, not through Caddy, so proxy overhead is not part of the numbers. No scenario has this file yet.

Isolation is the operator's job and is recorded, not enforced: pin the node with `cpuset` in the bench override, pin the loader to other cores with `--loader-cpus`, close everything else. On a laptop, plug in power and expect thermal throttling; `host.txt` records the governor, turbo state and power supply.

## Result directory

`bench/results/<date>-<host-id>-<engine>-<version>/`:

| File | Content |
|---|---|
| `host.txt` | host record from `host-info.sh`, captured after the first cluster start so that JVM and processor details are included |
| `run.txt` | parameters, start and end time, corpus exhaustion and cold-run notes |
| `inputs.sha256` | SHA-256 of the compose files, `versions.env`, mapping profile and query set |
| `summary.csv` | one row per loader run |
| `stats/<tag>/` | `_nodes/stats`, `_cat/indices`, `_cat/segments`, container OOM state, cgroup `memory.stat`, `cpu.stat`, `io.stat` |
| `raw/` | per-request JSON lines and loader stdout; git-ignored because of size |
