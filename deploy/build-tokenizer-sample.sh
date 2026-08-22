#!/usr/bin/env bash
# build-tokenizer-sample.sh — assemble the NUL-framed stream that `learn-bpe`
# trains on, in deliberate byte proportions.
#
# BPE learns from a word-frequency table, so the sample's composition decides
# how the 32,768 pieces are divided between English and code. Two facts shape
# the default mix:
#
#   Agda and Lean are a small share of the corpus but their notation
#   (forall, ->, lambda, ==, |-) is 3-byte UTF-8, and each glyph stays three
#   separate byte-tokens unless it clears MIN_FREQUENCY in THIS sample. They
#   are therefore deliberately oversampled relative to their corpus share.
#
#   The budget is shared: pieces spent on code are not spent on English. That
#   tension is why the 50/50 split was measured rather than assumed -- at this
#   mix, held-out prose moved -0.04% while code improved 39.5%.
#
# Sampling is strided, never a prefix: these corpora are ordered (Wikipedia by
# article, code by package name), so a head is not a sample. The stride is
# chosen coprime with 5 because mixed-corpus.jsonl interleaves wiki and FineWeb
# with period 5, and a stride sharing that factor returns one source only.
#
# Usage:
#   deploy/build-tokenizer-sample.sh OUT.nul SOURCE.jsonl:MB[:ID_REGEX] ...
set -euo pipefail

OUT="${1:?usage: build-tokenizer-sample.sh OUT.nul SOURCE.jsonl:MB[:ID_REGEX] ...}"
shift
[ "$#" -ge 1 ] || { echo "build-tokenizer-sample: need at least one source" >&2; exit 1; }

: > "$OUT"
for spec in "$@"; do
  path="${spec%%:*}"; rest="${spec#*:}"
  mb="${rest%%:*}"
  if [ "$rest" = "$mb" ]; then pattern=""; else pattern="${rest#*:}"; fi
  test -f "$path" || { echo "build-tokenizer-sample: no such source: $path" >&2; exit 1; }
  budget=$(( mb * 1000000 ))

  # Restrict to the requested languages first, so the stride is computed over
  # what will actually be drawn from rather than over the whole file.
  work="$OUT.filtered"
  if [ -n "$pattern" ]; then
    jq -c --arg p "$pattern" 'select(.id | test($p))' < "$path" > "$work"
  else
    ln -sf "$(readlink -f "$path")" "$work"
  fi

  # stat, not `wc -c`: wc reads the whole file, and the English source is
  # 36 GB. The line count is only ever printed, so it is not worth a second
  # full pass either -- the stride below is chosen from bytes.
  available=$(stat -Lc %s "$work")
  if [ "$available" -le "$budget" ]; then
    stride=1
  else
    stride=$(( available / budget ))
    # Walk DOWN to the nearest stride coprime with 10. Coprimality matters
    # because mixed-corpus.jsonl interleaves wiki and FineWeb with period 5, so
    # a stride sharing that factor samples one source only -- the error that
    # made an earlier corpus measurement report 99% FineWeb. Downward rather
    # than upward so the sample still fills its budget; two guards applied in
    # sequence walked 4 up to 5, which is precisely the value to avoid.
    while [ "$stride" -gt 1 ] && { [ $(( stride % 2 )) -eq 0 ] || [ $(( stride % 5 )) -eq 0 ]; }; do
      stride=$(( stride - 1 ))
    done
  fi

  taken=$(awk -v s="$stride" -v b="$budget" 'NR % s == 0 { print; n += length($0) + 1; if (n >= b) exit }' \
    < "$work" \
    | jq --raw-output0 '.id, (.text | explode | map(select(. != 0)) | implode)' \
    | tee -a "$OUT" | wc -c)
  printf 'build-tokenizer-sample: %-34s %4d MB requested, %4d MB taken (stride %d over %d MB)\n' \
    "$(basename "$path")${pattern:+ [$pattern]}" "$mb" "$(( taken / 1000000 ))" "$stride" "$(( available / 1000000 ))" >&2
  rm -f "$work"
done

echo "build-tokenizer-sample: wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
