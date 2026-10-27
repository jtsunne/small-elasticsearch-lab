# tests

Scenario and proxy test harness: `lib.sh` (curl helpers, assertions, TAP output), `echo-upstream/` (an HTTP server that logs the raw request line), `proxy-matrix.tsv`, `run-proxy-matrix.sh` and `run-scenario.sh`.

Status: not yet written (plan task T5). The harness is only meaningful against a running scenario behind Caddy, so it is written and checked together with the first scenarios. `make test` refuses to run until `run-scenario.sh` exists.
