# small-elasticsearch-lab

Docker Compose scenarios, tests and benchmarks for running a small Elasticsearch or OpenSearch deployment: one node, or three, on a single modest host. This repository is the companion to the Elasticsearch guide on [miasnychenko.com](https://miasnychenko.com/elasticsearch/). Every configuration the guide shows comes from a scenario here, and every number it quotes comes from a result file here.

Status: work in progress. No scenario has been written or tested yet, and no benchmark has been run. Sections below that depend on lab results say so.

## 1. What this is

What is covered:

- Elasticsearch 9.5.5 and Kibana 9.5.5, OpenSearch 3.9.0 and OpenSearch Dashboards 3.9.0, all from the official images, pinned by tag and digest in `versions.env`.
- Docker Compose only, on one Linux host.
- A single node with authentication on and Caddy in front (TLS, IP allowlist, path allowlist), three nodes on one host for quorum and failure tests, and two procedures for growing from one node to three.
- A proxy bypass test matrix, and a benchmark loader that speaks plain HTTP to both engines.

What is not covered:

- Kubernetes, operators, packages, or managed services.
- Production hardening beyond what each scenario README states. The three-node scenarios run all nodes on one host, which is fine for testing quorum behaviour and useless for availability.
- Head-to-head engine comparisons. Results are published per engine with method and host; differences in defaults make a naive "X is faster than Y" misleading.

## 2. Requirements

- Linux with cgroup v2. cgroup v1 changes memory accounting and is not supported.
- Docker Engine with the Compose v2 plugin. Record the exact versions with `make host-info`.
- `vm.max_map_count` of at least 1048576 for Elasticsearch (OpenSearch documents at least 262144):

  ```sh
  sudo sysctl -w vm.max_map_count=1048576
  echo 'vm.max_map_count=1048576' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
  ```

- Functional tests: about 4 vCPU, 16 GiB RAM and 40 GiB free disk for three 2 GiB nodes plus Kibana, Caddy and test containers (an estimate, not yet confirmed).
- Benchmarks: a dedicated filesystem for the data volume (a separate disk, partition, LVM volume or loop-mounted image). Disk watermarks are percentages of the filesystem that holds the data path, so a Docker volume on the root filesystem reports the whole host disk. `bench/run.sh` refuses to run without one.
- Go (see `bench/loader/go.mod`) to build the loader; `curl`, `jq`, `bzip2`, `sha256sum`.

## 3. Scenarios

| Scenario | Engine | Nodes | Security model | Tested on | Guide page |
|---|---|---|---|---|---|
| `es-single` | Elasticsearch | 1 | auth on, no node TLS, Caddy TLS + allowlists | not yet tested | Minimal security |
| `es-single-kibana` | Elasticsearch + Kibana | 1 | as above, Kibana behind Caddy | not yet tested | Minimal security |
| `es-three-local` | Elasticsearch | 3 on one host | auth on, transport TLS | not yet tested | One node or three |
| `es-grow-restore` | Elasticsearch | 1 to 3 | as above | not yet tested | One node or three |
| `es-grow-inplace` | Elasticsearch | 1 to 3 | as above | not yet tested | One node or three |
| `os-single` | OpenSearch | 1 | security plugin, own certificates, no HTTP TLS on the node, Caddy in front | not yet tested | Minimal security |
| `os-single-dashboards` | OpenSearch + Dashboards | 1 | as above | not yet tested | Minimal security |
| `os-three-local` | OpenSearch | 3 on one host | security plugin, transport TLS | not yet tested | One node or three |
| `os-grow-restore` | OpenSearch | 1 to 3 | as above | not yet tested | One node or three |
| `os-grow-inplace` | OpenSearch | 1 to 3 | as above | not yet tested | One node or three |
| `bad-heap` | Elasticsearch | 1 | deliberately wrong heap | not yet tested | Sizing |

Each scenario directory has a README with its purpose. Until a scenario has a `compose.yaml`, `make up` refuses to run it.

## 4. Quick start for `es-single`

Not available yet: the scenario is not written. Once it is, the steps will be:

```sh
cp scenarios/es-single/.env.example scenarios/es-single/.env   # set the passwords
make up SCENARIO=es-single
make test SCENARIO=es-single
make down SCENARIO=es-single
```

## 5. Tests

The test harness (`tests/`) is not written yet. It will print TAP: one `ok` or `not ok` line per check, with the request, the expected result and the actual result as diagnostics, and a plan line with the total. Results are recorded in `results/tests/<date>.tap` with the versions they were run against.

## 6. Benchmarks

Method, summarised from the guide's plan:

- One loader for both engines (`bench/loader`, Go, standard library only): `_bulk` with NDJSON and `_search`, basic auth, bounded retry on 429. See `bench/README.md`.
- Corpora: `http_logs` (logs-style) and `geonames` (search-heavy), downloaded by `bench/fetch-corpus.sh` from the Rally track hosting; they are not redistributed here.
- Size steps of 1, 10 and 30 GB on-disk primary store, three repetitions each, mapping profiles `dynamic`, `keyword` and (Elasticsearch only) `logsdb`.
- Every result directory carries a host record from `bench/host-info.sh`. The host id is a label, never a hostname.

Results: not yet measured. The first runs will be on the author's laptop, and the host record will say so. Laptop numbers are affected by thermal throttling and power management; read them as one data point, not as a reference.

To reproduce, see `bench/README.md`. Results from other hosts are welcome as a pull request with the full result directory, including `host.txt`.

## 7. Known limitations and threat model

Not yet written; it follows the proxy test results. The short version that the tests are meant to confirm or refute: Caddy's path allowlist is a speed bump, not access control. Elasticsearch or OpenSearch roles are what stop a request that the proxy lets through, for example a `_bulk` body that names another index.

## 8. Licence

Code, configuration files and scripts: MIT, see `LICENSE`. Results under `bench/results/` and `results/`, and the prose in README files: CC BY 4.0, see `LICENSE-results`. Elasticsearch and Kibana images are under the Elastic License 2.0 and related terms, OpenSearch under Apache 2.0; this repository only references them. Benchmark corpora carry their publishers' licences.
