#!/usr/bin/env bash
# Writes .env next to this script from .env.example with random alphanumeric
# passwords. Refuses to overwrite an existing .env.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
env_file="$dir/.env"

if [ -e "$env_file" ]; then
	echo "error: $env_file exists; remove it first to regenerate" >&2
	exit 1
fi

random_secret() {
	LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true
}

umask 077
while IFS= read -r line; do
	case "$line" in
	*=change-me*) printf '%s=%s\n' "${line%%=*}" "$(random_secret 32)" ;;
	*) printf '%s\n' "$line" ;;
	esac
done <"$dir/.env.example" >"$env_file"
echo "wrote $env_file (mode 600)"
