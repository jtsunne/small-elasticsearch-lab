import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RULES, SOURCES, presetOutcomes, presets, simulate, validateCluster } from '../quorum-model.js';

const node = (id, roles) => ({ id, master: roles.includes('m'), data: roles.includes('d'), votingOnly: roles.includes('v') });
const cluster = (roles, { engine = 'es', primaries = 1, replicas = 1, failures = [], mode = 'simultaneous' } = {}) => ({
	engine,
	nodes: roles.map((r, i) => node(`${engine}0${i + 1}`, r)),
	index: { primaries, replicas },
	failures,
	mode,
});
const run = (c) => {
	const r = simulate(c);
	assert.deepEqual(r.errors, [], JSON.stringify(r.errors));
	return r;
};
const preset = (id, engine = 'es') => presets(engine).find((p) => p.id === id).cluster;
const lose = (id, failures, mode = 'simultaneous', engine = 'es') => run({ ...preset(id, engine), failures, mode }).final;

test('rules: every rule has a known status and a source; every cited key exists', () => {
	for (const [key, rule] of Object.entries(RULES)) {
		assert.ok(['verified', 'model', 'uncertain'].includes(rule.status), key);
		assert.ok(rule.src in SOURCES, `${key}: ${rule.src}`);
		assert.ok(rule.text.length > 20, key);
		assert.ok(!/[\u2013\u2014]/.test(rule.text), `${key} has an en or em dash`);
	}
	for (const engine of ['es', 'os']) {
		for (const row of presetOutcomes(engine)) {
			for (const cell of [row.loseOne, row.loseTwoAtOnce, row.loseTwoOneAtATime]) {
				for (const r of cell?.runs ?? []) for (const k of r.uncertain) assert.ok(k in RULES, k);
			}
		}
	}
});

test('preset 1 node: green with replicas 0; losing it stops everything', () => {
	const healthy = run(preset('one')).initial;
	// Replicas 0 is the documented way to make a one-node cluster green.
	assert.equal(healthy.health, 'green');
	assert.deepEqual(healthy.votingConfig, ['es01']);
	const down = lose('one', ['es01']);
	// No node is left, so there is nothing to elect and nothing to write to.
	assert.equal(down.master, null);
	assert.equal(down.writes, 'rejected');
	assert.equal(down.text, 'All nodes are down. Writes: rejected.');
});

test('one node with a replica is always yellow', () => {
	const s = run(cluster([['m', 'd']], { replicas: 1 })).initial;
	// health page: "A single-node cluster will always have yellow status."
	assert.equal(s.health, 'yellow');
	assert.equal(s.writes, 'accepted');
	assert.equal(s.text, 'Master: es01. Health: YELLOW. Writes: accepted. 1 replica unassigned because no other data node.');
});

test('preset 2 nodes, both master-eligible: the voting configuration has one node', () => {
	const healthy = run(preset('two-both-master')).initial;
	// odd_size: two master-eligible nodes give a voting configuration of one.
	assert.deepEqual(healthy.votingConfig, ['es01']);
	assert.ok(healthy.uncertain.includes('odd_size_choice'));
	const loseVoter = lose('two-both-master', ['es01']);
	// The only voting node is gone: 0 of 1 is not more than half.
	assert.equal(loseVoter.master, null);
	assert.equal(loseVoter.writes, 'rejected');
	assert.ok(loseVoter.why.includes('no_master_block'));
	const loseOther = lose('two-both-master', ['es02']);
	// Which node is left out is a model choice; here es02 was, so its loss does not matter.
	assert.equal(loseOther.master, 'es01');
	assert.equal(loseOther.health, 'yellow');
	assert.ok(loseOther.uncertain.includes('odd_size_choice'));
});

test('preset 2 nodes, one master-eligible: survives only the loss of the other node', () => {
	const loseMaster = lose('two-one-master', ['es01']);
	// small_clusters: tolerant to the loss of one node but not the other.
	assert.equal(loseMaster.master, null);
	assert.equal(loseMaster.writes, 'rejected');
	const loseData = lose('two-one-master', ['es02']);
	// The master stays; the replica has nowhere to go.
	assert.equal(loseData.master, 'es01');
	assert.equal(loseData.health, 'yellow');
	assert.equal(loseData.writes, 'accepted');
});

test('preset 2 nodes + tiebreaker: survives either data node, never elects the tiebreaker', () => {
	const healthy = run(preset('two-tiebreaker')).initial;
	assert.deepEqual(healthy.votingConfig, ['es01', 'es02', 'es03']);
	const loseFirst = lose('two-tiebreaker', ['es01']);
	// 2 of 3 votes live; es02 is the only electable node.
	assert.equal(loseFirst.master, 'es02');
	assert.equal(loseFirst.health, 'yellow');
	const loseBoth = lose('two-tiebreaker', ['es01', 'es02']);
	// 1 of 3 votes is no quorum, and the tiebreaker could not be master anyway.
	assert.equal(loseBoth.master, null);
	assert.equal(loseBoth.writes, 'rejected');
	const loseTb = lose('two-tiebreaker', ['es03']);
	// The tiebreaker holds no data, so its loss leaves health green.
	assert.equal(loseTb.health, 'green');
});

test('voting-only nodes alone cannot form a master', () => {
	const s = run(cluster([['m', 'd'], ['m', 'v'], ['m', 'v']], { replicas: 0, failures: ['es01'] })).final;
	// 2 of 3 votes are live, but voting_only_not_master leaves no candidate.
	assert.equal(s.quorum.live, 2);
	assert.equal(s.master, null);
	assert.match(s.text, /no live master-eligible node that is not voting-only/);
});

test('preset 3 nodes: survives one loss, not two, in either failure mode', () => {
	for (const id of ['es01', 'es02', 'es03']) {
		const s = lose('three', [id]);
		// 2 of 3 votes; the replica of a lost primary is promoted and a new replica placed.
		assert.notEqual(s.master, null);
		assert.equal(s.health, 'green');
	}
	const promoted = lose('three', ['es01']);
	assert.equal(promoted.shards[0].primary, 'es02');
	assert.ok(promoted.shards[0].promoted);
	assert.ok(promoted.why.includes('promote_replica'));
	// auto_shrink never goes below 3, so one at a time does not help.
	assert.equal(lose('three', ['es01', 'es02'], 'simultaneous').master, null);
	const seq = run({ ...preset('three'), failures: ['es01', 'es02'], mode: 'sequential' });
	assert.deepEqual(seq.steps[0].votingConfig, ['es01', 'es02', 'es03']);
	assert.equal(seq.final.master, null);
});

test('preset 5 nodes: two simultaneous losses keep a master, three do not; one at a time survives three', () => {
	const two = lose('five', ['es03', 'es04']);
	// 3 of 5 votes.
	assert.equal(two.master, 'es01');
	assert.equal(lose('five', ['es01', 'es02', 'es03']).master, null);
	// simultaneous: 2 of 5 votes; sequential: the configuration shrinks to 3 and then keeps 2 of 3.
	const seq = run({ ...preset('five'), failures: ['es01', 'es02', 'es03'], mode: 'sequential' });
	assert.deepEqual(seq.steps.map((s) => s.votingConfig.length), [3, 3, 3]);
	assert.notEqual(seq.final.master, null);
	assert.equal(lose('five', ['es01', 'es02', 'es03', 'es04'], 'sequential').master, null);
});

test('simultaneous vs one at a time differ only through reconfiguration', () => {
	const at = run({ ...preset('five'), failures: ['es02', 'es04', 'es05'], mode: 'simultaneous' });
	const seq = run({ ...preset('five'), failures: ['es02', 'es04', 'es05'], mode: 'sequential' });
	assert.equal(at.steps.length, 1);
	assert.deepEqual(at.steps[0].failed, ['es02', 'es04', 'es05']);
	assert.ok(at.final.why.includes('simultaneous'));
	assert.equal(at.final.master, null);
	assert.equal(seq.steps.length, 3);
	assert.equal(seq.final.master, 'es01');
	assert.ok(seq.final.why.includes('wait_between'));
});

test('no reconfiguration and no reallocation without a master', () => {
	const r = run(cluster([['m', 'd'], ['m', 'd'], ['m', 'd']], { failures: ['es01', 'es02', 'es03'], mode: 'sequential' }));
	assert.notEqual(r.steps[0].master, null);
	assert.equal(r.steps[1].master, null);
	assert.ok(r.steps[1].why.includes('reconfig_needs_master'));
	assert.deepEqual(r.steps[1].votingConfig, r.steps[0].votingConfig);
	assert.equal(r.steps[1].health, null);
	assert.ok(r.steps[1].uncertain.includes('health_no_master'));
});

test('even count: one master-eligible node is left out and swapped in when a voter leaves', () => {
	const four = cluster([['m', 'd'], ['m', 'd'], ['m', 'd'], ['m', 'd']]);
	const healthy = run(four).initial;
	assert.deepEqual(healthy.votingConfig, ['es01', 'es02', 'es03']);
	assert.equal(healthy.nodes.find((n) => n.id === 'es04').inVotingConfig, false);
	// Losing the excluded node changes nothing.
	assert.deepEqual(run({ ...four, failures: ['es04'] }).final.votingConfig, ['es01', 'es02', 'es03']);
	// swap_departed: es04 replaces es01 in the configuration.
	const seq = run({ ...four, failures: ['es01'], mode: 'sequential' });
	assert.deepEqual(seq.final.votingConfig, ['es02', 'es03', 'es04']);
	// voting page: three or four master-eligible nodes tolerate one unavailable node.
	assert.equal(run({ ...four, failures: ['es01', 'es02'] }).final.master, null);
});

test('health: green, yellow and red', () => {
	assert.equal(run(cluster([['m', 'd'], ['m', 'd'], ['m', 'd']])).initial.health, 'green');
	const yellow = run(cluster([['m', 'd'], ['m', 'd'], ['m', 'd']], { replicas: 2, failures: ['es03'] })).final;
	// Two replicas need two other data nodes; one is gone.
	assert.equal(yellow.health, 'yellow');
	assert.equal(yellow.unassignedReplicas, 1);
	assert.equal(yellow.writes, 'accepted');
	assert.ok(yellow.why.includes('wait_for_active_shards'));
	const red = run(cluster([['m', 'd'], ['m', 'd'], ['m', 'd']], { primaries: 3, replicas: 0, failures: ['es02'] })).final;
	// Replicas 0: the primary on es02 has no other copy.
	assert.equal(red.health, 'red');
	assert.equal(red.unassignedPrimaries, 1);
	assert.equal(red.writes, 'partial');
	assert.equal(red.text, 'Master: es01. Health: RED. Writes: rejected for 1 of 3 primary shards. 1 primary shard has no live copy.');
	const allRed = lose('five', ['es01', 'es02']);
	assert.equal(allRed.health, 'red');
	assert.equal(allRed.writes, 'rejected');
	assert.match(allRed.text, /1 replica unassigned because the primary has no live copy\./);
});

test('a replica is never on its primary\'s node, nor two copies on one node', () => {
	const ids = (n) => Array.from({ length: n }, (_, i) => `es0${i + 1}`);
	let checked = 0;
	for (let n = 1; n <= 5; n++) {
		for (let primaries = 1; primaries <= 3; primaries++) {
			for (let replicas = 0; replicas <= 2; replicas++) {
				const base = cluster(Array.from({ length: n }, () => ['m', 'd']), { primaries, replicas });
				const sets = [[], ...ids(n).map((id) => [id]), ...ids(n).flatMap((a, i) => ids(n).slice(i + 1).map((b) => [a, b]))];
				for (const failures of sets) {
					for (const mode of ['simultaneous', 'sequential']) {
						const r = run({ ...base, failures, mode });
						for (const s of [r.initial, ...r.steps]) {
							for (const sh of s.shards) {
								const copies = [sh.primary, ...sh.replicas].filter((x) => x !== null);
								assert.equal(new Set(copies).size, copies.length, JSON.stringify(sh));
								assert.ok(!sh.replicas.includes(sh.primary));
								assert.equal(sh.replicas.length + sh.unassignedReplicas, replicas);
								checked++;
							}
						}
					}
				}
			}
		}
	}
	assert.ok(checked > 1000);
});

test('OpenSearch: no voting-only role, cluster manager wording, uncertain no-master block', () => {
	assert.ok(!presets('os').some((p) => p.id === 'two-tiebreaker'));
	assert.equal(presets('os').length, presets('es').length - 1);
	const bad = validateCluster(cluster([['m', 'd'], ['m', 'd'], ['m', 'v']], { engine: 'os' }));
	assert.ok(bad.some((e) => /no voting-only role/.test(e.message)));
	const s = lose('three', ['os01', 'os02'], 'simultaneous', 'os');
	assert.match(s.text, /^Cluster manager: none/);
	assert.match(s.text, /no cluster manager/);
	assert.ok(s.uncertain.includes('os_no_master_block'));
	assert.ok(run(preset('three', 'os')).initial.why.includes('os_no_voting_only'));
});

test('validation returns structured errors', () => {
	const fields = (c) => validateCluster(c).map((e) => e.field);
	assert.deepEqual(fields(cluster([['m', 'd']])), []);
	assert.ok(fields(undefined).includes('nodes'));
	assert.ok(fields(cluster(Array.from({ length: 6 }, () => ['m', 'd']))).includes('nodes'));
	assert.ok(fields(cluster([['d']])).includes('nodes'));
	assert.deepEqual(fields(cluster([['m', 'd'], ['v', 'd']])), ['nodes[1]']);
	assert.ok(fields(cluster([['m', 'd']], { primaries: 4 })).includes('index.primaries'));
	assert.ok(fields(cluster([['m', 'd']], { replicas: 3 })).includes('index.replicas'));
	assert.ok(fields(cluster([['m', 'd']], { failures: ['es09'] })).includes('failures'));
	assert.ok(fields(cluster([['m', 'd']], { failures: ['es01', 'es01'] })).includes('failures'));
	assert.ok(fields(cluster([['m', 'd']], { mode: 'random' })).includes('mode'));
	assert.ok(fields({ ...cluster([['m', 'd']]), engine: 'solr' }).includes('engine'));
	const dup = cluster([['m', 'd'], ['m', 'd']]);
	dup.nodes[1].id = 'es01';
	assert.ok(fields(dup).includes('nodes[1]'));
	const r = simulate(dup);
	assert.equal(r.final, null);
	assert.ok(r.errors.length);
});

test('preset outcome table: deterministic, one row per preset, worst and best named', () => {
	const es = presetOutcomes('es');
	assert.deepEqual(es, presetOutcomes('es'));
	assert.deepEqual(es.map((r) => r.id), ['one', 'two-both-master', 'two-one-master', 'two-tiebreaker', 'three', 'five']);
	const row = (id) => es.find((r) => r.id === id);
	assert.equal(row('one').loseTwoAtOnce, null);
	assert.equal(row('one').loseOne.worst.short, 'all nodes down');
	assert.equal(row('two-one-master').loseOne.varies, true);
	assert.deepEqual(row('two-one-master').loseOne.worst.failed, ['es01']);
	assert.equal(row('two-one-master').loseOne.worst.short, 'no master, no health, writes rejected');
	assert.equal(row('two-one-master').loseOne.best.short, 'master elected, YELLOW, writes accepted');
	assert.ok(row('two-both-master').loseOne.uncertain.includes('odd_size_choice'));
	assert.equal(row('two-tiebreaker').loseOne.worst.writes, 'accepted');
	assert.equal(row('two-tiebreaker').loseTwoAtOnce.worst.short, 'no master, no health, writes rejected');
	assert.equal(row('three').loseOne.varies, false);
	assert.equal(row('three').loseOne.worst.short, 'master elected, GREEN, writes accepted');
	assert.equal(row('three').loseTwoOneAtATime.worst.short, 'no master, no health, writes rejected');
	assert.equal(row('five').loseTwoAtOnce.worst.short, 'master elected, RED, writes rejected');
	assert.equal(row('five').loseTwoOneAtATime.varies, false);
	assert.equal(row('five').loseTwoOneAtATime.worst.short, 'master elected, GREEN, writes accepted');
	assert.equal(presetOutcomes('os').find((r) => r.id === 'three').loseOne.worst.short, 'cluster manager elected, GREEN, writes accepted');
});
