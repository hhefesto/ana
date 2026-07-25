#!/usr/bin/env bash
# build-mixed-corpus.sh — assemble one JSONL {id, text} corpus from Wikipedia
# plus a directory of C4 shards, interleaved.
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
# Usage:
#   deploy/build-mixed-corpus.sh OUTPUT.jsonl WIKI.jsonl C4_DIR [WIKI_PER CN_PER]
set -euo pipefail

OUT="${1:?usage: build-mixed-corpus.sh OUTPUT.jsonl WIKI.jsonl C4_DIR [WIKI_PER C4_PER]}"
WIKI="${2:?missing Wikipedia JSONL}"
C4DIR="${3:?missing C4 directory}"
WIKI_PER="${4:-3}"
C4_PER="${5:-4}"

test -f "$WIKI" || { echo "build-mixed-corpus: no such file: $WIKI" >&2; exit 1; }
test -d "$C4DIR" || { echo "build-mixed-corpus: no such directory: $C4DIR" >&2; exit 1; }
shopt -s nullglob
shards=("$C4DIR"/*.json.gz)
[ ${#shards[@]} -gt 0 ] || { echo "build-mixed-corpus: no *.json.gz under $C4DIR" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkfifo "$work/wiki" "$work/c4"

# Wikipedia lines already carry .id and .text, so they pass through verbatim --
# no parse/serialize round trip over 19 GB.
cat "$WIKI" > "$work/wiki" &

# C4 has no id field; synthesise a stable one from the shard name and the
# record's line number, so the same inputs always produce the same ids.
{
  for shard in "${shards[@]}"; do
    name="$(basename "$shard" .json.gz)"
    gunzip -c "$shard" \
      | jq -c --arg p "$name" '{id: ($p + "-" + (input_line_number|tostring)), text: .text}'
  done
} > "$work/c4" &

echo "build-mixed-corpus: ${#shards[@]} C4 shards, ratio ${WIKI_PER} wiki : ${C4_PER} c4" >&2

# Round-robin both streams. getline on a FIFO keeps this O(1) in memory
# regardless of corpus size.
awk -v wf="$work/wiki" -v cf="$work/c4" -v wn="$WIKI_PER" -v cn="$C4_PER" '
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
