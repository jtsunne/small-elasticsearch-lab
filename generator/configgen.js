// Config generator for the guide's es-config widget: a pure function from
// inputs and the site's data file (hugo.Data.es, data/es.toml) to the files of
// one scenario. No DOM, no I/O, no dependencies; the same inputs always give
// the same bytes. For every tested input set the output equals the committed
// files under scenarios/ once the "# es-config:" header lines are removed;
// generator/test/configgen.test.mjs enforces that.
//
// The site copies this file unchanged to assets/js/es/configgen.js.

export const GENERATOR_VERSION = '0.1.0';
export const HEADER_PREFIX = '# es-config: ';

// The input sets the lab scenarios were written for. Tested-ness is decided by
// structure (engine, scenario, routes, address families); values such as
// memory or hostnames are substitutions and are listed in the header instead.
export const TESTED = Object.freeze({
	'es/single': {
		path: 'scenarios/es-single',
		inputs: {
			engine: 'es', scenario: 'single', memoryGiB: 2, cpus: 1,
			apiHost: 'es.localhost', uiHost: 'kibana.localhost',
			allowedCidrs: ['127.0.0.1/32'], indexPrefix: 'app',
			readRoute: true, writeRoute: true, maxBodyMB: 20, apiKeyDays: 30,
		},
	},
	'es/single-ui': {
		path: 'scenarios/es-single-kibana',
		inputs: {
			engine: 'es', scenario: 'single-ui', memoryGiB: 2, cpus: 1,
			apiHost: 'es.localhost', uiHost: 'kibana.localhost',
			allowedCidrs: ['127.0.0.1/32'], indexPrefix: 'app',
			readRoute: true, writeRoute: true, maxBodyMB: 20, apiKeyDays: 30,
		},
	},
	'es/three': {
		path: 'scenarios/es-three-local',
		inputs: {
			engine: 'es', scenario: 'three', memoryGiB: 2, cpus: 1,
			apiHost: 'es.localhost', uiHost: 'kibana.localhost',
			allowedCidrs: ['127.0.0.1/32'], indexPrefix: 'app',
			readRoute: true, writeRoute: true, maxBodyMB: 20, apiKeyDays: 30,
		},
	},
	'os/single': {
		path: 'scenarios/os-single',
		inputs: {
			engine: 'os', scenario: 'single', memoryGiB: 2, cpus: 1,
			apiHost: 'os.localhost', uiHost: 'dashboards.localhost',
			allowedCidrs: ['203.0.113.10/32', '198.51.100.0/24'], indexPrefix: 'app',
			readRoute: true, writeRoute: true, maxBodyMB: 20, apiKeyDays: 30,
		},
	},
	'os/single-ui': {
		path: 'scenarios/os-single-dashboards',
		inputs: {
			engine: 'os', scenario: 'single-ui', memoryGiB: 2, cpus: 1,
			apiHost: 'os.localhost', uiHost: 'dashboards.localhost',
			allowedCidrs: ['203.0.113.10/32', '198.51.100.0/24'], indexPrefix: 'app',
			readRoute: true, writeRoute: true, maxBodyMB: 20, apiKeyDays: 30,
		},
	},
});

// The tested input set for an engine and scenario, as a fresh copy. A UI that
// switches engine should start from this rather than keep the other engine's
// hostnames and allowlist.
export function defaultInputs(engine = 'es', scenario = 'single') {
	const entry = TESTED[`${engine}/${scenario}`] ?? TESTED['es/single'];
	return structuredClone(entry.inputs);
}

export const DEFAULT_INPUTS = Object.freeze(defaultInputs());

export const ENGINES = ['es', 'os'];
export const SCENARIOS = ['single', 'single-ui', 'three'];

const LIMITS = {
	memoryGiB: { min: 1, max: 64, step: 0.5 },
	cpus: { min: 0.5, max: 32, step: 0.5 },
	maxBodyMB: { min: 1, max: 1024 },
	apiKeyDays: { min: 1, max: 3650 },
	cidrs: 64,
};

// RFC 5737 and RFC 3849 ranges: valid syntax, never a real client.
const DOC_RANGES = ['192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24', '2001:db8::/32'];

// The last label needs a letter, which rules out IPv4 literals: Caddy cannot
// get a public certificate for an IP site address.
const HOSTNAME_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+(?=[a-z0-9-]*[a-z])[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
const PREFIX_RE = /^[a-z0-9][a-z0-9-]{0,40}$/;

// Templates are tagged with t, which reads the raw strings so backslashes in
// the shell scripts stay as written. Only three escapes are interpreted:
// \t (tab), \` and \${. A leading newline after the opening backtick is dropped.
function t(strings, ...values) {
	let out = '';
	strings.raw.forEach((s, i) => {
		const text = s.replace(/\\t/g, '\t').replace(/\\(`|\$\{)/g, '$1');
		out += i === 0 && text.startsWith('\n') ? text.slice(1) : text;
		if (i < values.length) out += values[i];
	});
	return out;
}

function when(cond, text) {
	return cond ? text : '';
}

function isNumberInRange(n, { min, max, step }) {
	if (typeof n !== 'number' || !Number.isFinite(n) || n < min || n > max) return false;
	return step === undefined ? Number.isInteger(n) : Number.isInteger(Math.round(n / step * 1e9) / 1e9);
}

function parseIPv4(s) {
	const parts = s.split('.');
	if (parts.length !== 4) return null;
	const bytes = [];
	for (const p of parts) {
		// Leading zeros are rejected: some parsers read them as octal.
		if (!/^(0|[1-9][0-9]{0,2})$/.test(p) || Number(p) > 255) return null;
		bytes.push(Number(p));
	}
	return bytes;
}

function parseIPv6(s) {
	if (!/^[0-9a-fA-F:.]+$/.test(s)) return null;
	const halves = s.split('::');
	if (halves.length > 2) return null;
	// An embedded IPv4 address may only be the last 32 bits.
	if (halves.length === 2 && halves[0].includes('.')) return null;
	const toWords = (part) => {
		if (part === '') return [];
		const groups = part.split(':');
		const words = [];
		for (let i = 0; i < groups.length; i++) {
			const g = groups[i];
			if (g.includes('.')) {
				const v4 = i === groups.length - 1 ? parseIPv4(g) : null;
				if (!v4) return null;
				words.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
			} else if (/^[0-9a-fA-F]{1,4}$/.test(g)) {
				words.push(parseInt(g, 16));
			} else {
				return null;
			}
		}
		return words;
	};
	const head = toWords(halves[0]);
	const tail = halves.length === 2 ? toWords(halves[1]) : [];
	if (!head || !tail) return null;
	let words;
	if (halves.length === 1) {
		if (head.length !== 8) return null;
		words = head;
	} else {
		if (head.length + tail.length > 7) return null;
		words = [...head, ...Array(8 - head.length - tail.length).fill(0), ...tail];
	}
	return words.flatMap((w) => [w >> 8, w & 255]);
}

// Returns { family, bytes, bits } or { error }.
export function parseCidr(text) {
	const m = /^([^/\s]+)\/([0-9]{1,3})$/.exec(text);
	if (!m) {
		if (parseIPv4(text) || parseIPv6(text)) return { error: `${text} needs a prefix length, for example ${text.includes(':') ? `${text}/128` : `${text}/32`}` };
		return { error: `${text} is not an IPv4 or IPv6 CIDR` };
	}
	const [, addr, bitsText] = m;
	if (bitsText.length > 1 && bitsText.startsWith('0')) return { error: `${text}: prefix length has a leading zero` };
	const bits = Number(bitsText);
	const v4 = parseIPv4(addr);
	const bytes = v4 || (addr.includes(':') ? parseIPv6(addr) : null);
	if (!bytes) return { error: `${text} is not an IPv4 or IPv6 CIDR` };
	const family = v4 ? 4 : 6;
	if (bits > bytes.length * 8) return { error: `${text}: an IPv${family} prefix is at most /${bytes.length * 8}` };
	const masked = maskBytes(bytes, bits);
	if (masked.some((b, i) => b !== bytes[i])) {
		return { error: `${text} has host bits set; the network is ${formatAddr(masked, family)}/${bits}` };
	}
	return { family, bytes, bits };
}

function maskBytes(bytes, bits) {
	return bytes.map((b, i) => {
		const keep = Math.max(0, Math.min(8, bits - i * 8));
		return b & ((0xff << (8 - keep)) & 0xff);
	});
}

function formatAddr(bytes, family) {
	if (family === 4) return bytes.join('.');
	const words = [];
	for (let i = 0; i < 16; i += 2) words.push((bytes[i] << 8) | bytes[i + 1]);
	let best = -1;
	let bestLen = 0;
	for (let i = 0; i < 8;) {
		let j = i;
		while (j < 8 && words[j] === 0) j++;
		if (j - i > bestLen) {
			best = i;
			bestLen = j - i;
		}
		i = j === i ? i + 1 : j;
	}
	const hex = words.map((w) => w.toString(16));
	if (bestLen < 2) return hex.join(':');
	return `${hex.slice(0, best).join(':')}::${hex.slice(best + bestLen).join(':')}`;
}

function cidrContains(outer, inner) {
	if (outer.family !== inner.family || outer.bits > inner.bits) return false;
	const a = maskBytes(inner.bytes, outer.bits);
	return a.every((b, i) => b === outer.bytes[i]);
}

function splitCidrs(value) {
	if (Array.isArray(value)) return value.map((v) => String(v).trim()).filter(Boolean);
	if (typeof value === 'string') return value.split(/[\s,]+/).filter(Boolean);
	return null;
}

function isLabHost(host) {
	return host === 'localhost' || host.endsWith('.localhost');
}

// Normalises and validates user input. Never throws for user input: problems
// come back as { field, message } entries.
export function validate(rawInputs = {}) {
	const errors = [];
	const warnings = [];
	const err = (field, message) => errors.push({ field, message });
	const warn = (field, message) => warnings.push({ field, message });
	const inputs = rawInputs && typeof rawInputs === 'object' ? rawInputs : {};

	const engine = inputs.engine ?? DEFAULT_INPUTS.engine;
	if (!ENGINES.includes(engine)) err('engine', `engine must be one of ${ENGINES.join(', ')}`);
	const scenario = inputs.scenario ?? DEFAULT_INPUTS.scenario;
	if (!SCENARIOS.includes(scenario)) {
		err('scenario', `scenario must be one of ${SCENARIOS.join(', ')}`);
	} else if (scenario === 'three' && engine === 'os') {
		err('scenario', 'three OpenSearch nodes are not generated: there is no os-three-local scenario yet');
	}
	const base = TESTED[`${ENGINES.includes(engine) ? engine : 'es'}/single`].inputs;
	const pick = (key) => (inputs[key] === undefined ? base[key] : inputs[key]);

	const memoryGiB = pick('memoryGiB');
	if (!isNumberInRange(memoryGiB, LIMITS.memoryGiB)) {
		err('memoryGiB', `memory must be ${LIMITS.memoryGiB.min} to ${LIMITS.memoryGiB.max} GiB in steps of ${LIMITS.memoryGiB.step}`);
	}
	const cpus = pick('cpus');
	if (!isNumberInRange(cpus, LIMITS.cpus)) {
		err('cpus', `CPUs must be ${LIMITS.cpus.min} to ${LIMITS.cpus.max} in steps of ${LIMITS.cpus.step}`);
	}

	const apiHost = pick('apiHost');
	const uiHost = pick('uiHost');
	const ui = scenario === 'single-ui';
	for (const [field, host] of [['apiHost', apiHost], ...(ui ? [['uiHost', uiHost]] : [])]) {
		if (typeof host !== 'string' || !HOSTNAME_RE.test(host)) {
			err(field, 'hostname must be a lower-case DNS name with at least two labels, such as es.example.com');
		}
	}
	if (ui && typeof apiHost === 'string' && apiHost === uiHost) err('uiHost', 'the UI needs its own hostname');
	if (ui && typeof apiHost === 'string' && typeof uiHost === 'string' && isLabHost(apiHost) !== isLabHost(uiHost)) {
		err('uiHost', 'use *.localhost for both hostnames (lab) or public names for both');
	}

	const cidrList = splitCidrs(pick('allowedCidrs'));
	const parsedCidrs = [];
	if (!cidrList || cidrList.length === 0) {
		err('allowedCidrs', 'at least one CIDR is required');
	} else if (cidrList.length > LIMITS.cidrs) {
		err('allowedCidrs', `at most ${LIMITS.cidrs} CIDRs`);
	} else {
		const seen = new Set();
		for (const c of cidrList) {
			const p = parseCidr(c);
			if (p.error) {
				err('allowedCidrs', p.error);
				continue;
			}
			if (seen.has(c)) err('allowedCidrs', `${c} is listed twice`);
			seen.add(c);
			if (p.bits === 0) warn('allowedCidrs', `${c} allows every address, so the allowlist protects nothing`);
			parsedCidrs.push({ text: c, ...p });
		}
	}
	if (parsedCidrs.some((c) => c.family === 6)) {
		warn('allowedCidrs', 'IPv6 entries are valid Caddy syntax but no lab scenario has tested an IPv6 allowlist');
	}
	const docRanges = [];
	for (const c of parsedCidrs) {
		for (const r of DOC_RANGES) {
			if (cidrContains(parseCidr(r), c) && !docRanges.includes(r)) docRanges.push(r);
		}
	}
	if (docRanges.length) warn('allowedCidrs', `${docRanges.join(', ')} ${docRanges.length > 1 ? 'are documentation ranges' : 'is a documentation range'}: replace with your client addresses`);

	const indexPrefix = pick('indexPrefix');
	if (typeof indexPrefix !== 'string' || !PREFIX_RE.test(indexPrefix)) {
		err('indexPrefix', 'index prefix must match ^[a-z0-9][a-z0-9-]{0,40}$');
	}
	const readRoute = pick('readRoute');
	const writeRoute = pick('writeRoute');
	if (typeof readRoute !== 'boolean') err('readRoute', 'readRoute must be true or false');
	if (typeof writeRoute !== 'boolean') err('writeRoute', 'writeRoute must be true or false');
	if (readRoute === false && writeRoute === false) err('readRoute', 'enable the read route, the write route or both');

	const maxBodyMB = pick('maxBodyMB');
	if (!isNumberInRange(maxBodyMB, LIMITS.maxBodyMB)) err('maxBodyMB', `max body must be a whole number of MB, ${LIMITS.maxBodyMB.min} to ${LIMITS.maxBodyMB.max}`);
	const apiKeyDays = pick('apiKeyDays');
	if (engine === 'es' && !isNumberInRange(apiKeyDays, LIMITS.apiKeyDays)) {
		err('apiKeyDays', `API key expiration must be a whole number of days, ${LIMITS.apiKeyDays.min} to ${LIMITS.apiKeyDays.max}`);
	}

	const values = {
		engine, scenario, memoryGiB, cpus, apiHost,
		uiHost: ui ? uiHost : base.uiHost,
		allowedCidrs: cidrList || [], indexPrefix, readRoute, writeRoute, maxBodyMB,
		apiKeyDays: engine === 'es' ? apiKeyDays : base.apiKeyDays,
	};
	return { values, errors, warnings, docRanges };
}

function checkData(data) {
	const errors = [];
	const num = (v) => typeof v === 'number' && Number.isFinite(v);
	const heap = data?.es?.heap;
	if (typeof data?.meta?.versions_checked !== 'string') errors.push({ field: 'data', message: 'data.meta.versions_checked is missing' });
	if (!heap || !['small_threshold_mb', 'small_ratio', 'small_floor_mb', 'ratio', 'cap_gb'].every((k) => num(heap[k]))) {
		errors.push({ field: 'data', message: 'data.es.heap is missing or incomplete' });
	}
	if (!num(data?.sysctl?.es_max_map_count) || !num(data?.os?.sysctl?.max_map_count)) {
		errors.push({ field: 'data', message: 'data.sysctl.es_max_map_count or data.os.sysctl.max_map_count is missing' });
	}
	return errors;
}

// Elasticsearch's automatic heap for a data node (jvm-settings page); used
// for OpenSearch as well, which does not size its heap itself.
export function heapMiB(memoryGiB, heap) {
	const mem = memoryGiB * 1024;
	const mib = mem < heap.small_threshold_mb
		? Math.max(heap.small_ratio * mem, heap.small_floor_mb)
		: Math.min(heap.ratio * mem, heap.cap_gb * 1024);
	return Math.floor(mib);
}

function size(mib) {
	return mib % 1024 === 0 ? `${mib / 1024}g` : `${mib}m`;
}

function days(n) {
	return `${n} ${n === 1 ? 'day' : 'days'}`;
}

function testedStatus(v) {
	const key = `${v.engine}/${v.scenario}`;
	const entry = TESTED[key];
	const reasons = [];
	if (!v.readRoute) reasons.push('read route disabled');
	if (!v.writeRoute) reasons.push('write route disabled');
	if (v.allowedCidrs.some((c) => c.includes(':'))) reasons.push('IPv6 allowlist');
	if (reasons.length) return { tested: false, path: null, reasons, differs: [] };
	const differs = Object.keys(entry.inputs).filter((k) => {
		if (k === 'uiHost' && v.scenario !== 'single-ui') return false;
		if (k === 'apiKeyDays' && v.engine !== 'es') return false;
		const a = entry.inputs[k];
		const b = v[k];
		return Array.isArray(a) ? a.join(' ') !== b.join(' ') : a !== b;
	});
	return { tested: true, path: entry.path, reasons: [], differs };
}

function headerLines(status, data) {
	const tag = typeof data.meta.companion_tag === 'string' ? `@${data.meta.companion_tag}` : '';
	const lines = [`generated by small-elasticsearch-lab generator ${GENERATOR_VERSION}; data verified ${data.meta.versions_checked}`];
	if (status.tested) {
		lines.push(`tested scenario: ${status.path}${tag}`);
		if (status.differs.length) lines.push(`inputs that differ from the tested set: ${status.differs.join(', ')}`);
	} else {
		lines.push(`not a tested combination: ${status.reasons.join(', ')}`);
	}
	return lines.map((l) => `${HEADER_PREFIX}${l}\n`).join('');
}

// Shell scripts get the header at the end: their --help prints fixed line
// ranges of the file (sed -n '2,6p'), which lines inserted at the top would
// shift.
function withHeader(name, text, header) {
	return name.endsWith('.sh') ? `${text}${header}` : `${header}${text}`;
}

// Removes the generator header, for comparing output with scenario files.
export function stripHeader(text) {
	return text.split(/(?<=\n)/).filter((line) => !line.startsWith(HEADER_PREFIX)).join('');
}

export function generate(inputs, data) {
	const { values: v, errors, warnings, docRanges } = validate(inputs);
	errors.push(...checkData(data));
	if (errors.length) return { files: {}, errors, warnings, notes: [], tested: null };

	const ui = v.scenario === 'single-ui';
	const three = v.scenario === 'three';
	const d = {
		...v,
		ui,
		three,
		lab: isLabHost(v.apiHost),
		project: three ? `${v.engine}-three-local` : `${v.engine}-single${ui ? (v.engine === 'es' ? '-kibana' : '-dashboards') : ''}`,
		mem: size(v.memoryGiB * 1024),
		memLabel: `${v.memoryGiB} GiB`,
		heap: size(heapMiB(v.memoryGiB, data.es.heap)),
		cidrs: v.allowedCidrs.join(' '),
		docRanges,
	};
	const status = testedStatus(v);
	const files = v.engine === 'es' ? esFiles(d) : osFiles(d);
	const header = headerLines(status, data);
	const out = {};
	for (const [name, text] of Object.entries(files)) out[name] = withHeader(name, text, header);
	const notes = [v.engine === 'es'
		? { topic: 'vm.max_map_count', value: data.sysctl.es_max_map_count, text: `Set vm.max_map_count=${data.sysctl.es_max_map_count} on the host; a container cannot set it.` }
		: { topic: 'vm.max_map_count', value: data.os.sysctl.max_map_count, text: `Set vm.max_map_count to at least ${data.os.sysctl.max_map_count} on the host; a container cannot set it.` }];
	return { files: out, errors, warnings, notes, tested: status };
}

function docRangeComment(d) {
	if (!d.docRanges.length) return '';
	const list = d.docRanges.length === 1 ? d.docRanges[0] : `${d.docRanges.slice(0, -1).join(', ')} and ${d.docRanges[d.docRanges.length - 1]}`;
	return `# ${list} ${d.docRanges.length === 1 ? 'is a documentation range: replace it' : 'are documentation ranges: replace them'}.\n`;
}

function esFiles(d) {
	const files = {
		'compose.yaml': d.three ? esThreeCompose(d) : esCompose(d),
		'.env.example': esEnv(d),
		'Caddyfile': esCaddyfile(d),
		'init-env.sh': esInitEnv(),
		'setup-roles.sh': esSetupRoles(d),
	};
	if (d.three) files['certs/gen-certs.sh'] = esThreeGenCerts();
	return files;
}

function esCompose(d) {
	return t`
name: ${d.project}

services:
  es01:
    image: \${ES_IMAGE:?ES_IMAGE comes from versions.env}
    environment:
      - node.name=es01
      - cluster.name=${d.project}
      - discovery.type=single-node
      - xpack.security.enabled=true
      # Allowed without node certificates only because discovery.type is
      # single-node; a second node needs transport TLS.
      - xpack.security.http.ssl.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - xpack.license.self_generated.type=basic
      - bootstrap.memory_lock=true
      - ELASTIC_PASSWORD=\${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD in .env}
      # Same value auto-sizing picks for a ${d.memLabel} container, set explicitly so the
      # OpenSearch scenarios (which do not auto-size) run the same heap. Set
      # ES_HEAP_OPTS to an empty string to let Elasticsearch size it (L-M1).
      - ES_JAVA_OPTS=\${ES_HEAP_OPTS--Xms${d.heap} -Xmx${d.heap}}
    cpus: ${d.cpus}
    mem_limit: ${d.mem}
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65535
        hard: 65535
    volumes:
      - esdata:/usr/share/elasticsearch/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200 | grep -q 'missing authentication credentials'"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s

${when(d.ui, t`
  # One-shot: sets the kibana_system password before Kibana starts, so the
  # password never has to be typed into Kibana's or anyone's command line.
  kibana-setup:
    image: \${ES_IMAGE:?ES_IMAGE comes from versions.env}
    depends_on:
      es01:
        condition: service_healthy
    environment:
      - ELASTIC_PASSWORD=\${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD in .env}
      - KIBANA_SYSTEM_PASSWORD=\${KIBANA_SYSTEM_PASSWORD:?set KIBANA_SYSTEM_PASSWORD in .env}
    networks:
      - backend
    restart: "no"
    # Alphanumeric only, so neither the JSON body nor the curl config needs escaping.
    command:
      - bash
      - -c
      - |
        set -euo pipefail
        for v in "$$ELASTIC_PASSWORD" "$$KIBANA_SYSTEM_PASSWORD"; do
          [[ $$v =~ ^[A-Za-z0-9]{6,}$$ ]] || { echo "passwords must be alphanumeric, 6+ characters" >&2; exit 1; }
        done
        printf '{"password":"%s"}' "$$KIBANA_SYSTEM_PASSWORD" |
          curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' --data-binary @- \
            -K <(printf 'user = "elastic:%s"\n' "$$ELASTIC_PASSWORD") \
            http://es01:9200/_security/user/kibana_system/_password
        echo

  kibana:
    image: \${KIBANA_IMAGE:?KIBANA_IMAGE comes from versions.env}
    depends_on:
      kibana-setup:
        condition: service_completed_successfully
    environment:
      - SERVER_NAME=kibana
      - SERVER_PUBLICBASEURL=\${KIBANA_PUBLIC_URL:?set KIBANA_PUBLIC_URL in .env}
      # Straight to the node on the compose network, not through Caddy.
      - ELASTICSEARCH_HOSTS=http://es01:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=\${KIBANA_SYSTEM_PASSWORD:?set KIBANA_SYSTEM_PASSWORD in .env}
      # Fixed keys keep sessions and encrypted saved objects (alerting rules,
      # connectors) valid across restarts; without the saved-objects key
      # alerting is unavailable.
      - XPACK_SECURITY_ENCRYPTIONKEY=\${KIBANA_SECURITY_KEY:?set KIBANA_SECURITY_KEY in .env}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=\${KIBANA_SAVED_OBJECTS_KEY:?set KIBANA_SAVED_OBJECTS_KEY in .env}
      - XPACK_REPORTING_ENCRYPTIONKEY=\${KIBANA_REPORTING_KEY:?set KIBANA_REPORTING_KEY in .env}
    # 1g matches the official compose; Kibana recommends 2g with alerting,
    # reporting, detection rules or SLOs.
    mem_limit: \${KIBANA_MEM_LIMIT:-1g}
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "curl -s -I http://localhost:5601 | grep -q 'HTTP/1.1 302 Found'"]
      interval: 10s
      timeout: 10s
      retries: 60
      start_period: 60s

`)}  caddy:
    image: \${CADDY_IMAGE:?CADDY_IMAGE comes from versions.env}
    depends_on:
      es01:
        condition: service_healthy
    environment:
      - ES_SITE_ADDRESS=\${ES_SITE_ADDRESS:?set ES_SITE_ADDRESS in .env}
${when(d.ui, t`
      - KIBANA_SITE_ADDRESS=\${KIBANA_SITE_ADDRESS:?set KIBANA_SITE_ADDRESS in .env}
`)}      - ALLOWED_CIDRS=\${ALLOWED_CIDRS:?set ALLOWED_CIDRS in .env}
    ports:
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTP_PORT:-80}:80"
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTPS_PORT:-443}:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - backend

networks:
  backend: {}

volumes:
  esdata: {}
  caddy_data: {}
  caddy_config: {}
`;
}

function caddyPublish(d, siteVars) {
	if (d.lab) {
		return t`
# Lab defaults: Caddy on loopback, high ports, Caddy's internal CA for *.localhost.
# On a real host: CADDY_BIND=0.0.0.0, ports 80 and 443, ES_SITE_ADDRESS set to a
# public DNS name so Caddy obtains a certificate${siteVars}.
CADDY_BIND=127.0.0.1
CADDY_HTTP_PORT=8080
CADDY_HTTPS_PORT=8443
`;
	}
	return t`
# Public DNS names: Caddy obtains certificates from Let's Encrypt, which needs
# ports 80 and 443 reachable. For a local lab use *.localhost names,
# CADDY_BIND=127.0.0.1 and high ports instead.
CADDY_BIND=0.0.0.0
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
`;
}

function esEnv(d) {
	return t`
# Copy to .env, or run ./init-env.sh, which writes .env with random passwords.
# Passwords: alphanumeric, at least 6 characters (Elasticsearch minimum); the
# scripts here refuse the change-me placeholders.
ELASTIC_PASSWORD=change-me-elastic
APP_PASSWORD=change-me-app
${when(d.ui, t`
KIBANA_SYSTEM_PASSWORD=change-me-kibana

# Kibana keys, at least 32 characters each. init-env.sh generates them; keep
# them stable, changing the saved-objects key makes encrypted objects unreadable.
KIBANA_SECURITY_KEY=change-me-kibana-security-key-32chars
KIBANA_SAVED_OBJECTS_KEY=change-me-kibana-saved-objects-key-32
KIBANA_REPORTING_KEY=change-me-kibana-reporting-key-32chars

# 1g for Discover and dashboards; 2g if you use alerting or reporting.
KIBANA_MEM_LIMIT=1g
`)}
${caddyPublish(d, d.ui ? ' (same for KIBANA_SITE_ADDRESS)' : '')}ES_SITE_ADDRESS=${d.apiHost}
${when(d.ui, t`
KIBANA_SITE_ADDRESS=${d.uiHost}
# The URL users type, port included when it is not 443; no trailing slash.
KIBANA_PUBLIC_URL=https://${d.uiHost}${d.lab ? ':8443' : ''}
`)}
# Space-separated CIDRs. Caddy sees the immediate TCP peer, see README.md.
${docRangeComment(d)}ALLOWED_CIDRS=${d.cidrs}

# Unset: -Xms${d.heap} -Xmx${d.heap}. Empty string: Elasticsearch sizes the heap itself.
#ES_HEAP_OPTS=
`;
}

function routeMatchers(d) {
	return when(d.writeRoute, t`
\t\t# This allowlist is a speed bump: a _bulk body can still name any index,
\t\t# and only the ${d.engine === 'es' ? 'Elasticsearch' : 'OpenSearch'} role decides what the caller may touch.
`) + when(d.readRoute, t`
\t\t@app_read {
\t\t\tmethod GET POST
\t\t\texpression \`{http.request.uri}.matches("^/${d.indexPrefix}-[a-z0-9][a-z0-9-]*/_(search|count)([?].*)?$")\`
\t\t}
`) + when(d.writeRoute, t`
\t\t@app_write {
\t\t\tmethod POST PUT
\t\t\texpression \`{http.request.uri}.matches("^/${d.indexPrefix}-[a-z0-9][a-z0-9-]*/_bulk([?].*)?$")\`
\t\t}
`);
}

function caddyGlobal(d, sites) {
	return t`
# Requires Caddy 2.11.1 or later (CVE-2026-27587). The {$VAR:default} values let
# the same file run in compose, in CI validation and in the proxy-only test
# harness; compose always sets ${sites} and ALLOWED_CIDRS.${when(d.three, t`
 ES_UPSTREAMS is a
# space-separated host:port list; Caddy splits it into one upstream per item.`)}
{
\tadmin {$CADDY_ADMIN:localhost:2019}
\tservers {
\t\tprotocols h1 h2
\t}
}
`;
}

function esCaddyfile(d) {
	const routes = [d.readRoute && 'app_read', d.writeRoute && 'app_write'].filter(Boolean);
	const upstream = d.three ? '{$ES_UPSTREAMS:es01:9200 es02:9200 es03:9200}' : '{$ES_UPSTREAM:es01:9200}';
	const balance = when(d.three, t`
\t\t\tlb_policy round_robin
\t\t\tlb_try_duration 5s
\t\t\tfail_duration 30s
`);
	const proxies = when(d.three, t`
\t\t# A stopped node fails at connect time, and Caddy retries a failed
\t\t# connect on another node for any method, because nothing reached the
\t\t# node. A request that did reach a node is retried only if it is a GET,
\t\t# so a _bulk is never sent twice. fail_duration keeps a dead node out of
\t\t# rotation for 30s after one failure.
`) + routes.map((r, i) => i === 0 ? t`
\t\treverse_proxy @${r} ${upstream} {
${balance}\t\t\t# Elasticsearch does not honour this header; dropping it only keeps
\t\t\t# the upstream request equal to what the method matcher saw.
\t\t\theader_up -X-HTTP-Method-Override
\t\t}
` : t`
\t\treverse_proxy @${r} ${upstream} {
${balance}\t\t\theader_up -X-HTTP-Method-Override
\t\t}
`).join('');
	return caddyGlobal(d, d.ui ? 'the site addresses' : 'ES_SITE_ADDRESS') + t`

{$ES_SITE_ADDRESS:es.localhost} {
\tlog

\t# route keeps the written order. Without it Caddy sorts directives and runs
\t# handle and reverse_proxy before abort, so the IP allowlist would not
\t# protect the proxied paths.
\troute {
\t\t# remote_ip is the immediate TCP peer. Behind another proxy or Docker's
\t\t# userland proxy that is not the client, and this check means nothing.
\t\t@outside not remote_ip {$ALLOWED_CIDRS:127.0.0.1/32}
\t\tabort @outside

\t\trequest_body {
\t\t\tmax_size ${d.maxBodyMB}MB
\t\t}

\t\t# Matched against the raw request URI, because reverse_proxy forwards the
\t\t# raw path: path and path_regexp see a decoded, dot-cleaned path, so
\t\t# /secret/../${d.indexPrefix}-a/_search would match them and still reach the node as
\t\t# written. Any encoding, dot segment, double slash, upper case, comma,
\t\t# wildcard, date math or remote-cluster prefix fails the pattern and
\t\t# gets the 404 below.
${routeMatchers(d)}
${proxies}
\t\trespond 404
\t}
}
${when(d.ui, t`

# Kibana is a full Elasticsearch client for anyone who can log in (Dev Tools
# console), so the path allowlist above does not apply to Kibana users; their
# Elasticsearch roles do. Caddy only adds the IP allowlist and TLS here.
{$KIBANA_SITE_ADDRESS:kibana.localhost} {
\tlog

\troute {
\t\t@outside not remote_ip {$ALLOWED_CIDRS:127.0.0.1/32}
\t\tabort @outside

\t\treverse_proxy {$KIBANA_UPSTREAM:kibana:5601}
\t}
}
`)}`;
}

function esInitEnv() {
	return t`
#!/usr/bin/env bash
# Writes .env next to this script from .env.example with random alphanumeric
# passwords. Refuses to overwrite an existing .env.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
env_file="$dir/.env"

if [ -e "$env_file" ]; then
\techo "error: $env_file exists; remove it first to regenerate" >&2
\texit 1
fi

random_secret() {
\tLC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "\${1:-32}" || true
}

umask 077
while IFS= read -r line; do
\tcase "$line" in
\t*=change-me*) printf '%s=%s\n' "\${line%%=*}" "$(random_secret 32)" ;;
\t*) printf '%s\n' "$line" ;;
\tesac
done <"$dir/.env.example" >"$env_file"
echo "wrote $env_file (mode 600)"
`;
}

function esPrivileges(d) {
	return [d.readRoute && '"read"', d.writeRoute && '"create_doc"'].filter(Boolean).join(', ');
}

function esSetupRoles(d) {
	const p = d.indexPrefix;
	const replicas = d.three ? 1 : 0;
	return t`
#!/usr/bin/env bash
# Creates the index template, the test indices, the app_writer role and the
# app_x user, then creates an expiring, scoped API key for the application as
# elastic. Run it again to rotate: it creates a new key, see README.md.
#
# Usage: setup-roles.sh [--key-out FILE]
# READY_TIMEOUT (seconds, default 180) bounds the wait for the cluster.
#
# The node publishes no port and Caddy does not proxy _security, so every call
# runs curl inside the es01 container against 127.0.0.1:9200. Passwords reach
# that curl on stdin and as a curl config read from a pipe, never through argv,
# which any user on the host can read with ps.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../.." && pwd)
key_out=""

while [ $# -gt 0 ]; do
\tcase "$1" in
\t--key-out) key_out="\${2:?--key-out needs a file}"; shift 2 ;;
\t-h | --help) sed -n '2,6p' "$0"; exit 0 ;;
\t*) echo "error: unknown argument $1" >&2; exit 2 ;;
\tesac
done

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -f "$dir/.env" ] || { echo "error: $dir/.env missing, run init-env.sh" >&2; exit 1; }

# Read single keys instead of sourcing .env: ALLOWED_CIDRS holds spaces and
# compose does not quote values.
env_value() {
\tlocal v
\tv=$(grep -m1 "^$1=" "$dir/.env" | cut -d= -f2-) || true
\tprintf '%s' "\${!1:-$v}"
}
ELASTIC_PASSWORD=$(env_value ELASTIC_PASSWORD)
APP_PASSWORD=$(env_value APP_PASSWORD)
for name in ELASTIC_PASSWORD APP_PASSWORD; do
\tcase "\${!name}" in
\t"" | change-me*) echo "error: $name is unset or still the .env.example placeholder" >&2; exit 1 ;;
\tesac
done

compose=(docker compose --project-directory "$dir" --env-file "$repo/versions.env"
\t--env-file "$dir/.env" -f "$dir/compose.yaml")

# The first stdin line is the password, the rest is the request body. bash
# reads a pipe byte by byte, so curl gets the stream right after that line.
# shellcheck disable=SC2016 # expanded inside the container
remote='IFS= read -r pass; pass=\${pass//\\/\\\\}; pass=\${pass//\"/\\\"}
curl -sS -w "\n%{http_code}" -X "$1" -H "Content-Type: application/json" \
\t--data-binary @- -K <(printf "user = \"%s:%s\"\n" "$3" "$pass") \
\t"http://127.0.0.1:9200$2"'

# es METHOD PATH < body; runs as elastic, prints the response body, then the
# status on its own line.
es() {
\t{ printf '%s\n' "$ELASTIC_PASSWORD"; cat; } |
\t\t"\${compose[@]}" exec -T es01 bash -c "$remote" _ "$1" "$2" elastic
}

# es_ok METHOD PATH < body; prints the body, fails unless 2xx.
es_ok() {
\tlocal res status body
\tres=$(es "$@")
\tstatus=\${res##*$'\n'}
\tbody=\${res%$'\n'*}
\tcase "$status" in
\t2??) printf '%s' "$body" ;;
\t*) echo "error: $1 $2 returned $status: $body" >&2; return 1 ;;
\tesac
}

# wait_ready PATH: GET PATH until it answers 200. compose up --wait returns
# when the node answers HTTP, which can be before the .security-7 primary is
# assigned; until then even elastic fails with 503 ("failed to retrieve
# password hash for reserved user"), or 401. 401, 408 (health timeout), 503
# and no answer are retried until READY_TIMEOUT seconds (default 180) have
# passed; anything else fails at once.
wait_ready() {
\tlocal timeout=\${READY_TIMEOUT:-180} start=$SECONDS attempt=0 res status
\t[[ $timeout =~ ^[0-9]+$ ]] || { echo "error: READY_TIMEOUT must be a number of seconds" >&2; return 1; }
\twhile :; do
\t\tattempt=$((attempt + 1))
\t\tres=$(es GET "$1" </dev/null 2>/dev/null) || true
\t\tstatus=\${res##*$'\n'}
\t\t[[ $status =~ ^[0-9]{3}$ ]] || status=000
\t\tcase "$status" in
\t\t200) return 0 ;;
\t\t401 | 408 | 503 | 000) ;;
\t\t*) echo "error: GET $1 returned $status: \${res%$'\n'*}" >&2; return 1 ;;
\t\tesac
\t\tif [ $((SECONDS - start)) -ge "$timeout" ]; then
\t\t\techo "error: GET $1 not ready after \${timeout}s ($attempt attempts), last answer $status: \${res%$'\n'*}" >&2
\t\t\treturn 1
\t\tfi
\t\techo "waiting for $1: attempt $attempt answered $status, $((SECONDS - start))s of \${timeout}s" >&2
\t\tsleep 3
\tdone
}

create_index_once() {
\tif [ "$(es GET "/$1" </dev/null | tail -n1)" = 404 ]; then
\t\tes_ok PUT "/$1" >/dev/null
\tfi
}

"\${compose[@]}" ps --status running -q es01 | grep -q . ||
\t{ echo "error: es01 is not running, start it with make up SCENARIO=$(basename "$dir")" >&2; exit 1; }

${d.three ? t`
# Green, not yellow: with three nodes every replica has somewhere to go.
wait_ready '/_cluster/health?wait_for_status=green&wait_for_nodes=3&timeout=30s'
` : t`
wait_ready '/_cluster/health?wait_for_status=yellow&timeout=30s'
`}
es_ok PUT /_index_template/${p} >/dev/null <<'JSON'
{
  "index_patterns": ["${p}-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": ${replicas}}
  }
}
JSON

es_ok PUT /_security/role/app_writer >/dev/null <<'JSON'
{
  "indices": [
    {"names": ["${p}-*"], "privileges": [${esPrivileges(d)}]}
  ]
}
JSON

APP_PASSWORD=$APP_PASSWORD jq -n '{password: env.APP_PASSWORD, roles: ["app_writer"], full_name: "app-x service"}' |
\tes_ok PUT /_security/user/app_x >/dev/null

create_index_once ${p}-a </dev/null
create_index_once secret <<'JSON'
{"settings": {"number_of_shards": 1, "number_of_replicas": ${replicas}}}
JSON
echo '{"message": "seed", "@timestamp": "2026-01-01T00:00:00Z"}' |
\tes_ok PUT '/${p}-a/_doc/seed?refresh=true' >/dev/null
echo '{"message": "not for app-x", "@timestamp": "2026-01-01T00:00:00Z"}' |
\tes_ok PUT '/secret/_doc/1?refresh=true' >/dev/null
${when(d.three, t`
es_ok GET '/_cluster/health/${p}-a,secret?wait_for_status=green&timeout=120s' </dev/null >/dev/null
`)}
# The key is owned by elastic, so role_descriptors is its only limit: without
# them it would be a superuser key. Keys never expire unless told to.
key=$(es_ok POST /_security/api_key <<'JSON' | jq -er .encoded
{
  "name": "app-x-key",
  "expiration": "${d.apiKeyDays}d",
  "role_descriptors": {
    "app_x_key": {
      "indices": [
        {"names": ["${p}-*"], "privileges": [${esPrivileges(d)}]}
      ]
    }
  }
}
JSON
)

if [ -n "$key_out" ]; then
\t(umask 077 && printf 'APP_API_KEY=%s\n' "$key" >"$key_out")
\techo "role app_writer, user app_x and an app API key (${days(d.apiKeyDays)}, owned by elastic) created; key written to $key_out"
else
\techo "role app_writer, user app_x and an app API key (${days(d.apiKeyDays)}, owned by elastic) created" >&2
\tprintf 'APP_API_KEY=%s\n' "$key"
fi
`;
}

function esThreeCompose(d) {
	return t`
# Lab only: three nodes on one host share its CPU, memory, disk and kernel, so
# losing the host loses all three. This shows quorum and allocation behaviour,
# not fault tolerance.
name: ${d.project}

x-es-env: &es-env
  cluster.name: ${d.project}
  node.roles: master,data,ingest
  discovery.seed_hosts: es01,es02,es03
  # Read only while no cluster has formed yet; every run starts from empty
  # volumes (make down deletes them). Left in, each node logs a warning at
  # start and every 12 hours. On a real cluster remove it after the first
  # start, see README.md.
  cluster.initial_master_nodes: es01,es02,es03
  xpack.security.enabled: "true"
  xpack.security.http.ssl.enabled: "false"
  xpack.security.transport.ssl.enabled: "true"
  # The CA signs nothing but these nodes, so a valid chain identifies a node of
  # this cluster; full verification would also need the container IPs, which
  # Docker assigns at start, in every certificate.
  xpack.security.transport.ssl.verification_mode: certificate
  xpack.security.transport.ssl.key: certs/node-key.pem
  xpack.security.transport.ssl.certificate: certs/node.pem
  xpack.security.transport.ssl.certificate_authorities: certs/ca.pem
  xpack.license.self_generated.type: basic
  bootstrap.memory_lock: "true"
  # The image writes this into the node's keystore as bootstrap.password. Only
  # the node that first handles the elastic user needs it, and which node that
  # is cannot be known up front, so every node gets the same value.
  ELASTIC_PASSWORD: \${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD in .env}
  # Unset: -Xms${d.heap} -Xmx${d.heap}, as in es-single. Empty string: auto-sizing.
  ES_JAVA_OPTS: \${ES_HEAP_OPTS--Xms${d.heap} -Xmx${d.heap}}

x-es-node: &es-node
  image: \${ES_IMAGE:?ES_IMAGE comes from versions.env}
  cpus: ${d.cpus}
  mem_limit: ${d.mem}
  ulimits:
    memlock:
      soft: -1
      hard: -1
    nofile:
      soft: 65535
      hard: 65535
  networks:
    - backend
  healthcheck:
    test: ["CMD-SHELL", "curl -s http://localhost:9200 | grep -q 'missing authentication credentials'"]
    interval: 10s
    timeout: 10s
    retries: 30
    start_period: 30s

# create_host_path false: without it a missing certificate becomes an empty
# directory created by Docker, and the node fails with a less obvious error.
x-ca: &ca
  type: bind
  source: ./certs/ca.pem
  target: /usr/share/elasticsearch/config/certs/ca.pem
  read_only: true
  bind:
    create_host_path: false

services:
  es01:
    <<: *es-node
    environment:
      <<: *es-env
      node.name: es01
    volumes:
      - esdata01:/usr/share/elasticsearch/data
      - *ca
      - {type: bind, source: ./certs/es01.pem, target: /usr/share/elasticsearch/config/certs/node.pem, read_only: true, bind: {create_host_path: false}}
      - {type: bind, source: ./certs/es01-key.pem, target: /usr/share/elasticsearch/config/certs/node-key.pem, read_only: true, bind: {create_host_path: false}}

  es02:
    <<: *es-node
    environment:
      <<: *es-env
      node.name: es02
    volumes:
      - esdata02:/usr/share/elasticsearch/data
      - *ca
      - {type: bind, source: ./certs/es02.pem, target: /usr/share/elasticsearch/config/certs/node.pem, read_only: true, bind: {create_host_path: false}}
      - {type: bind, source: ./certs/es02-key.pem, target: /usr/share/elasticsearch/config/certs/node-key.pem, read_only: true, bind: {create_host_path: false}}

  es03:
    <<: *es-node
    environment:
      <<: *es-env
      node.name: es03
    volumes:
      - esdata03:/usr/share/elasticsearch/data
      - *ca
      - {type: bind, source: ./certs/es03.pem, target: /usr/share/elasticsearch/config/certs/node.pem, read_only: true, bind: {create_host_path: false}}
      - {type: bind, source: ./certs/es03-key.pem, target: /usr/share/elasticsearch/config/certs/node-key.pem, read_only: true, bind: {create_host_path: false}}

  caddy:
    image: \${CADDY_IMAGE:?CADDY_IMAGE comes from versions.env}
    depends_on:
      es01:
        condition: service_healthy
      es02:
        condition: service_healthy
      es03:
        condition: service_healthy
    environment:
      - ES_SITE_ADDRESS=\${ES_SITE_ADDRESS:?set ES_SITE_ADDRESS in .env}
      - ALLOWED_CIDRS=\${ALLOWED_CIDRS:?set ALLOWED_CIDRS in .env}
    ports:
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTP_PORT:-80}:80"
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTPS_PORT:-443}:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - backend

networks:
  backend: {}

volumes:
  esdata01: {}
  esdata02: {}
  esdata03: {}
  caddy_data: {}
  caddy_config: {}
`;
}

function esThreeGenCerts() {
	return t`
#!/usr/bin/env bash
# Generates a CA and one transport certificate per node with
# elasticsearch-certutil, run inside the pinned Elasticsearch image, and writes
# PEM files next to this script. Refuses to overwrite existing files.
#
# Usage: certs/gen-certs.sh [NODE...]      (default: es01 es02 es03)
#
# Output: ca.pem, ca-key.pem (host only, never mounted), <node>.pem and
# <node>-key.pem. Node keys are owned by the host user with group 0 and mode
# 640, because the container user is uid 1000, gid 0.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../../.." && pwd)
nodes=("$@")
[ \${#nodes[@]} -gt 0 ] || nodes=(es01 es02 es03)

for n in "\${nodes[@]}"; do
\t[[ $n =~ ^[a-z][a-z0-9-]*$ ]] || { echo "error: bad node name '$n'" >&2; exit 2; }
done

existing=$(find "$dir" -maxdepth 1 \( -name '*.pem' -o -name '*.zip' \) -print -quit)
if [ -n "$existing" ]; then
\techo "error: $dir already holds certificates ($existing); remove them first to regenerate" >&2
\texit 1
fi

image=$(grep -m1 '^ES_IMAGE=' "$repo/versions.env" | cut -d= -f2-)
[ -n "$image" ] || { echo "error: ES_IMAGE not found in $repo/versions.env" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: the Docker daemon is not reachable" >&2; exit 1; }

work=$(mktemp -d "$dir/.gen.XXXXXX")
trap 'rm -rf "$work"' EXIT

{
\techo "instances:"
\tfor n in "\${nodes[@]}"; do
\t\tprintf '  - name: %s\n    dns: [%s, localhost]\n    ip: [127.0.0.1]\n' "$n" "$n"
\tdone
} >"$work/instances.yml"

echo "generating a CA and certificates for: \${nodes[*]} (image $image)"
# shellcheck disable=SC2016 # expanded inside the container
docker run --rm --user 0 -v "$work:/work" --entrypoint bash "$image" -c '
set -euo pipefail
cd /usr/share/elasticsearch
bin/elasticsearch-certutil ca --silent --pem --out /work/ca.zip
unzip -q /work/ca.zip -d /work
bin/elasticsearch-certutil cert --silent --pem --ca-cert /work/ca/ca.crt --ca-key /work/ca/ca.key \
\t--in /work/instances.yml --out /work/nodes.zip
unzip -q /work/nodes.zip -d /work/nodes
mkdir /work/out
cp /work/ca/ca.crt /work/out/ca.pem
cp /work/ca/ca.key /work/out/ca-key.pem
for d in /work/nodes/*/; do
\tn=$(basename "$d")
\tcp "$d/$n.crt" "/work/out/$n.pem"
\tcp "$d/$n.key" "/work/out/$n-key.pem"
done
chown -R "$1:$2" /work
chown "$1:0" /work/out/*.pem
chown "$1:$2" /work/out/ca-key.pem
chmod 644 /work/out/*.pem
chmod 640 /work/out/*-key.pem
chmod 600 /work/out/ca-key.pem
' _ "$(id -u)" "$(id -g)"

for n in "\${nodes[@]}"; do
\t[ -s "$work/out/$n.pem" ] && [ -s "$work/out/$n-key.pem" ] ||
\t\t{ echo "error: certutil produced no certificate for $n" >&2; exit 1; }
done
mv "$work"/out/*.pem "$dir/"
ls -l "$dir"/*.pem
`;
}

function osFiles(d) {
	const files = {
		'.gitignore': '/security/\n',
		'compose.yaml': osCompose(d),
		'.env.example': osEnv(d),
		'opensearch.yml': osYml(d),
	};
	if (d.ui) files['opensearch_dashboards.yml'] = osDashboardsYml();
	Object.assign(files, {
		'Caddyfile': osCaddyfile(d),
		'roles.yml': osRoles(d),
		'roles_mapping.yml': osRolesMapping(d),
		'internal_users.yml.example': osInternalUsers(d),
		'init-env.sh': osInitEnv(),
		'init-security.sh': osInitSecurity(),
		'certs/gen-certs.sh': osGenCerts(),
	});
	return files;
}

function osCompose(d) {
	return t`
name: ${d.project}

# Run through the Makefile (make up SCENARIO=${d.project}), which passes
# versions.env and .env. Certificates and security/internal_users.yml must exist
# first: certs/gen-certs.sh, then init-security.sh. See README.md.

x-file: &file
  type: bind
  read_only: true
  bind:
    # Fail instead of letting Docker create an empty directory when a
    # certificate or the rendered users file has not been generated yet.
    create_host_path: false

services:
  os01:
    image: \${OPENSEARCH_IMAGE:?OPENSEARCH_IMAGE comes from versions.env}
    hostname: os01
    cpus: ${d.cpus}
    mem_limit: ${d.mem}
    environment:
      # OpenSearch does not size the heap from the container limit; without
      # this it starts with the 1g from its jvm.options whatever mem_limit is.
      OPENSEARCH_JAVA_OPTS: -Xms${d.heap} -Xmx${d.heap}
      DISABLE_INSTALL_DEMO_CONFIG: "true"
      # A second JVM next to the node, started by the image entrypoint, that
      # would take memory from the same ${d.mem} limit.
      DISABLE_PERFORMANCE_ANALYZER_AGENT_CLI: "true"
      plugins.security.ssl.http.enabled: "true"
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - os01-data:/usr/share/opensearch/data
      - { <<: *file, source: ./opensearch.yml, target: /usr/share/opensearch/config/opensearch.yml }
      - { <<: *file, source: ./certs/root-ca.pem, target: /usr/share/opensearch/config/root-ca.pem }
      - { <<: *file, source: ./certs/os01.pem, target: /usr/share/opensearch/config/os01.pem }
      - { <<: *file, source: ./certs/os01-key.pem, target: /usr/share/opensearch/config/os01-key.pem }
      - { <<: *file, source: ./certs/admin.pem, target: /usr/share/opensearch/config/admin.pem }
      - { <<: *file, source: ./certs/admin-key.pem, target: /usr/share/opensearch/config/admin-key.pem }
      - { <<: *file, source: ./security/internal_users.yml, target: /usr/share/opensearch/config/opensearch-security/internal_users.yml }
      - { <<: *file, source: ./roles.yml, target: /usr/share/opensearch/config/opensearch-security/roles.yml }
      - { <<: *file, source: ./roles_mapping.yml, target: /usr/share/opensearch/config/opensearch-security/roles_mapping.yml }
    healthcheck:
      # 401 without credentials means the REST layer is up and the security
      # index is initialized; an uninitialized plugin answers 503. No password
      # is needed inside the container for this.
      test:
        - CMD-SHELL
        - >-
          test "$$(curl -s -o /dev/null -w '%{http_code}' --cacert config/root-ca.pem
          --resolve os01:9200:127.0.0.1 https://os01:9200/)" = 401
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s
    networks:
      - backend

${when(d.ui, t`
  osd01:
    image: \${OPENSEARCH_DASHBOARDS_IMAGE:?OPENSEARCH_DASHBOARDS_IMAGE comes from versions.env}
    hostname: osd01
    cpus: 1
    mem_limit: 1g
    depends_on:
      os01:
        condition: service_healthy
    environment:
      KIBANASERVER_PASSWORD: \${KIBANASERVER_PASSWORD:?set KIBANASERVER_PASSWORD in .env}
      DASHBOARDS_COOKIE_SECRET: \${DASHBOARDS_COOKIE_SECRET:?set DASHBOARDS_COOKIE_SECRET in .env}
      # An explicit V8 heap below mem_limit, so that Node.js does not size it
      # from host memory and the container is not OOM-killed first.
      NODE_OPTIONS: --max-old-space-size=640
    volumes:
      - { <<: *file, source: ./opensearch_dashboards.yml, target: /usr/share/opensearch-dashboards/config/opensearch_dashboards.yml }
      - { <<: *file, source: ./certs/root-ca.pem, target: /usr/share/opensearch-dashboards/config/root-ca.pem }
    healthcheck:
      # 200 or 401 means the server is up; it answers 503 while it starts.
      test:
        - CMD-SHELL
        - >-
          code=$$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5601/api/status);
          test "$$code" = 200 || test "$$code" = 401
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 120s
    networks:
      - backend

`)}  caddy:
    image: \${CADDY_IMAGE:?CADDY_IMAGE comes from versions.env}
    depends_on:
      os01:
        condition: service_healthy
${when(d.ui, t`
      osd01:
        condition: service_started
`)}    environment:
      OS_SITE_ADDRESS: \${OS_SITE_ADDRESS:?set OS_SITE_ADDRESS in .env}
${when(d.ui, t`
      DASHBOARDS_SITE_ADDRESS: \${DASHBOARDS_SITE_ADDRESS:?set DASHBOARDS_SITE_ADDRESS in .env}
`)}      ALLOWED_CIDRS: \${ALLOWED_CIDRS:?set ALLOWED_CIDRS in .env}
    ports:
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTP_PORT:-80}:80"
      - "\${CADDY_BIND:-127.0.0.1}:\${CADDY_HTTPS_PORT:-443}:443"
    volumes:
      - { <<: *file, source: ./Caddyfile, target: /etc/caddy/Caddyfile }
      - { <<: *file, source: ./certs/root-ca.pem, target: /etc/caddy/os-root-ca.pem }
      - caddy-data:/data
    networks:
      - backend

volumes:
  os01-data:
  caddy-data:

networks:
  backend:
`;
}

function osEnv(d) {
	const publish = d.lab ? t`
# Where Caddy is published. Lab defaults: loopback, high ports. On a server:
# CADDY_BIND=0.0.0.0, ports 80 and 443.
CADDY_BIND=127.0.0.1
CADDY_HTTP_PORT=8080
CADDY_HTTPS_PORT=8443
` : t`
# Where Caddy is published: all interfaces, ports 80 and 443. For a local lab:
# CADDY_BIND=127.0.0.1 and high ports.
CADDY_BIND=0.0.0.0
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
`;
	return t`
# Copy to .env and replace every value. .env is git-ignored.

# Passwords for internal_users.yml, hashed by init-security.sh. At least 16
# characters each. The admin password is also what bench/run.sh needs as
# LOADER_PASSWORD.
ADMIN_PASSWORD=change-me-admin-0000000000
APP_PASSWORD=change-me-app-00000000000000
# The internal user behind APP_PASSWORD, as in internal_users.yml.example and
# roles_mapping.yml; tests/run-scenario.sh reads it for the app_user rows.
APP_USER=app_x

${d.ui ? t`
# Public name of the API site (Dashboards has its own, below). A real DNS name
# makes Caddy get a certificate from Let's Encrypt and needs ports 80 and 443
# reachable; os.localhost uses Caddy's internal CA, for local lab use.
` : t`
# Public name of the API site. A real DNS name makes Caddy get a certificate
# from Let's Encrypt and needs ports 80 and 443 reachable; os.localhost uses
# Caddy's internal CA, for local lab use.
`}OS_SITE_ADDRESS=${d.apiHost}

${d.ui ? t`
# Space-separated CIDRs allowed to reach the API and Dashboards through Caddy.
# Matched against the TCP peer address that Caddy sees (remote_ip), not
# X-Forwarded-For.
` : t`
# Space-separated CIDRs allowed to reach the API through Caddy. Matched against
# the TCP peer address that Caddy sees (remote_ip), not X-Forwarded-For.
`}${docRangeComment(d)}ALLOWED_CIDRS=${d.cidrs}

${publish}${when(d.ui, t`

# OpenSearch Dashboards: the kibanaserver password is hashed into
# internal_users.yml by init-security.sh and given to Dashboards. The cookie
# secret encrypts session cookies and must be at least 32 characters.
KIBANASERVER_PASSWORD=change-me-kibanaserver-000000
DASHBOARDS_COOKIE_SECRET=change-me-cookie-secret-0000000000000000
DASHBOARDS_SITE_ADDRESS=${d.uiHost}
`)}`;
}

function osYml(d) {
	return t`
cluster.name: ${d.project}
node.name: os01
network.host: 0.0.0.0
discovery.type: single-node
bootstrap.memory_lock: true

plugins.security.ssl.transport.pemcert_filepath: os01.pem
plugins.security.ssl.transport.pemkey_filepath: os01-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: root-ca.pem

# plugins.security.ssl.http.enabled is set in compose.yaml, not here, so that
# compose.bench.yaml can switch it off with a plain environment override.
plugins.security.ssl.http.pemcert_filepath: os01.pem
plugins.security.ssl.http.pemkey_filepath: os01-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: root-ca.pem

# Without the demo installer nothing creates the security index. This makes the
# plugin create it on first start from the files mounted into
# config/opensearch-security/; later changes need init-security.sh --apply.
plugins.security.allow_default_init_securityindex: true

plugins.security.nodes_dn:
  - 'CN=os01,OU=lab,O=small-elasticsearch-lab'
plugins.security.authcz.admin_dn:
  - 'CN=admin,OU=lab,O=small-elasticsearch-lab'
`;
}

function osDashboardsYml() {
	return t`
# Mounted over the image file, which is written for the demo configuration.
# \${VAR} is replaced from the container environment when Dashboards reads this
# file, so the secrets stay out of the file and off the command line.
server.name: osd01
server.host: "0.0.0.0"

opensearch.hosts: ["https://os01:9200"]
opensearch.ssl.verificationMode: full
opensearch.ssl.certificateAuthorities: ["/usr/share/opensearch-dashboards/config/root-ca.pem"]
opensearch.username: kibanaserver
opensearch.password: \${KIBANASERVER_PASSWORD}
opensearch.requestHeadersAllowlist: [authorization, securitytenant]

opensearch_security.multitenancy.enabled: false
# Browsers reach Dashboards over HTTPS through Caddy, even though Caddy talks
# to it over plain HTTP.
opensearch_security.cookie.secure: true
# The default is a fixed string in the plugin source, so every install that
# keeps it encrypts session cookies with a publicly known password.
opensearch_security.cookie.password: \${DASHBOARDS_COOKIE_SECRET}
`;
}

function osCaddyfile(d) {
	const imports = [d.readRoute && 'app_read', d.writeRoute && 'app_write']
		.filter(Boolean).map((r) => `\t\timport os_upstream @${r}\n`).join('');
	return caddyGlobal(d, d.ui ? 'the site addresses' : 'OS_SITE_ADDRESS') + t`

# import os_upstream <matcher>
(os_upstream) {
\treverse_proxy {args[0]} {$OS_UPSTREAM:https://os01:9200} {
\t\t# Not access control; dropping it only keeps the upstream request equal
\t\t# to what the method matcher saw.
\t\theader_up -X-HTTP-Method-Override
\t\t# The node serves HTTPS because securityadmin.sh needs it. Caddy verifies
\t\t# it against the lab CA; the server name defaults to the upstream host,
\t\t# os01, which is in the node certificate SAN.
\t\ttransport http {
\t\t\ttls_trust_pool file {$OS_CA_FILE:/etc/caddy/os-root-ca.pem}
\t\t}
\t}
}

{$OS_SITE_ADDRESS:os.localhost} {
\tlog

\t# route keeps the written order. Without it Caddy sorts directives and runs
\t# handle and reverse_proxy before abort, so the IP allowlist would not
\t# protect the proxied paths.
\troute {
\t\t# remote_ip is the immediate TCP peer. Behind another proxy or Docker's
\t\t# userland proxy that is not the client, and this check means nothing.
\t\t@outside not remote_ip {$ALLOWED_CIDRS:127.0.0.1/32}
\t\tabort @outside

\t\trequest_body {
\t\t\tmax_size ${d.maxBodyMB}MB
\t\t}

\t\t# Matched against the raw request URI, because reverse_proxy forwards the
\t\t# raw path: path and path_regexp see a decoded, dot-cleaned path, so
\t\t# /_plugins/_security/../${d.indexPrefix}-a/_search would match them and still reach
\t\t# the node as written. Any encoding, dot segment, double slash, upper
\t\t# case, comma, wildcard, date math or remote-cluster prefix fails the
\t\t# pattern and gets the 404 below, as do _plugins/_security and the
\t\t# legacy _opendistro/_security paths.
${routeMatchers(d)}
${imports}
\t\trespond 404
\t}
}
${when(d.ui, t`

# Dashboards is a full OpenSearch client for anyone who can log in (the Dev
# Tools console proxies any API call), so the path allowlist above does not
# apply to Dashboards users; their OpenSearch roles do. Caddy only adds the IP
# allowlist, the body limit and TLS here.
{$DASHBOARDS_SITE_ADDRESS:dashboards.localhost} {
\tlog

\troute {
\t\t@outside not remote_ip {$ALLOWED_CIDRS:127.0.0.1/32}
\t\tabort @outside

\t\trequest_body {
\t\t\tmax_size ${d.maxBodyMB}MB
\t\t}

\t\treverse_proxy {$DASHBOARDS_UPSTREAM:osd01:5601}
\t}
}
`)}`;
}

function osRoles(d) {
	const p = d.indexPrefix;
	let scope;
	if (d.readRoute && d.writeRoute) {
		scope = t`
# Same scope as the Elasticsearch app role: search and append documents in the
# ${p}-* indices, nothing else. Not "write" or "crud": those include update and
# delete. No indices:admin/create, so the app cannot create indices by writing
# to a new name; an operator creates them.
app_writer:
  reserved: false
  description: "Search and index documents in ${p}-* only"
`;
	} else if (d.readRoute) {
		scope = t`
# Same scope as the Elasticsearch app role: search the ${p}-* indices, nothing
# else.
app_writer:
  reserved: false
  description: "Search documents in ${p}-* only"
`;
	} else {
		scope = t`
# Same scope as the Elasticsearch app role: append documents to the ${p}-*
# indices, nothing else. Not "write" or "crud": those include update and
# delete. No indices:admin/create, so the app cannot create indices by writing
# to a new name; an operator creates them.
app_writer:
  reserved: false
  description: "Index documents in ${p}-* only"
`;
	}
	const cluster = d.writeRoute ? t`
  cluster_permissions:
    # A _bulk request is authorized at cluster level first, then every item
    # against its own index.
    - "indices:data/write/bulk"
` : '  cluster_permissions: []\n';
	return t`
_meta:
  type: "roles"
  config_version: 2

${scope}${cluster}  index_permissions:
    - index_patterns:
        - "${p}-*"
      allowed_actions:
${when(d.readRoute, '        - "read"\n')}${when(d.writeRoute, t`
        - "indices:data/write/index"
        - "indices:data/write/bulk*"
        - "indices:admin/mapping/put"
`)}`;
}

function osRolesMapping(d) {
	return t`
_meta:
  type: "rolesmapping"
  config_version: 2

# This file replaces the image's roles_mapping.yml, which maps the demo backend
# roles (admin, kibanauser, readall, logstash, snapshotrestore).
all_access:
  reserved: true
  users:
    - "admin"
  description: "Only the admin user gets full access"

app_writer:
  reserved: false
  users:
    - "app_x"
${when(d.ui, t`

# kibana_server is a built-in role; the image maps it the same way.
kibana_server:
  reserved: true
  users:
    - "kibanaserver"
`)}`;
}

function osInternalUsers(d) {
	return t`
_meta:
  type: "internalusers"
  config_version: 2

# Template for security/internal_users.yml, which init-security.sh renders by
# replacing each @@<NAME>_HASH@@ with a bcrypt hash of the <NAME>_PASSWORD in .env.
# The rendered file replaces the image's internal_users.yml, which ships the
# demo users (admin, kibanaserver, readall, ...) with publicly known hashes.
admin:
  hash: "@@ADMIN_HASH@@"
  reserved: true
  description: "Cluster administrator, for operators only"

app_x:
  hash: "@@APP_HASH@@"
  reserved: false
  description: "Application user, mapped to app_writer"
${when(d.ui, t`

kibanaserver:
  hash: "@@KIBANASERVER_HASH@@"
  reserved: true
  description: "OpenSearch Dashboards server user, not for people"
`)}`;
}

function osInitEnv() {
	return t`
#!/usr/bin/env bash
# Writes .env next to this script from .env.example, replacing every change-me
# value with a random one: 32-character passwords with upper case, lower case,
# digits and one of . _ - (the demo installer's admin password rules, though
# nothing checks internal_users.yml passwords), 48 alphanumeric characters for
# *_SECRET keys. Refuses to overwrite an existing .env. Prints key names only.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
env_file="$dir/.env"

if [ -e "$env_file" ]; then
\techo "error: $env_file exists; remove it first to regenerate" >&2
\texit 1
fi

random_chars() {
\tLC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2" || true
}

# The character set leaves out what Compose's .env parser, the curl config
# the tests write and the shell would treat specially: $ # quotes \ space.
random_password() {
\tlocal p
\twhile :; do
\t\tp=$(random_chars 'A-Za-z0-9' 1)$(random_chars 'A-Za-z0-9._-' 31)
\t\t[[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] && $p =~ [._-] ]] && break
\tdone
\tprintf '%s' "$p"
}

umask 077
tmp=$(mktemp "$dir/.env.XXXXXX")
trap 'rm -f "$tmp"' EXIT
generated=()
while IFS= read -r line || [ -n "$line" ]; do
\tcase "$line" in
\t*_SECRET=change-me*)
\t\tgenerated+=("\${line%%=*}")
\t\tprintf '%s=%s\n' "\${line%%=*}" "$(random_chars 'A-Za-z0-9' 48)"
\t\t;;
\t*=change-me*)
\t\tgenerated+=("\${line%%=*}")
\t\tprintf '%s=%s\n' "\${line%%=*}" "$(random_password)"
\t\t;;
\t*) printf '%s\n' "$line" ;;
\tesac
done <"$dir/.env.example" >"$tmp"
mv "$tmp" "$env_file"
trap - EXIT
echo "wrote $env_file (mode 600), generated: \${generated[*]}"
`;
}

function osInitSecurity() {
	return t`
#!/usr/bin/env bash
# Prepares and applies the security plugin configuration of this scenario.
#
#   init-security.sh          render security/internal_users.yml with bcrypt
#                             hashes of the passwords in .env (before first start)
#   init-security.sh --apply  load internal_users.yml, roles.yml and
#                             roles_mapping.yml into the running cluster with
#                             securityadmin.sh and the admin certificate
#
# On the first start the plugin creates its index from the mounted files
# (plugins.security.allow_default_init_securityindex), so --apply is only
# needed after a change. --apply overwrites users and roles created through the
# REST API or Dashboards.
set -euo pipefail

usage() {
\tsed -n '2,13s/^# \{0,1\}//p' "\${BASH_SOURCE[0]}"
}

scenario_dir=$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$scenario_dir/../.." && pwd)
apply=0

while [ $# -gt 0 ]; do
\tcase "$1" in
\t--apply) apply=1; shift ;;
\t-h | --help) usage; exit 0 ;;
\t*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
\tesac
done

die() {
\techo "init-security.sh: $*" >&2
\texit 1
}

[ -f "$scenario_dir/.env" ] || die "no .env; copy .env.example to .env and set the passwords"
# shellcheck disable=SC1091
. "$repo_root/versions.env"

# .env is read the way Compose reads it, not sourced: values may contain spaces
# and shell metacharacters. Only *_PASSWORD and *_SECRET keys are taken.
secrets=()
while IFS= read -r line || [ -n "$line" ]; do
\tcase "$line" in '' | '#'*) continue ;; esac
\tkey="\${line%%=*}"
\tvalue="\${line#*=}"
\t[[ "$key" =~ ^[A-Z0-9_]+_(PASSWORD|SECRET)$ ]] || continue
\tif [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
\t\tvalue="\${BASH_REMATCH[1]}"
\tfi
\texport "$key=$value"
\t[[ "$key" != *_SECRET ]] || secrets+=("$key")
done <"$scenario_dir/.env"

for var in "\${secrets[@]}"; do
\tvalue="\${!var}"
\t[ "\${#value}" -ge 32 ] || die "$var must be at least 32 characters"
\tcase "$value" in *change-me* | *changeme* | *CHANGE-ME* | *CHANGEME*) die "$var still has the .env.example value" ;; esac
done

compose=(docker compose --project-directory "$scenario_dir" --env-file "$repo_root/versions.env"
\t--env-file "$scenario_dir/.env" -f "$scenario_dir/compose.yaml")
security_dir=/usr/share/opensearch/config/opensearch-security
tools=/usr/share/opensearch/plugins/opensearch-security/tools

if [ "$apply" -eq 1 ]; then
\t[ -f "$scenario_dir/security/internal_users.yml" ] || die "security/internal_users.yml missing; run without --apply first"
\tfor pair in internal_users.yml:internalusers roles.yml:roles roles_mapping.yml:rolesmapping; do
\t\tfile="\${pair%%:*}"
\t\ttype="\${pair##*:}"
\t\techo "applying $file"
\t\t# -f/-t loads one configuration type at a time, so action groups,
\t\t# tenants and config.yml in the index are left as they are.
\t\t"\${compose[@]}" exec -T os01 "$tools/securityadmin.sh" \
\t\t\t-f "$security_dir/$file" -t "$type" \
\t\t\t-h os01 -p 9200 -icl \
\t\t\t-cacert /usr/share/opensearch/config/root-ca.pem \
\t\t\t-cert /usr/share/opensearch/config/admin.pem \
\t\t\t-key /usr/share/opensearch/config/admin-key.pem
\tdone
\texit 0
fi

template="$scenario_dir/internal_users.yml.example"
placeholders=$(grep -o '@@[A-Z_]*_HASH@@' "$template" | sort -u)
[ -n "$placeholders" ] || die "no @@<NAME>_HASH@@ placeholders in $template"

# The demo installer enforces strength rules on OPENSEARCH_INITIAL_ADMIN_PASSWORD;
# with the demo configuration disabled nothing checks the passwords in
# internal_users.yml, so this script does a minimum itself.
declare -A hashes
for placeholder in $placeholders; do
\tname="\${placeholder#@@}"
\tname="\${name%_HASH@@}"
\tvar="\${name}_PASSWORD"
\tvalue="\${!var:-}"
\t[ -n "$value" ] || die "$var is not set in .env"
\t[ "\${#value}" -ge 16 ] || die "$var must be at least 16 characters"
\tcase "$value" in *change-me* | *changeme* | *CHANGE-ME* | *CHANGEME*) die "$var still has the .env.example value" ;; esac
\techo "hashing $var"
\t# The password reaches hash.sh through the environment (-env), never argv,
\t# so it does not show up in the process list.
\thash=$(docker run --rm --network none -e "$var" --entrypoint "$tools/hash.sh" \
\t\t"$OPENSEARCH_IMAGE" -env "$var" | grep -E '^\$2[aby]\$' | tail -n 1) ||
\t\tdie "hash.sh failed for $var"
\t[ -n "$hash" ] || die "hash.sh printed no bcrypt hash for $var"
\thashes[$placeholder]="$hash"
done

mkdir -p "$scenario_dir/security"
out="$scenario_dir/security/internal_users.yml"
tmp=$(mktemp "$scenario_dir/security/.internal_users.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cp "$template" "$tmp"
for placeholder in "\${!hashes[@]}"; do
\tPLACEHOLDER="$placeholder" HASH="\${hashes[$placeholder]}" \
\t\tawk '{ gsub(ENVIRON["PLACEHOLDER"], ENVIRON["HASH"]); print }' "$tmp" >"$tmp.new"
\tmv "$tmp.new" "$tmp"
done
! grep -q '@@[A-Z_]*_HASH@@' "$tmp" || die "unreplaced placeholder left in $out"
chmod 0600 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "wrote $out"
if [ "$(id -u)" != 1000 ]; then
\techo "note: the container user is uid 1000; run: sudo chown 1000 $out" >&2
fi
`;
}

function osGenCerts() {
	return t`
#!/usr/bin/env bash
# Generates the lab CA, the os01 node certificate and the security plugin admin
# certificate with openssl. Every output file is git-ignored. The subjects must
# match plugins.security.nodes_dn and plugins.security.authcz.admin_dn in
# ../opensearch.yml; the script checks that before it finishes.
set -euo pipefail

usage() {
\tcat <<'EOF'
usage: gen-certs.sh [--out DIR] [--days N] [--force]

  --out DIR   where to write the files (default: the directory of this script)
  --days N    validity of all certificates in days (default 730)
  --force     overwrite existing files, including the CA

Writes root-ca.pem, root-ca-key.pem, os01.pem, os01-key.pem, admin.pem and
admin-key.pem. Keys are PKCS#8, unencrypted, mode 0600.
EOF
}

script_dir=$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)
out="$script_dir"
days=730
force=0

while [ $# -gt 0 ]; do
\tcase "$1" in
\t--out) out="\${2:?}"; shift 2 ;;
\t--days) days="\${2:?}"; shift 2 ;;
\t--force) force=1; shift ;;
\t-h | --help) usage; exit 0 ;;
\t*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
\tesac
done

die() {
\techo "gen-certs.sh: $*" >&2
\texit 1
}

command -v openssl >/dev/null || die "openssl not found"
[[ "$days" =~ ^[1-9][0-9]*$ ]] || die "--days must be a positive integer"
mkdir -p "$out"
cd "$out"

files=(root-ca.pem root-ca-key.pem os01.pem os01-key.pem admin.pem admin-key.pem)
if [ "$force" -eq 0 ]; then
\tfor f in "\${files[@]}"; do
\t\t[ ! -e "$f" ] || die "$out/$f exists; pass --force to regenerate everything (a new CA invalidates all issued certificates)"
\tdone
fi

subject_base="/O=small-elasticsearch-lab/OU=lab"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

# The security plugin reads PKCS#8 keys only (TLS settings page), so every key
# goes through pkcs8 -topk8 whatever the openssl default output format is.
new_key() {
\topenssl genrsa -out "$work/$1.tmp" 2048 2>/dev/null
\topenssl pkcs8 -topk8 -nocrypt -inform PEM -outform PEM -in "$work/$1.tmp" -out "$1"
}

new_key root-ca-key.pem
openssl req -new -x509 -sha256 -days "$days" -key root-ca-key.pem \
\t-subj "$subject_base/CN=small-elasticsearch-lab root CA" -out root-ca.pem \
\t-addext 'basicConstraints = critical, CA:TRUE, pathlen:0' \
\t-addext 'keyUsage = critical, keyCertSign, cRLSign' \
\t-addext 'subjectKeyIdentifier = hash'

# Transport TLS uses the node certificate as client and server at the same
# time, so it needs both extended key usages. The SAN carries the compose
# service name that Caddy, Dashboards and securityadmin.sh connect to.
cat >"$work/os01.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:os01, DNS:localhost, IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

cat >"$work/admin.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

issue() {
\tlocal name="$1" cn="$2"
\tnew_key "$name-key.pem"
\topenssl req -new -sha256 -key "$name-key.pem" -subj "$subject_base/CN=$cn" -out "$work/$name.csr"
\topenssl x509 -req -sha256 -days "$days" -in "$work/$name.csr" \
\t\t-CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -CAserial "$work/root-ca.srl" \
\t\t-extfile "$work/$name.ext" -out "$name.pem" 2>/dev/null
}

issue os01 os01
issue admin admin
chmod 0644 root-ca.pem os01.pem admin.pem
chmod 0600 root-ca-key.pem os01-key.pem admin-key.pem

openssl verify -CAfile root-ca.pem os01.pem admin.pem

node_dn=$(openssl x509 -in os01.pem -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
admin_dn=$(openssl x509 -in admin.pem -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
echo "node DN:  $node_dn"
echo "admin DN: $admin_dn"

config="$script_dir/../opensearch.yml"
if [ -f "$config" ]; then
\tgrep -qF "'$node_dn'" "$config" || die "node DN '$node_dn' is not listed in $config (plugins.security.nodes_dn)"
\tgrep -qF "'$admin_dn'" "$config" || die "admin DN '$admin_dn' is not listed in $config (plugins.security.authcz.admin_dn)"
fi

# The OpenSearch image runs as uid 1000 and reads the keys through bind mounts.
if [ "$(id -u)" != 1000 ]; then
\techo "note: you are uid $(id -u), the container user is uid 1000; it cannot read keys with mode 0600." >&2
\techo "      run: sudo chown 1000 $out/os01-key.pem $out/admin-key.pem" >&2
fi
`;
}
