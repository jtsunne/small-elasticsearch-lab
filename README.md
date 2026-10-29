# small-elasticsearch-lab

Docker Compose scenarios, tests and benchmarks for running a small Elasticsearch or OpenSearch deployment: one node, or three, on a single modest host. This repository is the companion to the Elasticsearch guide on [miasnychenko.com](https://miasnychenko.com/elasticsearch/). Every configuration the guide shows comes from a scenario here, and every number it quotes comes from a result file here.

Status: work in progress. Seven Elasticsearch and OpenSearch scenarios, including both Elasticsearch growth procedures, ran in a functional lab run on 2026-10-29 and passed every row except one transient row in `es-single-kibana`; `bad-heap` ran as a load experiment (table in section 3). The OpenSearch three-node and growth scenarios are not written yet, and no benchmark series (L-B1 to L-B4) has been run. Sections below that depend on lab results say so.

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
| `es-single` | Elasticsearch | 1 | auth on, no node TLS, Caddy TLS + allowlists | 2026-10-29: 83/83 | Minimal security |
| `es-single-kibana` | Elasticsearch + Kibana | 1 | as above, Kibana behind Caddy | 2026-10-29: 90/91 (row 01 asserted green while Kibana was still creating its indices; the row now waits) | Minimal security |
| `es-three-local` | Elasticsearch | 3 on one host | auth on, transport TLS | 2026-10-29: 30/30, fault test 15/15 | One node or three |
| `es-grow-restore` | Elasticsearch | 1 to 3 | as above | 2026-10-29: steps 0 to 5 all exit 0, end state 22/22 | One node or three |
| `es-grow-inplace` | Elasticsearch | 1 to 3 | as above | 2026-10-29: steps 0 to 6 all exit 0, end state 22/22, traps L-G3 and L-G4 recorded; rehearsed in this lab, not Elastic-published | One node or three |
| `os-single` | OpenSearch | 1 | security plugin, own certificates, HTTPS on the node, Caddy in front | 2026-10-29: 62/62 | Minimal security |
| `os-single-dashboards` | OpenSearch + Dashboards | 1 | as above | 2026-10-29: 70/70 | Minimal security |
| `os-three-local` | OpenSearch | 3 on one host | security plugin, transport TLS | not yet tested | One node or three |
| `os-grow-restore` | OpenSearch | 1 to 3 | as above | not yet tested | One node or three |
| `os-grow-inplace` | OpenSearch | 1 to 3 | as above | not yet tested | One node or three |
| `bad-heap` | Elasticsearch | 1 | deliberately wrong heap | 2026-10-29: L-M2 bulk-load experiment, not OOM-killed, slower than a 1 GiB heap; its own `expected.tsv` not run | Sizing |

"Tested on" counts are rows passed of rows run, from the TAP files in `results/tests/`. All runs on 2026-10-29 used one host, `laptop-6c16g-nvme-01`: the author's laptop, Linux with cgroup v2, 6 cores / 12 threads, about 15.5 GiB RAM, `vm.max_map_count` 1048576, Docker 29.9.1, Compose 5.6.0, and the images pinned in `versions.env` (Elasticsearch 9.5.5, Kibana 9.5.5, OpenSearch 3.9.0, OpenSearch Dashboards 3.9.0, Caddy 2.11.7). The first run that day failed rows because of mistakes in the test rows, the runner and one readiness wait in a setup script, not in the compose files or Caddyfiles; each scenario README lists them and what they turned out to be, and `results/FINDINGS-2026-10-29.md` summarises what the run showed. `es-single` also passed 83/83 in its second heap mode (auto-sizing). The growth procedures and `bad-heap` ran later the same day; their counts are the end-state checks after the procedure, and their READMEs give the step timings and what was not tested.

Each scenario directory has a README with its purpose. Until a scenario has a `compose.yaml`, `make up` refuses to run it.

## 4. Quick start for `es-single`

Prerequisites on the host, beyond section 2: your user can reach the Docker daemon (`docker info` works without sudo), `vm.max_map_count` is at least 1048576, ports 8080 and 8443 on 127.0.0.1 are free (Caddy publishes there with the `.env` that `init-env.sh` writes from `.env.example`; `CADDY_HTTP_PORT` and `CADDY_HTTPS_PORT` change them), and the test client subnets `10.231.1.0/24` and `10.231.2.0/24` do not overlap a network you already use.

```sh
scenarios/es-single/init-env.sh          # writes .env with random passwords, mode 600
make test SCENARIO=es-single             # up, setup, 83 checks, down -v
```

`make test` brings the scenario up, runs `setup-roles.sh`, runs the checks and removes the containers and volumes again. To keep a node to look at instead:

```sh
make up SCENARIO=es-single
scenarios/es-single/setup-roles.sh --key-out /tmp/app-key.env
make down SCENARIO=es-single             # deletes the volumes
```

`scenarios/es-single/README.md` explains every setting, the Caddy rules and how to reach `https://es.localhost:8443` with curl.

## 5. Tests

`make test SCENARIO=<name>` runs `tests/run-scenario.sh <name>`: it creates `.env` with `init-env.sh` when the scenario has one and `.env` is missing, runs `docker compose up --wait`, runs `setup-roles.sh` if present, executes the scenario's `expected.tsv` row by row, prints TAP (one `ok` or `not ok` line per check, with the request and the expected and actual result, and a plan line with the total) and brings the stack down with its volumes. It refuses to start when the Docker daemon is not reachable by your user. `--keep-up` leaves the stack running; `--plan-only` parses `expected.tsv` and prints how each row would run, without Docker.

Requests "from" an allowed or a denied client come from two short-lived client containers on Docker networks `10.231.1.0/24` (allowed) and `10.231.2.0/24` (denied), because Caddy's IP allowlist sees the immediate TCP peer. Override them with `TEST_ALLOWED_SUBNET` and `TEST_DENIED_SUBNET` if they collide with your networks. Rows with site `node` go straight to the node on the compose network, bypassing Caddy. Format and options: `tests/README.md`.

The TAP output is copied to `results/tests/<date>-<scenario>.tap`, and bodies of `record` rows to `results/tests/<date>-<scenario>/`. The growth scenarios are procedures: run their step scripts first, then the runner on the end state, as their READMEs show. `tests/run-proxy-matrix.sh` tests a Caddyfile alone against a local Caddy and an echo upstream, without Docker.

## 6. Benchmarks

Method, summarised from the guide's plan:

- One loader for both engines (`bench/loader`, Go, standard library only): `_bulk` with NDJSON and `_search`, basic auth, bounded retry on 429. See `bench/README.md`.
- Corpora: `http_logs` (logs-style) and `geonames` (search-heavy), downloaded by `bench/fetch-corpus.sh` from the Rally track hosting; they are not redistributed here.
- Size steps of 1, 10 and 30 GB on-disk primary store, three repetitions each, mapping profiles `dynamic`, `keyword` and (Elasticsearch only) `logsdb`.
- Every result directory carries a host record from `bench/host-info.sh`. The host id is a label, never a hostname.

Results: no benchmark series (L-B1 to L-B4) has been run. The one load measurement so far is the L-M2 heap experiment of 2026-10-29 on the author's laptop (`bench/results/2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/`): two runs of 3,000,000 synthetic documents, with its data directory on tmpfs, so it compares two heap sizes and says nothing about disk throughput or sizing. Laptop numbers are affected by thermal throttling and power management; read them as one data point, not as a reference.

To reproduce, see `bench/README.md`. Results from other hosts are welcome as a pull request with the full result directory, including `host.txt`.

## 7. Known limitations and threat model

Not yet written; it follows the proxy test results. The short version that the tests are meant to confirm or refute: Caddy's path allowlist is a speed bump, not access control. Elasticsearch or OpenSearch roles are what stop a request that the proxy lets through, for example a `_bulk` body that names another index.

## 8. Licence

Code, configuration files and scripts: MIT, see `LICENSE`. Results under `bench/results/` and `results/`, and the prose in README files: CC BY 4.0, see `LICENSE-results`. Elasticsearch and Kibana images are under the Elastic License 2.0 and related terms, OpenSearch under Apache 2.0; this repository only references them. Benchmark corpora carry their publishers' licences.
