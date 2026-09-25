#!/usr/bin/env bash
# dense-identity.sh — the dense trainer's trajectory as bytes, to hold a
# layout change (where the store's regions live, how many arrays hold them)
# to "nothing observable moved".
#
# Usage: bend/tests/dense-identity.sh OUT_DIR [TRAINER]
#
# TRAINER is a built bend-train-dense (default: this flake's). Each run is six
# steps of small4-v3 on a frozen corpus (docs/haskell-era/RUN-2026-07-25-
# WIKI-FULL.md, which nothing edits), batch 8 in micro-batches of 4 (so the
# gradient accumulates), on the CPU loops (--gpu off). OUT_DIR gets, per
# optimizer (AdamW, Muon), the final parameters (BTC1) and the log with the
# fields that are not the trajectory removed: the timestamp, ms=, tok/s=,
# remaining=, eta= and the store's size (the one number a layout change is
# allowed to move). Two OUT_DIRs, before and after a change, must be equal:
#   diff -r BEFORE AFTER
set -euo pipefail
out="${1:?usage: dense-identity.sh OUT_DIR [TRAINER]}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trainer="${2:-$(nix build --no-link --print-out-paths "$repo#bend-train-dense")/bin/bend-train-dense}"
corpus="$repo/docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md"
mkdir -p "$out"
for opt in adamw muon; do
  ( cd "$out" && CORPUS="$corpus" PRESET=small4-v3 TRAIN_STEPS=6 TRAIN_BATCH=8 TRAIN_MICRO=4 \
      TRAIN_LR=3e-3 TRAIN_WARMUP=2 TRAIN_OPT="$opt" EVAL_EVERY=3 OUT="$opt.btc" \
      "$trainer" --gpu off --threads 4 > "$opt.raw.log" 2>&1 )
  sed -E -e 's/^\[[^]]*\] //' -e 's/ (ms|tok\/s|remaining|eta)=[^ ]*//g' \
      -e 's/, store [0-9]+ floats//' "$out/$opt.raw.log" > "$out/$opt.log"
  rm "$out/$opt.raw.log"
done
sha256sum "$out"/*.btc "$out"/*.log
