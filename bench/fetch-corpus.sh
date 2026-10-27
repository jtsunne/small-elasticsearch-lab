#!/usr/bin/env bash
# Downloads a benchmark corpus from the Rally track hosting and verifies it.
#
# File names, document counts and byte sizes come from the official track
# definitions (github.com/elastic/rally-tracks, http_logs/track.json and
# geonames/track.json; the same values are in opensearch-benchmark-workloads),
# read on 2026-10-26. Neither project publishes content checksums, so SHA-256
# sums are trust-on-first-use: --record-checksums writes them to
# bench/corpus.sha256, which is meant to be committed, and every later run
# verifies against it.
set -euo pipefail

BASE_URL="${CORPUS_BASE_URL:-https://rally-tracks.elastic.co}"

# corpus|file|documents|compressed bytes|uncompressed bytes
CORPUS_FILES="
http_logs|documents-181998.json.bz2|2708746|13843641|363512754
http_logs|documents-191998.json.bz2|9697882|49546887|1301732149
http_logs|documents-201998.json.bz2|13053463|65759419|1744012279
http_logs|documents-211998.json.bz2|17647279|88445049|2364230815
http_logs|documents-221998.json.bz2|10716760|54274027|1438320123
http_logs|documents-231998.json.bz2|11961342|61043842|1597530673
http_logs|documents-241998.json.bz2|181463624|907295259|24555905444
geonames|documents-2.json.bz2|11396503|265208777|3547613828
"

usage() {
	cat <<'EOF'
usage: fetch-corpus.sh CORPUS [options]

  CORPUS                http_logs or geonames
  --dir DIR             target directory (default bench/corpus)
  --accept-terms        required for http_logs, see below
  --record-checksums    write missing SHA-256 sums to bench/corpus.sha256 instead of failing
  --keep-compressed     keep the .bz2 files after decompression

http_logs is derived from the 1998 World Cup web server logs
(https://ita.ee.lbl.gov/html/contrib/WorldCup.html, Hewlett-Packard copyright
notice). The OpenSearch benchmark project removed its hosted copy pending a
data-licence review; the Rally hosting still serves it. Read the original terms
and pass --accept-terms if you are entitled to use the data.

geonames is under CC BY 3.0 (https://www.geonames.org/).
EOF
}

corpus=""
dir=""
accept=0
record=0
keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--dir) dir="${2:?}"; shift 2 ;;
	--accept-terms) accept=1; shift ;;
	--record-checksums) record=1; shift ;;
	--keep-compressed) keep=1; shift ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	*) corpus="$1"; shift ;;
	esac
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir="${dir:-$repo_root/bench/corpus}"
sums_file="$repo_root/bench/corpus.sha256"

case "$corpus" in
http_logs | geonames) ;;
*) usage >&2; exit 2 ;;
esac
if [ "$corpus" = http_logs ] && [ "$accept" -ne 1 ]; then
	echo "http_logs needs --accept-terms; see --help for the data licence situation" >&2
	exit 2
fi

missing=()
for tool in curl bzip2 sha256sum wc stat; do
	command -v "$tool" >/dev/null || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "missing tools: ${missing[*]}" >&2
	exit 1
fi
bunzip=(bzip2 -dc)
if command -v lbzip2 >/dev/null; then
	bunzip=(lbzip2 -dc)
elif command -v pbzip2 >/dev/null; then
	bunzip=(pbzip2 -dc)
fi

files=$(awk -F'|' -v c="$corpus" '$1 == c' <<<"$CORPUS_FILES")
if [ -z "$files" ]; then
	echo "no file list for corpus $corpus" >&2
	exit 1
fi

mkdir -p "$dir/$corpus"
fail=0

expected_sum() {
	[ -f "$sums_file" ] || return 0
	awk -v f="$1" '$2 == f || $2 == "*" f { print $1; exit }' "$sums_file"
}

while IFS='|' read -r _ file docs csize usize; do
	bz="$dir/$corpus/$file"
	json="${bz%.bz2}"
	key="$corpus/$file"

	if [ -f "$json" ] && [ "$(stat -c %s "$json")" = "$usize" ] && [ ! -f "$bz" ]; then
		echo "$key: decompressed file present with the expected size, not re-verifying the archive"
		continue
	fi

	if [ ! -f "$bz" ] || [ "$(stat -c %s "$bz")" != "$csize" ]; then
		echo "$key: downloading"
		curl -fL --retry 3 --retry-delay 5 -C - -o "$bz" "$BASE_URL/$corpus/$file"
	fi
	got=$(stat -c %s "$bz")
	if [ "$got" != "$csize" ]; then
		echo "$key: size $got, expected $csize" >&2
		fail=1
		continue
	fi

	sum=$(sha256sum "$bz" | awk '{ print $1 }')
	want=$(expected_sum "$key")
	if [ -z "$want" ]; then
		if [ "$record" -eq 1 ]; then
			echo "$sum  $key" >>"$sums_file"
			echo "$key: recorded sha256 $sum (trust on first use, commit bench/corpus.sha256)"
		else
			echo "$key: no recorded sha256 in bench/corpus.sha256; rerun with --record-checksums to record $sum" >&2
			fail=1
			continue
		fi
	elif [ "$sum" != "$want" ]; then
		echo "$key: sha256 $sum does not match recorded $want" >&2
		fail=1
		continue
	fi

	echo "$key: decompressing with ${bunzip[0]}"
	"${bunzip[@]}" "$bz" >"$json.part"
	gotu=$(stat -c %s "$json.part")
	lines=$(wc -l <"$json.part")
	if [ "$gotu" != "$usize" ] || [ "$lines" != "$docs" ]; then
		echo "$key: decompressed to $gotu bytes and $lines lines, expected $usize and $docs" >&2
		rm -f "$json.part"
		fail=1
		continue
	fi
	mv "$json.part" "$json"
	[ "$keep" -eq 1 ] || rm -f "$bz"
	echo "$key: ok ($docs documents)"
done <<<"$files"

if [ "$fail" -ne 0 ]; then
	echo "corpus $corpus: verification failed" >&2
	exit 1
fi
echo "corpus $corpus: ready in $dir/$corpus"
