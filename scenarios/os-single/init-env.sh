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
	echo "error: $env_file exists; remove it first to regenerate" >&2
	exit 1
fi

random_chars() {
	LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2" || true
}

# The character set leaves out what Compose's .env parser, the curl config
# the tests write and the shell would treat specially: $ # quotes \ space.
random_password() {
	local p
	while :; do
		p=$(random_chars 'A-Za-z0-9' 1)$(random_chars 'A-Za-z0-9._-' 31)
		[[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] && $p =~ [._-] ]] && break
	done
	printf '%s' "$p"
}

umask 077
tmp=$(mktemp "$dir/.env.XXXXXX")
trap 'rm -f "$tmp"' EXIT
generated=()
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
	*_SECRET=change-me*)
		generated+=("${line%%=*}")
		printf '%s=%s\n' "${line%%=*}" "$(random_chars 'A-Za-z0-9' 48)"
		;;
	*=change-me*)
		generated+=("${line%%=*}")
		printf '%s=%s\n' "${line%%=*}" "$(random_password)"
		;;
	*) printf '%s\n' "$line" ;;
	esac
done <"$dir/.env.example" >"$tmp"
mv "$tmp" "$env_file"
trap - EXIT
echo "wrote $env_file (mode 600), generated: ${generated[*]}"
