# results

One directory per benchmark series, written by `bench/run.sh`; layout in `bench/README.md`. Licensed CC BY 4.0, see `LICENSE-results`.

| Directory | What it is |
|---|---|
| `2026-10-29-laptop-6c16g-nvme-01-es-9.5.5-lm2/` | Lab test L-M2: the same synthetic bulk load into `scenarios/bad-heap` with a 1536 MiB heap and a 1 GiB heap, by the predecessor of `bench/l-m2.sh`. Layout of `l-m2.sh`, not of `run.sh`: one file per label (`bad-`, `control-`), `run.txt` with the parameters and the caveats (the data path was on tmpfs), `host.txt` captured after the run. The per-request files are about 0.5 MB each and are kept at the top level. Findings in `results/FINDINGS-2026-10-29.md` |

No `run.sh` series (L-B1 to L-B4) has been run yet.
