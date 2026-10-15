#!/usr/bin/env bash
# steady-mix.sh OUT.jsonl SRC.jsonl:BYTES ... (2026-10-07): a raw mix whose
# language shares hold from its first line to its last.
#
# Run 2's mix (rawshards.sh mix, unwired 2026-10-14 since this file replaced it: `deploy mix` with per-round shares set by
# token share) ran raw Agda dry at 72.8% of its output and Lean at 94.1%, so
# the last quarter of run 2, its whole low-learning-rate phase, trained on
# almost no Agda and, at the end, half the Lean (run/v2/remix-mix.log,
# project memory run2). Here every source runs dry in the same round:
#
#   T_s = min(lines, BYTES / mean line bytes)   the documents source s gives
#                                               (BYTES `all`: every line)
#   R   = min_s T_s                             the rounds
#   PER_s = floor(T_s / R), take PER_s * R      each round's share, and the
#                                               documents taken
#
# A source is sampled (shuf -n, a fixed random source: the same sample every
# run) and shuffled as it is taken, so no repository runs in one block; then
# `deploy mix` interleaves PER_s lines of each per round, R rounds, every
# source drying in the last one. The check at the end cuts OUT into 20
# pieces by bytes and prints each piece's byte share by language (from the
# id's file extension): steady means every language's share is the same in
# every piece, within a round's grain.
#
#   tools/corpus-v2/steady-mix.sh run/v3/R/mix.jsonl run/v2/raw/haskell.jsonl:2900000000 \
#     run/v2/raw/lean.jsonl:all run/v2/raw/agda.jsonl:all ...
set -euo pipefail
out=${1:?usage: steady-mix.sh OUT.jsonl SRC.jsonl:BYTES ...}; shift
cd /home/hhefesto/src/formalTransformer
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] steady-mix: $*"; }
tmp=$(dirname "$out")/steady-tmp; mkdir -p "$tmp"
declare -a src take
for a in "$@"; do
  f=${a%:*}; want=${a##*:}
  read -r lines bytes < <(wc -lc < "$f")
  if [ "$want" = all ]; then t=$lines; else t=$(( want * lines / bytes )); [ "$t" -gt "$lines" ] && t=$lines; fi
  [ "$t" -lt 1 ] && { log "$f gives no document at $want bytes"; exit 1; }
  src+=("$f"); take+=("$t")
  log "$f: $lines lines, $bytes bytes; takes $t"
done
R=${take[0]}; for t in "${take[@]}"; do [ "$t" -lt "$R" ] && R=$t; done
args=()
for i in "${!src[@]}"; do
  f=${src[$i]}; per=$(( take[i] / R )); n=$(( per * R ))
  s=$tmp/$(basename "$f" .jsonl).$i.jsonl
  shuf -n "$n" --random-source=<(yes "steady-mix $(basename "$f")") "$f" > "$s"
  log "$f: $n lines sampled ($per a round)"
  args+=("$s:$per")
done
log "$R rounds"
nix run .#deploy -- mix "$out" "${args[@]}"
# the check: each twentieth of OUT by bytes, its byte share by language
awk -v total="$(wc -c < "$out")" '
  { b = length($0) + 1; piece = int(acc * 20 / total); acc += b
    id = $0; sub(/^\{"id": *"/, "", id); sub(/".*/, "", id)
    lang = "other"
    if (id ~ /\.l?hs$/) lang = "haskell"; else if (id ~ /\.lean$/) lang = "lean"
    else if (id ~ /\.l?agda(\.md|\.tex|\.rst)?$/) lang = "agda"; else if (id ~ /\.nix$/) lang = "nix"; else if (id ~ /\.bend$/) lang = "bend"
    s[piece, lang] += b; p[piece] += b; L[lang] = 1 }
  END { printf "piece"; for (l in L) printf " %8s", l; print ""
        for (i = 0; i < 20; i++) { printf "%5d", i + 1; for (l in L) printf " %7.1f%%", 100 * s[i, l] / p[i]; print "" } }' "$out" | tee "${out%.jsonl}.steady.txt"
rm -rf "$tmp"
log "done: $out"
