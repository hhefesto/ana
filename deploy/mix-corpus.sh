#!/usr/bin/env bash
# mix-corpus.sh — interleave N JSONL sources in fixed proportions.
#
# Generalizes build-mixed-corpus.sh's two-FIFO round-robin. That version had a
# failure mode this one reports rather than hides: when one stream runs dry the
# others keep draining, so the tail of the corpus becomes a pure block of
# whatever is left. For a curriculum that is exactly backwards -- the model
# finishes on an unrepresentative diet -- and it is invisible in the output.
#
# Usage:
#   deploy/mix-corpus.sh OUT.jsonl SOURCE.jsonl:PER_ROUND[:REPEATS] ...
#
# PER_ROUND sets the ratio: with `a.jsonl:7 b.jsonl:3` each round emits 7
# documents of a then 3 of b. REPEATS pre-expands a small source so it can hold
# its share of a long corpus without running dry -- each copy gets a distinct
# id suffix, because Artifact rejects a duplicate id and kills the whole shard.
#
# Two traps this cannot solve for you:
#
#   Ratios apply to DOCUMENTS, and the trainer's unit is the WINDOW. Sources
#   with different document lengths give a window mix quite unlike the document
#   mix, so the summary below reports byte share as well -- a far better proxy
#   for windows -- and the plan's train_windows is the only real confirmation.
#
#   The train/validation split is a hash of document POSITION, not content
#   (FormalTransformer.Data), so a repeated source lands on both sides of it.
#   Anything given REPEATS > 1 must be excluded from held-out eval populations.
set -euo pipefail

OUT="${1:?usage: mix-corpus.sh OUT.jsonl SOURCE:PER[:REPEATS] ...}"
shift
[ "$#" -ge 1 ] || { echo "mix-corpus: need at least one source" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

paths=(); pers=()
index=0
for spec in "$@"; do
  path="${spec%%:*}"; rest="${spec#*:}"
  per="${rest%%:*}"
  if [ "$rest" = "$per" ]; then repeats=1; else repeats="${rest#*:}"; fi
  test -f "$path" || { echo "mix-corpus: no such source: $path" >&2; exit 1; }
  case "$per" in ''|*[!0-9]*) echo "mix-corpus: PER_ROUND must be a positive integer: $spec" >&2; exit 1 ;; esac
  [ "$per" -gt 0 ] || { echo "mix-corpus: PER_ROUND must be positive: $spec" >&2; exit 1; }

  stream="$work/src-$index"
  if [ "$repeats" -le 1 ]; then
    ln -s "$(readlink -f "$path")" "$stream"
  else
    # Pre-expansion rather than rewinding mid-stream: it keeps the mixer a
    # plain round-robin, and suffixing ids here is the only place the JSON is
    # touched, by jq, which cannot corrupt an escape the way awk would.
    : > "$stream"
    for (( r = 0; r < repeats; r++ )); do
      jq -c --arg r "$r" '.id = .id + "#r" + $r' < "$path" >> "$stream"
    done
    echo "mix-corpus: $path repeated ${repeats}x ($(wc -l < "$stream") documents)" >&2
  fi
  paths+=("$stream"); pers+=("$per")
  index=$((index+1))
done

# Round-robin. getline on each stream keeps this O(1) in memory regardless of
# corpus size, which is what a 36 GB source requires.
awk -v n="$index" \
    -v files="$(IFS=,; echo "${paths[*]}")" \
    -v counts="$(IFS=,; echo "${pers[*]}")" \
    -v names="$(IFS=,; echo "$*")" '
BEGIN {
  split(files, f, ","); split(counts, c, ","); split(names, label, ",")
  for (i = 1; i <= n; i++) { live[i] = 1; emitted[i] = 0; bytes[i] = 0; dry[i] = -1 }
  total = 0; alive = n
  while (alive > 0) {
    for (i = 1; i <= n; i++) {
      if (!live[i]) continue
      for (j = 0; j < c[i]; j++) {
        if ((getline line < f[i]) > 0) {
          print line; total++; emitted[i]++; bytes[i] += length(line) + 1
        } else {
          live[i] = 0; alive--; dry[i] = total
          break
        }
      }
    }
  }
  printf "mix-corpus: %d documents\n", total > "/dev/stderr"
  allbytes = 0
  for (i = 1; i <= n; i++) allbytes += bytes[i]
  for (i = 1; i <= n; i++) {
    printf "  %-40s %9d docs (%5.1f%%)  %6.1f%% of bytes", \
      label[i], emitted[i], 100 * emitted[i] / total, 100 * bytes[i] / allbytes > "/dev/stderr"
    # A source that runs dry well before the end leaves the remaining output
    # unrepresentative. Saying so is the whole point of this summary.
    if (dry[i] >= 0 && dry[i] < 0.98 * total)
      printf "  -- RAN DRY at %.1f%% of the output", 100 * dry[i] / total > "/dev/stderr"
    printf "\n" > "/dev/stderr"
  }
}' > "$OUT"

echo "mix-corpus: wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
