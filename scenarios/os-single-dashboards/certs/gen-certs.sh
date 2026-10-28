#!/usr/bin/env bash
# Generates the lab CA, the os01 node certificate and the security plugin admin
# certificate with openssl. Every output file is git-ignored. The subjects must
# match plugins.security.nodes_dn and plugins.security.authcz.admin_dn in
# ../opensearch.yml; the script checks that before it finishes.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: gen-certs.sh [--out DIR] [--days N] [--force]

  --out DIR   where to write the files (default: the directory of this script)
  --days N    validity of all certificates in days (default 730)
  --force     overwrite existing files, including the CA

Writes root-ca.pem, root-ca-key.pem, os01.pem, os01-key.pem, admin.pem and
admin-key.pem. Keys are PKCS#8, unencrypted, mode 0600.
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out="$script_dir"
days=730
force=0

while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="${2:?}"; shift 2 ;;
	--days) days="${2:?}"; shift 2 ;;
	--force) force=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

die() {
	echo "gen-certs.sh: $*" >&2
	exit 1
}

command -v openssl >/dev/null || die "openssl not found"
[[ "$days" =~ ^[1-9][0-9]*$ ]] || die "--days must be a positive integer"
mkdir -p "$out"
cd "$out"

files=(root-ca.pem root-ca-key.pem os01.pem os01-key.pem admin.pem admin-key.pem)
if [ "$force" -eq 0 ]; then
	for f in "${files[@]}"; do
		[ ! -e "$f" ] || die "$out/$f exists; pass --force to regenerate everything (a new CA invalidates all issued certificates)"
	done
fi

subject_base="/O=small-elasticsearch-lab/OU=lab"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

# The security plugin reads PKCS#8 keys only (TLS settings page), so every key
# goes through pkcs8 -topk8 whatever the openssl default output format is.
new_key() {
	openssl genrsa -out "$work/$1.tmp" 2048 2>/dev/null
	openssl pkcs8 -topk8 -nocrypt -inform PEM -outform PEM -in "$work/$1.tmp" -out "$1"
}

new_key root-ca-key.pem
openssl req -new -x509 -sha256 -days "$days" -key root-ca-key.pem \
	-subj "$subject_base/CN=small-elasticsearch-lab root CA" -out root-ca.pem \
	-addext 'basicConstraints = critical, CA:TRUE, pathlen:0' \
	-addext 'keyUsage = critical, keyCertSign, cRLSign' \
	-addext 'subjectKeyIdentifier = hash'

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
	local name="$1" cn="$2"
	new_key "$name-key.pem"
	openssl req -new -sha256 -key "$name-key.pem" -subj "$subject_base/CN=$cn" -out "$work/$name.csr"
	openssl x509 -req -sha256 -days "$days" -in "$work/$name.csr" \
		-CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -CAserial "$work/root-ca.srl" \
		-extfile "$work/$name.ext" -out "$name.pem" 2>/dev/null
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
	grep -qF "'$node_dn'" "$config" || die "node DN '$node_dn' is not listed in $config (plugins.security.nodes_dn)"
	grep -qF "'$admin_dn'" "$config" || die "admin DN '$admin_dn' is not listed in $config (plugins.security.authcz.admin_dn)"
fi

# The OpenSearch image runs as uid 1000 and reads the keys through bind mounts.
if [ "$(id -u)" != 1000 ]; then
	echo "note: you are uid $(id -u), the container user is uid 1000; it cannot read keys with mode 0600." >&2
	echo "      run: sudo chown 1000 $out/os01-key.pem $out/admin-key.pem" >&2
fi
