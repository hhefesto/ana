#!/usr/bin/env bash
# mix-corpus.sh — interleave N JSONL sources in fixed proportions.
#
# Generalizes build-mixed-corpus.sh's two-FIFO round-robin. That version had a
# failure mode this one prevents: when one stream runs dry the others keep
# draining, so the tail of the corpus becomes a pure block of whatever is left.
# For a curriculum that is exactly backwards -- the model finishes on an
# unrepresentative diet -- and it is invisible in the output.
#
# Usage:
#   deploy/mix-corpus.sh OUT.jsonl SOURCE.jsonl:PER_ROUND[:REPEATS|:cycle] ...
#
# PER_ROUND sets the ratio: with `a.jsonl:7 b.jsonl:3` each round emits 7
# documents of a then 3 of b.  A small source holds its share of a long corpus
# in one of two ways:
#
#   :REPEATS   pre-expands it a fixed number of times.  Use when the total
#              share should be capped (the user's-code 30x case).
#   :cycle     restarts it every time it drains, until every non-cycling
#              source is exhausted.  Use when the source must hold its ratio
#              to the very end of the mix.  At least one source must NOT
#              cycle, or the mix would never terminate.
#
# Either way every copy gets a distinct id suffix (#r<n> / #c<n>), because
# Artifact rejects a duplicate id and kills the whole shard -- and for the
# same reason the output's ids are checked for uniqueness across sources
# before the file is renamed into place (CHECK_IDS=0 skips it).
#
# One trap this cannot solve for you: ratios apply to DOCUMENTS, and the
# trainer's unit is the WINDOW.  Sources with different document lengths give
# a window mix quite unlike the document mix, so the summary reports byte
# share as well -- a far better proxy for windows -- and the plan's
# train_windows is the only real confirmation.
#
# And one it refuses to hide: anything repeated or cycled lands on both sides
# of the trainer's position-hashed train/validation split, so it must be
# excluded from held-out eval populations (the repeated ids make that
# mechanically checkable: grep for '#r' / '#c').
set -euo pipefail

OUT="${1:?usage: mix-corpus.sh OUT.jsonl SOURCE:PER[:REPEATS|:cycle] ...}"
shift
[ "$#" -ge 1 ] || { echo "mix-corpus: need at least one source" >&2; exit 1; }

work="$(mktemp -d)"
feeders=()
trap '((${#feeders[@]})) && kill "${feeders[@]}" 2>/dev/null; rm -rf "$work"' EXIT

paths=(); pers=(); cycles=()
index=0
anchored=0
for spec in "$@"; do
  path="${spec%%:*}"; rest="${spec#*:}"
  per="${rest%%:*}"
  if [ "$rest" = "$per" ]; then repeats=1; else repeats="${rest#*:}"; fi
  test -f "$path" || { echo "mix-corpus: no such source: $path" >&2; exit 1; }
  case "$per" in ''|*[!0-9]*) echo "mix-corpus: PER_ROUND must be a positive integer: $spec" >&2; exit 1 ;; esac
  [ "$per" -gt 0 ] || { echo "mix-corpus: PER_ROUND must be positive: $spec" >&2; exit 1; }

  stream="$work/src-$index"
  cycling=0
  if [ "$repeats" = cycle ]; then
    # An endless feeder behind a FIFO: the mixer reads it like any file, the
    # FIFO's backpressure keeps memory O(1), and each pass gets a fresh #c<n>
    # id suffix from jq -- the only place the JSON is ever touched.
    cycling=1
    mkfifo "$stream"
    ( r=0
      while :; do
        jq -c --arg r "$r" '.id = .id + "#c" + $r' < "$path" || exit 1
        r=$((r+1))
      done > "$stream"
    ) &
    feeders+=("$!")
  elif [ "$repeats" -le 1 ] 2>/dev/null; then
    ln -s "$(readlink -f "$path")" "$stream"
    anchored=1
  else
    # Pre-expansion rather than rewinding mid-stream: it keeps the mixer a
    # plain round-robin, and suffixing ids here is the only place the JSON is
    # touched, by jq, which cannot corrupt an escape the way awk would.
    : > "$stream"
    for (( r = 0; r < repeats; r++ )); do
      jq -c --arg r "$r" '.id = .id + "#r" + $r' < "$path" >> "$stream"
    done
    echo "mix-corpus: $path repeated ${repeats}x ($(wc -l < "$stream") documents)" >&2
    anchored=1
  fi
  paths+=("$stream"); pers+=("$per"); cycles+=("$cycling")
  index=$((index+1))
done
[ "$anchored" = 1 ] || { echo "mix-corpus: every source cycles; the mix would never end" >&2; exit 1; }

# Round-robin. getline on each stream keeps this O(1) in memory regardless of
# corpus size, which is what a 36 GB source requires.  LC_ALL=C so length() is
# BYTES: in a UTF-8 locale it counts characters, and Agda/Lean's three-byte
# glyphs would be undercounted by up to 3x in exactly the share being tuned.
LC_ALL=C awk -v n="$index" \
    -v files="$(IFS=,; echo "${paths[*]}")" \
    -v counts="$(IFS=,; echo "${pers[*]}")" \
    -v cyclers="$(IFS=,; echo "${cycles[*]}")" \
    -v names="$(IFS=,; echo "$*")" '
BEGIN {
  split(files, f, ","); split(counts, c, ","); split(cyclers, cy, ","); split(names, label, ",")
  alive = 0
  for (i = 1; i <= n; i++) {
    live[i] = 1; emitted[i] = 0; bytes[i] = 0; dry[i] = -1
    if (!cy[i]) alive++
  }
  total = 0; failed = 0
  # The mix ends when every NON-cycling source is exhausted; cycling sources
  # by construction never run dry (their feeder restarts them), so one going
  # dry means its feeder died -- an error, not an end.
  while (alive > 0) {
    for (i = 1; i <= n; i++) {
      if (!live[i]) continue
      for (j = 0; j < c[i]; j++) {
        if ((getline line < f[i]) > 0) {
          print line; total++; emitted[i]++; bytes[i] += length(line) + 1
        } else {
          live[i] = 0; dry[i] = total
          if (cy[i]) { printf "mix-corpus: cycling source %s ran dry -- its feeder died\n", label[i] > "/dev/stderr"; failed = 1 }
          else alive--
          break
        }
      }
      if (failed) exit 1
    }
  }
  printf "mix-corpus: %d documents\n", total > "/dev/stderr"
  allbytes = 0
  for (i = 1; i <= n; i++) allbytes += bytes[i]
  for (i = 1; i <= n; i++) {
    printf "  %-40s %9d docs (%5.1f%%)  %6.1f%% of bytes", \
      label[i], emitted[i], total ? 100 * emitted[i] / total : 0, \
      allbytes ? 100 * bytes[i] / allbytes : 0 > "/dev/stderr"
    # A non-cycling source that runs dry well before the end leaves the
    # remaining output unrepresentative. Saying so is the point of this line;
    # give such a source :cycle if it must hold its ratio throughout.
    if (!cy[i] && dry[i] >= 0 && dry[i] < 0.98 * total)
      printf "  -- RAN DRY at %.1f%% of the output", total ? 100 * dry[i] / total : 0 > "/dev/stderr"
    printf "\n" > "/dev/stderr"
  }
}' > "$OUT.tmp"

# Duplicate ids invalidate an entire shard thousands of steps into a paid run,
# so refuse to hand over a mix whose sources' id spaces collide.
if [ "${CHECK_IDS:-1}" = 1 ]; then
  # No head/sed in this pipe: an early close would SIGPIPE uniq under
  # pipefail exactly when duplicates exist, dying without the message.
  jq -r '.id' < "$OUT.tmp" | LC_ALL=C sort -T "$work" | uniq -d > "$work/dups"
  if [ -s "$work/dups" ]; then
    echo "mix-corpus: duplicate ids across sources, refusing:" >&2
    sed 's/^/  /;3q' "$work/dups" >&2
    exit 1
  fi
fi
mv "$OUT.tmp" "$OUT"
echo "mix-corpus: wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
