// Quorum and allocation model for the guide's es-quorum widget: a pure,
// deterministic model of the documented rules for voting configurations,
// master election, shard allocation, cluster health and write availability.
// No DOM, no I/O, no dependencies. It models the rules, not Elasticsearch:
// timing, network partitions, delayed allocation, allocation filtering,
// awareness and disk watermarks are ignored.
//
// Every rule carries a source key into SOURCES and a status:
//   verified  - quoted from the page in SOURCES (read 2026-10-28)
//   model     - a choice the docs leave open; the model picks one deterministically
//   uncertain - from training or not stated by the docs; shown as such
//
// The site copies this file unchanged to assets/js/es/quorum-model.js.

export const MODEL_VERSION = '0.1.0';

export const SOURCES = Object.freeze({
	voting: 'https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-voting',
	discovery_settings: 'https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/discovery-cluster-formation-settings',
	node_roles: 'https://www.elastic.co/docs/deploy-manage/distributed-architecture/clusters-nodes-shards/node-roles',
	small_clusters: 'https://www.elastic.co/docs/deploy-manage/production-guidance/availability-and-resilience/resilience-in-small-clusters',
	health: 'https://www.elastic.co/docs/troubleshoot/elasticsearch/red-yellow-cluster-status',
	bulk_api: 'https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-bulk',
	os_voting: 'https://docs.opensearch.org/latest/tuning-your-cluster/discovery-cluster-formation/voting-configuration/',
	os_quorum: 'https://docs.opensearch.org/latest/tuning-your-cluster/discovery-cluster-formation/voting-quorums/',
	os_settings: 'https://docs.opensearch.org/latest/tuning-your-cluster/discovery-cluster-formation/settings/',
	os_roles_source: 'https://github.com/opensearch-project/OpenSearch/blob/3.9.0/server/src/main/java/org/opensearch/cluster/node/DiscoveryNodeRole.java',
});

export const RULES = Object.freeze({
	voting_config: {
		status: 'verified', src: 'voting',
		text: 'The voting configuration is the set of master-eligible nodes whose votes count; usually all master-eligible nodes in the cluster.',
	},
	odd_size: {
		status: 'verified', src: 'voting',
		text: 'With an even number of master-eligible nodes, one is left out of the voting configuration so that it has an odd size; this does not reduce failure tolerance.',
	},
	odd_size_choice: {
		status: 'model', src: 'voting',
		text: 'The docs do not say which node is left out. The model leaves out the highest id, so which single node loss stops a two-node cluster is a model choice: in reality it can be either.',
	},
	quorum: {
		status: 'verified', src: 'voting',
		text: 'Decisions, including electing a master, need more than half of the nodes in the voting configuration.',
	},
	two_or_fewer: {
		status: 'verified', src: 'voting',
		text: 'With two or fewer master-eligible nodes, they must all remain available.',
	},
	simultaneous: {
		status: 'verified', src: 'voting',
		text: 'Stopping half or more of the voting configuration at the same time leaves the cluster unavailable until enough nodes return.',
	},
	auto_shrink: {
		status: 'verified', src: 'discovery_settings',
		text: 'cluster.auto_shrink_voting_configuration (default true) sheds departed nodes from the voting configuration, as long as it still contains at least 3 nodes.',
	},
	swap_departed: {
		status: 'verified', src: 'voting',
		text: 'A departed voting node is replaced by an available master-eligible node outside the voting configuration, keeping the size.',
	},
	wait_between: {
		status: 'verified', src: 'voting',
		text: 'The voting configuration adjusts after a node leaves; removing nodes one at a time only helps if each adjustment completes first.',
	},
	reconfig_needs_master: {
		status: 'model', src: 'voting',
		text: 'The voting configuration is part of the cluster state, so the model only reconfigures while a master is elected.',
	},
	voting_only_not_master: {
		status: 'verified', src: 'node_roles',
		text: 'A voting-only node votes in elections but is never elected master.',
	},
	voting_only_needs_master: {
		status: 'verified', src: 'node_roles',
		text: 'Only nodes with the master role can be voting-only.',
	},
	tiebreaker: {
		status: 'verified', src: 'small_clusters',
		text: 'Two nodes plus a voting-only tiebreaker survive the loss of either node; the two original nodes should not be voting-only.',
	},
	os_no_voting_only: {
		status: 'verified', src: 'os_roles_source',
		text: 'OpenSearch 3.9.0 has no voting-only role: DiscoveryNodeRole.java at the 3.9.0 tag defines data, ingest, master, cluster_manager, remote_cluster_client, warm and search, and the OpenSearch discovery docs mention none.',
	},
	replica_not_same_node: {
		status: 'verified', src: 'health',
		text: 'A replica is never assigned to the same node as its primary.',
	},
	one_copy_per_node: {
		status: 'uncertain', src: 'health',
		text: 'The model also keeps two replicas of one shard off the same node (from training: the same-shard allocation decider); the cited page only states the primary case.',
	},
	promote_replica: {
		status: 'verified', src: 'health',
		text: 'When the node holding a primary is lost, a replica on another node can replace it.',
	},
	allocation_needs_master: {
		status: 'model', src: 'voting',
		text: 'Promotion and reallocation are cluster state updates, so the model performs them only while a master is elected.',
	},
	health_red: {
		status: 'verified', src: 'health',
		text: 'Red: some primary shards are unassigned.',
	},
	health_yellow: {
		status: 'verified', src: 'health',
		text: 'Yellow: all primaries assigned, some replicas unassigned. A single-node cluster with replicas is always yellow.',
	},
	health_green: {
		status: 'verified', src: 'health',
		text: 'Green: no unassigned shards.',
	},
	health_no_master: {
		status: 'uncertain', src: 'voting',
		text: 'Without a master the model reports no health: the cluster health API depends on the elected master (from training, not stated by the cited pages).',
	},
	no_master_block: {
		status: 'verified', src: 'discovery_settings',
		text: 'cluster.no_master_block defaults to write: without a master, writes are rejected and reads succeed from the last known cluster state, possibly stale.',
	},
	os_no_master_block: {
		status: 'uncertain', src: 'os_settings',
		text: 'OpenSearch documents cluster.no_cluster_manager_block with values all and write, but the page does not state the default; the model assumes write, as in Elasticsearch.',
	},
	wait_for_active_shards: {
		status: 'verified', src: 'bulk_api',
		text: 'wait_for_active_shards defaults to 1, so a write needs only the primary of its shard; missing replicas do not block it.',
	},
});

export const MAX_NODES = 5;
const LIMITS = { primaries: [1, 3], replicas: [0, 2] };

const TERMS = {
	es: { master: 'master', Master: 'Master', product: 'Elasticsearch' },
	os: { master: 'cluster manager', Master: 'Cluster manager', product: 'OpenSearch' },
};

const byId = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export function validateCluster(cluster) {
	const errors = [];
	const err = (field, message) => errors.push({ field, message });
	const c = cluster && typeof cluster === 'object' ? cluster : {};
	if (!['es', 'os'].includes(c.engine)) err('engine', 'engine must be es or os');
	if (!Array.isArray(c.nodes) || c.nodes.length < 1 || c.nodes.length > MAX_NODES) {
		err('nodes', `between 1 and ${MAX_NODES} nodes`);
		return errors;
	}
	const ids = new Set();
	c.nodes.forEach((n, i) => {
		const f = `nodes[${i}]`;
		if (!n || typeof n.id !== 'string' || !/^[a-z0-9-]{1,20}$/.test(n.id)) err(f, 'node id must be 1-20 characters of a-z, 0-9 and -');
		else if (ids.has(n.id)) err(f, `duplicate node id ${n.id}`);
		else ids.add(n.id);
		for (const k of ['master', 'data', 'votingOnly']) {
			if (n && n[k] !== undefined && typeof n[k] !== 'boolean') err(f, `${k} must be true or false`);
		}
		if (n?.votingOnly && !n.master) err(f, `${RULES.voting_only_needs_master.text}`);
		if (n?.votingOnly && c.engine === 'os') err(f, 'OpenSearch has no voting-only role');
	});
	if (!c.nodes.some((n) => n?.master)) err('nodes', `at least one node must be ${TERMS[c.engine]?.master ?? 'master'}-eligible`);
	const idx = c.index ?? {};
	if (!Number.isInteger(idx.primaries) || idx.primaries < LIMITS.primaries[0] || idx.primaries > LIMITS.primaries[1]) {
		err('index.primaries', `primaries must be ${LIMITS.primaries[0]} to ${LIMITS.primaries[1]}`);
	}
	if (!Number.isInteger(idx.replicas) || idx.replicas < LIMITS.replicas[0] || idx.replicas > LIMITS.replicas[1]) {
		err('index.replicas', `replicas must be ${LIMITS.replicas[0]} to ${LIMITS.replicas[1]}`);
	}
	const failures = c.failures ?? [];
	if (!Array.isArray(failures)) err('failures', 'failures must be a list of node ids');
	else {
		const seen = new Set();
		for (const id of failures) {
			if (!ids.has(id)) err('failures', `unknown node ${id}`);
			else if (seen.has(id)) err('failures', `${id} fails twice`);
			seen.add(id);
		}
	}
	if (c.mode !== undefined && !['simultaneous', 'sequential'].includes(c.mode)) err('mode', 'mode must be simultaneous or sequential');
	return errors;
}

// Odd-sizes a list of master-eligible ids by leaving out the highest id
// (rule odd_size_choice).
function oddSized(ids) {
	const sorted = [...ids].sort(byId);
	return sorted.length % 2 === 0 ? sorted.slice(0, -1) : sorted;
}

function reconfigure(config, nodes, up) {
	const live = nodes.filter((n) => n.master && up.has(n.id)).map((n) => n.id).sort(byId);
	const outside = live.filter((id) => !config.includes(id));
	let cfg = config.map((id) => (up.has(id) || outside.length === 0 ? id : outside.shift()));
	const departed = () => cfg.filter((id) => !up.has(id)).sort(byId);
	while (cfg.length > 3 && departed().length) {
		const gone = departed().pop();
		cfg = cfg.filter((id) => id !== gone);
	}
	if (cfg.length % 2 === 0) {
		const drop = departed().pop() ?? [...cfg].sort(byId).pop();
		cfg = cfg.filter((id) => id !== drop);
	}
	return cfg.sort(byId);
}

function elect(nodes, config, up, previous) {
	const live = config.filter((id) => up.has(id)).length;
	const needed = Math.floor(config.length / 2) + 1;
	const quorum = { live, size: config.length, needed };
	if (live < needed) return { master: null, quorum, reason: 'quorum' };
	const candidates = nodes.filter((n) => n.master && !n.votingOnly && up.has(n.id)).map((n) => n.id).sort(byId);
	if (candidates.length === 0) return { master: null, quorum, reason: 'no_candidate' };
	return { master: candidates.includes(previous) ? previous : candidates[0], quorum, reason: null };
}

function initialShards(dataIds, primaries, replicas) {
	const n = dataIds.length;
	const shards = [];
	for (let s = 0; s < primaries; s++) {
		if (n === 0) {
			shards.push({ shard: s, primary: null, replicas: [] });
			continue;
		}
		const primary = dataIds[s % n];
		const rest = [];
		for (let k = 1; k < n && rest.length < replicas; k++) rest.push(dataIds[(s + k) % n]);
		shards.push({ shard: s, primary, replicas: rest });
	}
	return shards;
}

// Promotes a surviving replica of a lost primary, then refills replicas on the
// least loaded live data nodes that hold no copy (ties go to the lower id).
function reallocate(shards, dataIds, up, replicas) {
	const liveData = dataIds.filter((id) => up.has(id));
	const next = shards.map((sh) => {
		const liveReplicas = sh.replicas.filter((id) => up.has(id));
		let primary = sh.primary !== null && up.has(sh.primary) ? sh.primary : null;
		let promoted = false;
		if (primary === null && liveReplicas.length) {
			primary = liveReplicas.shift();
			promoted = sh.primary !== null;
		}
		return { shard: sh.shard, primary, replicas: liveReplicas, promoted };
	});
	const load = new Map(liveData.map((id) => [id, 0]));
	for (const sh of next) {
		for (const id of [sh.primary, ...sh.replicas]) if (id !== null && load.has(id)) load.set(id, load.get(id) + 1);
	}
	for (const sh of next) {
		if (sh.primary === null) continue;
		while (sh.replicas.length < replicas) {
			const holders = new Set([sh.primary, ...sh.replicas]);
			const target = liveData.filter((id) => !holders.has(id))
				.sort((a, b) => load.get(a) - load.get(b) || byId(a, b))[0];
			if (target === undefined) break;
			sh.replicas.push(target);
			load.set(target, load.get(target) + 1);
		}
	}
	return next;
}

function summarize(engine, nodes, up, config, election, shards, replicas, why) {
	const T = TERMS[engine];
	const master = election.master;
	const missing = (sh) => replicas - sh.replicas.filter((id) => up.has(id)).length;
	const isRed = (sh) => sh.primary === null || !up.has(sh.primary);
	const unassignedPrimaries = shards.filter(isRed).length;
	const unassignedReplicas = shards.reduce((n, sh) => n + missing(sh), 0);
	const orphanReplicas = shards.filter(isRed).reduce((n, sh) => n + missing(sh), 0);
	const dataLive = nodes.filter((n) => n.data && up.has(n.id)).length;
	const uncertain = new Set();
	let health = null;
	if (master !== null) {
		health = unassignedPrimaries ? 'red' : unassignedReplicas ? 'yellow' : 'green';
		why.push(health === 'red' ? 'health_red' : health === 'yellow' ? 'health_yellow' : 'health_green');
	} else if (up.size > 0) {
		why.push('health_no_master');
		uncertain.add('health_no_master');
	}
	let writes;
	if (up.size === 0) writes = 'rejected';
	else if (master === null) {
		writes = 'rejected';
		why.push(engine === 'es' ? 'no_master_block' : 'os_no_master_block');
		if (engine === 'os') uncertain.add('os_no_master_block');
	} else if (unassignedPrimaries === shards.length) writes = 'rejected';
	else if (unassignedPrimaries) writes = 'partial';
	else {
		writes = 'accepted';
		if (unassignedReplicas) why.push('wait_for_active_shards');
	}
	const masterEligible = nodes.filter((n) => n.master).length;
	if (masterEligible % 2 === 0) uncertain.add('odd_size_choice');

	const parts = [];
	if (up.size === 0) parts.push('All nodes are down.');
	else if (master) parts.push(`${T.Master}: ${master}.`);
	else if (election.reason === 'quorum') {
		parts.push(`${T.Master}: none, ${election.quorum.live} of ${election.quorum.size} voting nodes live and ${election.quorum.needed} needed.`);
	} else parts.push(`${T.Master}: none, no live ${T.master}-eligible node that is not voting-only.`);
	if (up.size > 0) parts.push(health ? `Health: ${health.toUpperCase()}.` : `Health: not reported without a ${T.master}.`);
	if (writes === 'accepted') parts.push('Writes: accepted.');
	else if (writes === 'partial') parts.push(`Writes: rejected for ${unassignedPrimaries} of ${shards.length} primary shards.`);
	else parts.push(master || up.size === 0 ? 'Writes: rejected.' : `Writes: rejected, no ${T.master}.`);
	if (master && unassignedPrimaries) parts.push(`${unassignedPrimaries} primary ${unassignedPrimaries === 1 ? 'shard has' : 'shards have'} no live copy.`);
	const replicaCount = (n) => `${n} ${n === 1 ? 'replica' : 'replicas'}`;
	if (master && orphanReplicas) parts.push(`${replicaCount(orphanReplicas)} unassigned because the primary has no live copy.`);
	if (master && unassignedReplicas - orphanReplicas) {
		const cause = dataLive <= 1 ? 'no other data node' : 'no other data node is free';
		parts.push(`${replicaCount(unassignedReplicas - orphanReplicas)} unassigned because ${cause}.`);
	}
	if (!master && up.size > 0) parts.push('Reads: served from live shard copies, possibly stale.');

	return {
		nodes: nodes.map((n) => ({ ...n, up: up.has(n.id), inVotingConfig: config.includes(n.id) })),
		votingConfig: [...config],
		quorum: election.quorum,
		master,
		shards: shards.map((sh) => ({
			shard: sh.shard,
			primary: sh.primary !== null && up.has(sh.primary) ? sh.primary : null,
			replicas: sh.replicas.filter((id) => up.has(id)),
			unassignedReplicas: replicas - sh.replicas.filter((id) => up.has(id)).length,
			promoted: Boolean(sh.promoted),
		})),
		health,
		unassignedPrimaries,
		unassignedReplicas,
		writes,
		why: [...new Set(why)],
		uncertain: [...uncertain].sort(),
		text: parts.join(' '),
	};
}

// simulate({ engine, nodes: [{ id, master, data, votingOnly }], index:
// { primaries, replicas }, failures: [ids], mode }) returns the state before
// any failure, the state after each failure (one entry for simultaneous
// mode) and the final state. Errors come back as { field, message }.
export function simulate(cluster) {
	const errors = validateCluster(cluster);
	if (errors.length) return { errors, initial: null, steps: [], final: null };
	const engine = cluster.engine;
	const mode = cluster.mode ?? 'simultaneous';
	const nodes = cluster.nodes.map((n) => ({ id: n.id, master: Boolean(n.master), data: Boolean(n.data), votingOnly: Boolean(n.votingOnly) }))
		.sort((a, b) => byId(a.id, b.id));
	const { primaries, replicas } = cluster.index;
	const dataIds = nodes.filter((n) => n.data).map((n) => n.id);
	const up = new Set(nodes.map((n) => n.id));

	let config = oddSized(nodes.filter((n) => n.master).map((n) => n.id));
	let election = elect(nodes, config, up, null);
	let shards = initialShards(election.master ? dataIds : [], primaries, replicas);
	const baseWhy = ['voting_config', 'quorum', 'replica_not_same_node'];
	if (nodes.filter((n) => n.master).length % 2 === 0) baseWhy.push('odd_size', 'odd_size_choice');
	if (nodes.filter((n) => n.master).length <= 2) baseWhy.push('two_or_fewer');
	if (nodes.some((n) => n.votingOnly)) baseWhy.push('voting_only_not_master', 'tiebreaker');
	if (replicas > 1) baseWhy.push('one_copy_per_node');
	if (engine === 'os') baseWhy.push('os_no_voting_only');
	const initial = summarize(engine, nodes, up, config, election, shards, replicas, [...baseWhy]);

	const steps = [];
	const failures = cluster.failures ?? [];
	const batches = mode === 'sequential' ? failures.map((id) => [id]) : failures.length ? [failures] : [];
	for (const batch of batches) {
		const why = [...baseWhy];
		for (const id of batch) up.delete(id);
		if (batch.length > 1) why.push('simultaneous');
		election = elect(nodes, config, up, election.master);
		if (election.master) {
			const before = config;
			config = reconfigure(config, nodes, up);
			if (before.join() !== config.join()) why.push('auto_shrink', 'swap_departed');
			if (mode === 'sequential') why.push('wait_between');
			const lostPrimary = shards.some((sh) => sh.primary !== null && !up.has(sh.primary));
			shards = reallocate(shards, dataIds, up, replicas);
			if (lostPrimary && shards.some((sh) => sh.promoted)) why.push('promote_replica');
		} else {
			why.push('reconfig_needs_master', 'allocation_needs_master');
		}
		steps.push({ failed: batch, ...summarize(engine, nodes, up, config, election, shards, replicas, why) });
	}
	return { errors: [], initial, steps, final: steps.length ? steps[steps.length - 1] : initial };
}

const PRESET_DEFS = [
	{ id: 'one', label: '1 node', roles: [['m', 'd']], replicas: 0 },
	{ id: 'two-both-master', label: '2 nodes, both master-eligible', roles: [['m', 'd'], ['m', 'd']], replicas: 1 },
	{ id: 'two-one-master', label: '2 nodes, one master-eligible', roles: [['m', 'd'], ['d']], replicas: 1 },
	{ id: 'two-tiebreaker', label: '2 nodes + voting-only tiebreaker', roles: [['m', 'd'], ['m', 'd'], ['m', 'v']], replicas: 1, esOnly: true },
	{ id: 'three', label: '3 nodes', roles: [['m', 'd'], ['m', 'd'], ['m', 'd']], replicas: 1 },
	{ id: 'five', label: '5 nodes', roles: [['m', 'd'], ['m', 'd'], ['m', 'd'], ['m', 'd'], ['m', 'd']], replicas: 1 },
];

// Presets per engine; OpenSearch has no voting-only role (rule os_no_voting_only).
export function presets(engine) {
	const prefix = engine === 'os' ? 'os' : 'es';
	return PRESET_DEFS.filter((p) => engine === 'es' || !p.esOnly).map((p) => ({
		id: p.id,
		label: engine === 'os' ? p.label.replace('master-eligible', 'cluster-manager-eligible') : p.label,
		cluster: {
			engine,
			nodes: p.roles.map((r, i) => ({
				id: `${prefix}0${i + 1}`,
				master: r.includes('m'),
				data: r.includes('d'),
				votingOnly: r.includes('v'),
			})),
			index: { primaries: 1, replicas: p.replicas },
			failures: [],
			mode: 'simultaneous',
		},
	}));
}

const WRITE_RANK = { accepted: 0, partial: 1, rejected: 2 };
const HEALTH_RANK = { green: 0, yellow: 1, red: 2, null: 3 };

function severity(s) {
	return WRITE_RANK[s.writes] * 10 + HEALTH_RANK[String(s.health)];
}

function combos(ids, k, ordered) {
	if (k === 0) return [[]];
	const out = [];
	ids.forEach((id, i) => {
		const rest = ordered ? ids.filter((x) => x !== id) : ids.slice(i + 1);
		for (const tail of combos(rest, k - 1, ordered)) out.push([id, ...tail]);
	});
	return out;
}

function outcomeCell(cluster, k, mode) {
	const T = TERMS[cluster.engine];
	const ids = cluster.nodes.map((n) => n.id);
	if (ids.length < k) return null;
	const runs = combos(ids, k, mode === 'sequential').map((failures) => {
		const s = simulate({ ...cluster, failures, mode }).final;
		const short = s.nodes.every((n) => !n.up)
			? 'all nodes down'
			: `${s.master ? `${T.master} elected` : `no ${T.master}`}, ${s.health ? s.health.toUpperCase() : 'no health'}, writes ${s.writes}`;
		return { failed: failures, master: s.master, health: s.health, writes: s.writes, short, text: s.text, uncertain: s.uncertain, severity: severity(s) };
	});
	const sorted = [...runs].sort((a, b) => b.severity - a.severity);
	const worst = sorted[0];
	const best = sorted[sorted.length - 1];
	const uncertain = [...new Set(runs.flatMap((r) => r.uncertain))].sort();
	return { varies: worst.severity !== best.severity, worst, best, runs, uncertain };
}

// The static table for the no-JS fallback: every preset with the outcomes of
// losing one node and losing two nodes, at once and one at a time, over every
// choice of failed nodes (worst and best case).
export function presetOutcomes(engine) {
	return presets(engine).map((p) => ({
		id: p.id,
		label: p.label,
		nodes: p.cluster.nodes.length,
		replicas: p.cluster.index.replicas,
		healthy: simulate(p.cluster).initial.text,
		loseOne: outcomeCell(p.cluster, 1, 'simultaneous'),
		loseTwoAtOnce: outcomeCell(p.cluster, 2, 'simultaneous'),
		loseTwoOneAtATime: outcomeCell(p.cluster, 2, 'sequential'),
	}));
}
