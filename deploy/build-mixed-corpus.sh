#!/usr/bin/env bash
# build-mixed-corpus.sh — assemble one JSONL {id, text} corpus from Wikipedia
# plus a directory of web-corpus shards, interleaved.
#
# Interleaving is the whole point, not a tidiness detail. The trainer consumes
# shards in file order under a single cosine schedule, so concatenating sources
# would make the run a curriculum: all Wikipedia first, all web text last. The
# 2026-07-25 run already showed how much the tail matters -- because the
# Wikipedia dump is article-ordered, its final shards are the stub tail, and
# reading the training log's last decile as "the model's quality" overstated it
# by 0.1 bpb. Interleaving makes every shard, and therefore every held-out
# split and every point on the loss curve, a representative sample of the whole
# mixture.
#
# The ratio is documents, not bytes: Wikipedia articles are longer than web
# documents, so a 3:4 document ratio lands near an even token split.
#
# The web side may be parquet (FineWeb-Edu) or gzipped JSONL (C4). Parquet is
# read through duckdb, which also lets the English filter run in the reader.
# FineWeb-Edu is English-only by construction -- it derives from FineWeb, which
# keeps only `en`, and the multilingual set is FineWeb-2 -- but it carries a
# `language` column, so filtering on it is free insurance rather than a claim
# taken on trust.
#
# Usage:
#   deploy/build-mixed-corpus.sh OUTPUT.jsonl WIKI.jsonl WEB_DIR [WIKI_PER WEB_PER]
set -euo pipefail

OUT="${1:?usage: build-mixed-corpus.sh OUTPUT.jsonl WIKI.jsonl WEB_DIR [WIKI_PER WEB_PER]}"
WIKI="${2:?missing Wikipedia JSONL}"
WEBDIR="${3:?missing web-corpus directory}"
WIKI_PER="${4:-3}"
WEB_PER="${5:-4}"

test -f "$WIKI" || { echo "build-mixed-corpus: no such file: $WIKI" >&2; exit 1; }
test -d "$WEBDIR" || { echo "build-mixed-corpus: no such directory: $WEBDIR" >&2; exit 1; }
shopt -s nullglob
parquets=("$WEBDIR"/*.parquet)
gzips=("$WEBDIR"/*.json.gz)
if [ ${#parquets[@]} -gt 0 ]; then
  kind=parquet
  shards=("${parquets[@]}")
  command -v duckdb >/dev/null \
    || { echo "build-mixed-corpus: duckdb is required to read parquet (try: nix shell nixpkgs#duckdb)" >&2; exit 1; }
elif [ ${#gzips[@]} -gt 0 ]; then
  kind=jsongz
  shards=("${gzips[@]}")
else
  echo "build-mixed-corpus: no *.parquet or *.json.gz under $WEBDIR" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkfifo "$work/wiki" "$work/web"

# Wikipedia lines already carry .id and .text, so they pass through verbatim --
# no parse/serialize round trip over 19 GB.
cat "$WIKI" > "$work/wiki" &

# Emit {id, text} per web document. FineWeb-Edu already has a unique id, so
# nothing is synthesised there. C4 has none, and its ordinal comes from an
# explicit foreach counter rather than jq's input_line_number, which is not a
# record counter: on C4 shard 0 it repeats a value at record 11243, and a
# duplicate id invalidates an entire corpus artifact only once the shard
# containing it is prepared -- thousands of shards later.
{
  for shard in "${shards[@]}"; do
    if [ "$kind" = parquet ]; then
      duckdb -c "COPY (SELECT id, text FROM read_parquet('$shard') WHERE language = 'en') TO '/dev/stdout' (FORMAT JSON)"
    else
      name="$(basename "$shard" .json.gz)"
      gunzip -c "$shard" \
        | jq -cn --arg p "$name" \
            'foreach inputs as $r (0; . + 1; {id: ($p + "-" + (.|tostring)), text: $r.text})'
    fi
  done
} > "$work/web" &

echo "build-mixed-corpus: ${#shards[@]} $kind web shards, ratio ${WIKI_PER} wiki : ${WEB_PER} web" >&2

# Round-robin both streams. getline on a FIFO keeps this O(1) in memory
# regardless of corpus size.
awk -v wf="$work/wiki" -v cf="$work/web" -v wn="$WIKI_PER" -v cn="$WEB_PER" '
BEGIN {
  wok = 1; cok = 1; emitted = 0
  while (wok || cok) {
    for (i = 0; i < wn && wok; i++) {
      if ((getline line < wf) > 0) { print line; emitted++ } else wok = 0
    }
    for (i = 0; i < cn && cok; i++) {
      if ((getline line < cf) > 0) { print line; emitted++ } else cok = 0
    }
  }
  printf "build-mixed-corpus: %d documents\n", emitted > "/dev/stderr"
}' > "$OUT"

wait
echo "build-mixed-corpus: wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
