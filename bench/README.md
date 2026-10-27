# bench

Benchmark tooling for the sizing page of the guide. Nothing here has been run against a real cluster yet: the loader is tested against fake HTTP servers only, and `run.sh` has only been exercised with a stubbed `docker` command and a fake node. Results: not yet measured.

| Path | What it is |
|---|---|
| `loader/` | Go, standard library only. `loader bulk` indexes NDJSON through `_bulk`, `loader search` runs a query set through `_search`. Same requests for Elasticsearch and OpenSearch. |
| `queries/` | Fixed query sets per corpus. |
| `mappings/es/`, `mappings/os/` | Create-index bodies, one file per corpus and mapping profile. |
| `fetch-corpus.sh` | Downloads and verifies a corpus into `bench/corpus/` (git-ignored). |
| `host-info.sh` | Prints the host record. |
| `run.sh` | Orchestrates size steps and repetitions, writes a result directory. |
| `results/` | One directory per run series, see below. |

## Validation status

The mapping profiles and query sets are **unvalidated**: they parse and their variables resolve (checked by `go test`), but none has been sent to Elasticsearch 9.5.5 or OpenSearch 3.9.0. Points that need a live check:

- `http_logs-logsdb.json` sets `index.mode: logsdb` with `index.mapping.source.mode: stored`, because synthetic `_source` is not available on the free Basic licence. Whether 9.5.5 accepts the explicit `stored` mode together with `logsdb` on Basic is not verified.
- `http_logs` documents carry `@timestamp` as epoch seconds. The `keyword` and `logsdb` profiles map it as `date` with `format: epoch_second`; the `dynamic` profile leaves it to dynamic mapping, which makes it a `long`. The `range-terms-agg` query uses plain numbers so that it works on both; that this holds on both engines is not verified.
- All explicit profiles use `dynamic: strict`, so a document with an unexpected field is rejected and shows up as a `strict_dynamic_mapping_exception` count rather than being indexed silently.
- `index.requests.cache.enable: false` in every profile, so that repeated aggregations measure work, not the shard request cache.
- OpenSearch profiles are the same files as the Elasticsearch ones. OpenSearch has no `logsdb` index mode; no OpenSearch equivalent is offered, and `run.sh` refuses `--mapping logsdb` with `--engine os`.

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
bench/run.sh --engine es --host-id laptop-6c32g-nvme-01 --host-class laptop --data-fs /mnt/esbench
bench/run.sh --engine es --host-id laptop-6c32g-nvme-01 --data-fs /mnt/esbench --mode sweep --reps 3
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
