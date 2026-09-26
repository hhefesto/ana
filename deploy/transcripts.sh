#!/usr/bin/env bash
# deploy/transcripts.sh: the transcript corpus, one language at a time, from
# the code corpus to rendered transcripts (docs/TRANSCRIPT-FORMAT.md).
#
#   deploy/transcripts.sh STAGE LANG
#
#   STAGE  sources   the language's files from $CORPUS, as NUL-framed
#                    (id, text) pairs, split into two streams by how many
#                    units a file may give (MAX_HI for the sources the corpus
#                    wants more of, MAX otherwise)
#          units     bend-units over chunks of CHUNK files, UNIT_JOBS at once
#          check     deploy/check/LANG.sh with CHECK_JOBS workers
#          render    bend-transcript with the code32k tokenizer
#          all       the four in order
#   LANG   haskell | agda | lean | nix | bend
#
# Everything lands in $OUT/LANG/ (default run/transcripts): files-{hi,lo}.nul,
# units.nul, results.nul (+ .stats), transcripts.nul, and log, whose lines
# are stamped in Mexico City time (UTC-6). A stage whose output exists is
# skipped, so a killed run resumes at the stage it died in.
#
# Environment: CORPUS (default run/code-train-v3.jsonl, else v2), OUT,
# MAX (4), MAX_HI (8), CHUNK (300), UNIT_JOBS (8), CHECK_JOBS (per language),
# WINDOW (2048), TOKENIZER (weights/code32k.bpe), BEND_UNITS,
# BEND_TRANSCRIPT (default: built from the flake).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
STAGE=${1:?usage: transcripts.sh STAGE LANG}
LANG_=${2:?usage: transcripts.sh STAGE LANG}
if [[ -z ${CORPUS:-} ]]; then
  CORPUS=run/code-train-v3.jsonl
  [[ -f $CORPUS ]] || CORPUS=run/code-train-v2.jsonl
fi
OUT=${OUT:-run/transcripts}
MAX=${MAX:-4}
MAX_HI=${MAX_HI:-8}
CHUNK=${CHUNK:-300}
UNIT_JOBS=${UNIT_JOBS:-8}
WINDOW=${WINDOW:-2048}
TOKENIZER=${TOKENIZER:-weights/code32k.bpe}
dir=$OUT/$LANG_
mkdir -p "$dir"

log() { printf '%s %s\n' "$(TZ='<-06>6' date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$dir/log" >&2; }
tool() { nix build ".#$1" --no-link --print-out-paths 2>/dev/null | tail -n 1; }

# the files of each language, by id (jq regular expressions)
case $LANG_ in
  haskell) FILES='\.hs$' ;;
  agda) FILES='\.(agda|lagda|lagda\.md|lagda\.tex)$' ;;
  # mathlib's own libraries only: the oleans the harness has are mathlib's
  # (its batteries is a different version from repo:batteries, held out
  # anyway), and lean4's sources are the compiler's own prelude
  lean) FILES='^(repo:mathlib4/(Mathlib|Archive|Counterexamples)/|own:|curated:).*\.lean$' ;;
  nix) FILES='\.nix$' ;;
  bend) FILES='\.bend$' ;;
  *) echo "transcripts.sh: LANG is haskell, agda, lean, nix or bend" >&2; exit 2 ;;
esac
# files left out: Agda's own test suite beyond test/Succeed (most of it fails
# on purpose), its benchmarks, notes and primitives; HoTT-Agda's old/ tree
# (Agda 2.4 era); Agda files inside Hackage packages (no library to check them in)
case $LANG_ in
  agda) EXCLUDE='^repo:agda/(test/(?!Succeed/)|benchmark/|notes/|src/|doc/)|^repo:HoTT-Agda/old/|^hackage:' ;;
  *) EXCLUDE='^$' ;;
esac
# the sources the corpus wants more of: category theory, the user's own
# code, the curated repositories (Conal Elliott's), PLFA
# Hackage packages taken (Haskell): a fixed HACKAGE_PCT percent of them,
# whole, by a hash of the package name; every other source is taken whole
HACKAGE_PCT=${HACKAGE_PCT:-30}
HI='CategoryTheory|[Cc]ategor|^own:|^curated:(?!ghc-9)|^repo:plfa/|^repo:agda-unimath/|^repo:HoTT-Agda/|^repo:formal-ledger-specifications/|^repo:plutus/plutus-metatheory/|^repo:ouroboros-consensus/docs/agda-spec/'

sources() {
  [[ -s $dir/files-lo.nul || -s $dir/files-hi.nul ]] && { log "sources: done already"; return; }
  log "sources: $CORPUS, ids matching $FILES"
  jq --raw-output0 --arg re "$FILES" --arg ex "$EXCLUDE" --arg hi "$HI" --argjson pct "$HACKAGE_PCT" \
    'select((.id | test($re)) and (.id | test($ex) | not) and (.id | test($hi)) and ((.id | startswith("hackage:") | not) or ((.id | split("/")[0] | explode | reduce .[] as $c (7; (. * 31 + $c) % 1000003)) % 100 < $pct))) | .id, .text' "$CORPUS" > "$dir/files-hi.nul.tmp"
  jq --raw-output0 --arg re "$FILES" --arg ex "$EXCLUDE" --arg hi "$HI" --argjson pct "$HACKAGE_PCT" \
    'select((.id | test($re)) and (.id | test($ex) | not) and (.id | test($hi) | not) and ((.id | startswith("hackage:") | not) or ((.id | split("/")[0] | explode | reduce .[] as $c (7; (. * 31 + $c) % 1000003)) % 100 < $pct))) | .id, .text' "$CORPUS" > "$dir/files-lo.nul.tmp"
  mv "$dir/files-hi.nul.tmp" "$dir/files-hi.nul"
  mv "$dir/files-lo.nul.tmp" "$dir/files-lo.nul"
  log "sources: $(tr -cd '\0' < "$dir/files-hi.nul" | wc -c | awk '{print $1/2}') files at $MAX_HI units, $(tr -cd '\0' < "$dir/files-lo.nul" | wc -c | awk '{print $1/2}') at $MAX"
}

# NUL-framed pairs in $1 split into files of $CHUNK pairs: $2.0000, $2.0001, ...
split_pairs() {
  gawk -v RS='\0' -v ORS='\0' -v n="$CHUNK" -v pre="$2" '
    NR % 2 == 1 { k = int((NR - 1) / (2 * n)); f = sprintf("%s.%04d", pre, k) }
    { print > f }' "$1"
}

units() {
  [[ -s $dir/units.nul ]] && { log "units: done already"; return; }
  local bu=${BEND_UNITS:-$(tool bend-units)/bin/bend-units} w=$dir/units.work
  rm -rf "$w"; mkdir -p "$w"
  split_pairs "$dir/files-hi.nul" "$w/hi"
  split_pairs "$dir/files-lo.nul" "$w/lo"
  log "units: $(ls "$w" | wc -l) chunks of $CHUNK files, $UNIT_JOBS at once"
  local lang=$LANG_ max=$MAX max_hi=$MAX_HI
  export bu lang max max_hi
  find "$w" -name '*.[0-9]*' -not -name '*.units' -print0 | sort -z \
    | xargs -0 -P "$UNIT_JOBS" -I{} sh -c '
        f={}; m=$max; case $f in */hi.*) m=$max_hi ;; esac
        "$bu" "$lang" "$f" "$f.units" "$m" > "$f.log" 2>&1 || { echo "units: FAILED $f" >&2; cat "$f.log" >&2; exit 255; }'
  cat "$w"/*.units > "$dir/units.nul.tmp"
  mv "$dir/units.nul.tmp" "$dir/units.nul"
  log "units: $(cat "$w"/*.log | awk '/units out/ { f += $2; u += $5 } END { print f " files in, " u " units out" }')"
  rm -rf "$w"
}

check() {
  [[ -s $dir/results.nul ]] && { log "check: done already"; return; }
  local jobs=${CHECK_JOBS:-}
  if [[ -z $jobs ]]; then
    case $LANG_ in lean) jobs=5 ;; agda) jobs=8 ;; *) jobs=$(nproc) ;; esac
  fi
  if [[ $LANG_ == bend ]]; then
    export BEND=${BEND:-$(tool bend)/bin/bend} BEND_SRC=${BEND_SRC:-run/code-sources/own}
  fi
  log "check: deploy/check/$LANG_.sh with $jobs workers"
  deploy/check/"$LANG_".sh "$dir/units.nul" "$dir/results.nul.tmp" "$jobs" > "$dir/check.out" 2>&1
  mv "$dir/results.nul.tmp.stats" "$dir/results.nul.stats"
  mv "$dir/results.nul.tmp" "$dir/results.nul"
  log "check: $(tr '\n' ' ' < "$dir/results.nul.stats")"
}

render() {
  [[ -s $dir/transcripts.nul ]] && { log "render: done already"; return; }
  local bt=${BEND_TRANSCRIPT:-$(tool bend-transcript)/bin/bend-transcript}
  log "render: window $WINDOW"
  "$bt" "$TOKENIZER" "$dir/results.nul" "$dir/transcripts.nul.tmp" "$WINDOW" > "$dir/render.out" 2>&1
  mv "$dir/transcripts.nul.tmp" "$dir/transcripts.nul"
  log "render: $(tail -n 1 "$dir/render.out")"
}

case $STAGE in
  sources) sources ;;
  units) units ;;
  check) check ;;
  render) render ;;
  all) sources; units; check; render ;;
  *) echo "transcripts.sh: STAGE is sources, units, check, render or all" >&2; exit 2 ;;
esac
