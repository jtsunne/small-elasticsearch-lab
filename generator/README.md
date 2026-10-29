# generator

Two pure JavaScript modules behind the guide's widgets, with `node --test` tests:

- `configgen.js`: the config generator (`es-config` widget). `generate(inputs, data)` returns the files of one scenario for the chosen engine, size, hostnames, allowlist and routes.
- `quorum-model.js`: the quorum and allocation model (`es-quorum` widget). `simulate(cluster)` applies node failures to a voting configuration and one index and reports master, health, writes and why; `presetOutcomes(engine)` computes the static preset table for the page without JavaScript.

## Contract

- Pure: no DOM, no network, no file system, no clock, no randomness, no dependencies. ES modules.
- Deterministic: the same inputs give the same output, byte for byte. Inputs are never mutated.
- User input never throws. Problems come back as `{ field, message }` entries in `errors` (and `warnings` for valid but questionable input, such as an IPv6 or a documentation-range allowlist entry).
- The site vendors both files unchanged as `assets/js/es/configgen.js` and `assets/js/es/quorum-model.js`; a thin DOM layer there calls them. Change them here, never in the site copy.
- `data` is the site's `data/es.toml` as Hugo hands it to `js.Build` (`hugo.Data.es`). The generator reads `meta.versions_checked`, `meta.companion_tag`, `es.heap.*`, `sysctl.es_max_map_count` and `os.sysctl.max_map_count`. `test/fixtures/data.json` mirrors those keys; keep it in step with the site.

## Config generator

```js
import { generate, defaultInputs } from './configgen.js';
const { files, errors, warnings, notes, tested } = generate(defaultInputs('es', 'single-ui'), data);
// files: { 'compose.yaml': '...', '.env.example': '...', 'Caddyfile': '...', ... }
```

Inputs: `engine` (`es`, `os`), `scenario` (`single`, `single-ui`, `three`; `three` is Elasticsearch only), `memoryGiB` (1 to 64, steps of 0.5), `cpus` (0.5 to 32), `apiHost`, `uiHost`, `allowedCidrs` (array, or a string split on whitespace and commas; IPv4 or IPv6 CIDR with no host bits set), `indexPrefix` (`^[a-z0-9][a-z0-9-]{0,40}$`), `readRoute`, `writeRoute`, `maxBodyMB` (1 to 1024), `apiKeyDays` (1 to 3650, Elasticsearch only). Missing inputs take the engine's tested values (`defaultInputs`).

The output for each tested input set (`TESTED`, the same sets as `test/fixtures/<scenario>.json`) is byte-identical to the files in that scenario directory once the header is removed. The scenario files are the source: when a scenario changes, change the generator until `node --test generator/test/` passes again; do not loosen the test. Scenario files the generator does not produce are lab-only and listed in the test (`README.md`, `expected.tsv`, `compose.bench.yaml`, `bodies/`, `fault-test.sh`); any other new file in a tested scenario fails the test until the generator emits it.

Every file carries a header of `# es-config: ` lines: generator version, data date, and either `tested scenario: <path>@<tag>` (with the inputs that differ from the tested set, if any) or `not a tested combination: <reasons>`. Disabling a route or allowing an IPv6 range makes a combination untested; changing memory, CPUs, hostnames, prefix, body size or key expiry does not, but is named in the header. The header is at the top of every file except shell scripts, where it is at the end: their `--help` prints fixed line ranges of the file.

Scenario `three` reproduces `scenarios/es-three-local`: three nodes on one host, for the lab only, with `cluster.initial_master_nodes` left in because every lab run starts from empty volumes (see that scenario's README before using it anywhere else). There is no OpenSearch three-node scenario, so `engine: 'os'` with `three` is an error.

The generator also reproduces lab-only details of the scenarios, because the byte-identical rule leaves no room to drop them: the test indices `app-a` and `secret` with their seed documents in `setup-roles.sh`, the `README.md`, `make up` and `tests/run-scenario.sh` references in comments, and `versions.env` read from two directories up.

## Quorum model

```js
import { simulate, presets, presetOutcomes, RULES, SOURCES } from './quorum-model.js';
const r = simulate({
  engine: 'es',
  nodes: [{ id: 'es01', master: true, data: true }, { id: 'es02', master: true, data: true }, { id: 'es03', master: true, votingOnly: true }],
  index: { primaries: 1, replicas: 1 },
  failures: ['es01'],
  mode: 'sequential', // or 'simultaneous'
});
r.final.text; // "Master: es02. Health: YELLOW. Writes: accepted. 1 replica unassigned because no other data node."
```

Every step carries `why` and `uncertain`, lists of keys into `RULES`. Each rule has a `status`:

- `verified`: stated on the page in `SOURCES` (read 2026-10-28): voting configuration and odd size, quorum of more than half, auto-shrink to no fewer than 3, swapping a departed voter, voting-only nodes never elected and only with the master role, replica never on its primary's node, red/yellow/green, `cluster.no_master_block` default `write` with possibly stale reads, `wait_for_active_shards` default 1. OpenSearch 3.9.0 has no voting-only role: its `DiscoveryNodeRole.java` at the 3.9.0 tag defines none and its discovery docs mention none, so the model rejects voting-only nodes for OpenSearch and its presets leave out the tiebreaker.
- `model`: the docs leave it open and the model picks: which node an even voting configuration leaves out (the highest id, so the two-node outcomes depend on that choice and are flagged), and that reconfiguration, promotion and reallocation happen only while a master is elected.
- `uncertain`: no health without a master, two replicas of one shard never on the same node, and the OpenSearch `cluster.no_cluster_manager_block` default (its settings page lists the values, not the default).

Ignored on purpose: timing (delayed allocation, the time a reconfiguration takes), network partitions, allocation filtering and awareness, disk watermarks, shard sizes.

## Tests

```sh
node --test generator/test/
```

Needs Node.js 22 or later, `git` (the scenario comparison lists files with `git ls-files`, so ignored local files such as `.env` or generated certificates do not count) and `bash` (every generated shell script is checked with `bash -n`). CI runs the same command in the `node` job.
