# results

One directory per benchmark series, written by `bench/run.sh` (L-M2: by `bench/l-m2.sh`); layout in `bench/README.md`. Licensed CC BY 4.0, see `LICENSE-results`.

| Directory | What it is |
|---|---|
| `2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2-disk/` | Lab test L-M2, the result: the same synthetic bulk load into `scenarios/bad-heap` with a 1536 MiB heap and a 1 GiB heap, by `bench/l-m2.sh`, data directory on btrfs. No OOM kill; the 1536 MiB heap ingested 29% slower with 2.8 times the p99 bulk latency. `run.txt` with the parameters and pointers, one file per label (`bad-`, `control-`), the per-request files (about 0.5 MB each) at the top level; the full container logs are under `raw/` (git-ignored); no `host.txt`. Findings in `results/FINDINGS-2026-10-29.md` |
| `2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/` | Method anti-example, superseded by the `-disk` directory above: the same L-M2 load by the predecessor of `bench/l-m2.sh`, with the data path on tmpfs, so the index lived in RAM inside the container's memory accounting. Do not quote its numbers. Layout of `l-m2.sh`, not of `run.sh`: one file per label (`bad-`, `control-`), `run.txt` with the parameters and the caveats, `host.txt` captured after the run. The per-request files are about 0.5 MB each and are kept at the top level. |

No `run.sh` series (L-B1 to L-B4) has been run yet.
