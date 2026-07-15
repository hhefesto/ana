#!/usr/bin/env bash
# train-cloud.sh — cost-optimal cloud trainer.
#
# Drives `formal-transformer-cuda train-segment` per shard directly from a
# pre-built plan and the pre-tokenized corpora. This deliberately bypasses the
# `wiki-train` app, which hard-requires the 18 GB source JSONL (it re-hashes it
# into the plan identity) even when a plan and corpora already exist. Here only
# the plan + corpora + the 103 KB tokenizer need to be on the instance.
#
# The global cosine LR schedule and one AdamW moment trajectory are preserved
# exactly: every train-segment call gets the same GLOBAL_TOTAL and GLOBAL_ID
# from the plan header, so the checkpoint is identical to what `wiki-train`
# would have produced for the same shards.
#
# Cost control: MAX_SHARDS>0 stops after that many shards this run, so a first
# pass stays cheap. Stopping early is safe — the checkpoint is a valid partial
# state; a later run resumes from its exact global Adam step. It also stops
# cleanly (not an error) at the first missing corpus, so you can transfer only
# the first N shards for a first pass.
#
# Env:
#   TOKENIZER_FILE   (required) path to the .bpe artifact
#   TRAIN_BATCH=8    must match the plan identity (batch is semantic)
#   MICRO_BATCH=1    raise toward TRAIN_BATCH on a headless GPU (no watchdog)
#   MAX_SHARDS=0     0 = whole plan; N = stop after N shards this run
#   CHECKPOINT_EVERY=100  checkpoint cadence (execution control; safe to change)
#   RUN_DIR, SIZE, SHARD_ARTICLES, PLAN, CHECKPOINT, FUT_CACHE  (have defaults)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

SIZE="${SIZE:-bpe10m}"
BATCH="${TRAIN_BATCH:-8}"
RUN_DIR="${RUN_DIR:-run/wiki-$SIZE}"
SHARD_ARTICLES="${SHARD_ARTICLES:-4000}"
PLAN="${PLAN:-$RUN_DIR/plan-$SIZE-b$BATCH-s$SHARD_ARTICLES.tsv}"
CHECKPOINT="${CHECKPOINT:-run/wiki-$SIZE-global.checkpoint}"
MAX_SHARDS="${MAX_SHARDS:-0}"
: "${TOKENIZER_FILE:?set TOKENIZER_FILE to the .bpe artifact}"

test -f "$PLAN" || { echo "train-cloud: plan not found: $PLAN" >&2; exit 1; }
test -f "$TOKENIZER_FILE" || { echo "train-cloud: tokenizer not found: $TOKENIZER_FILE" >&2; exit 1; }

features="nix-command flakes"
nix --extra-experimental-features "$features" build .#formal-transformer-cuda
trainer="$repo_root/result/bin/formal-transformer-cuda"

# Plan header: plan 1 <global_total> <global_id> <data_hash> <total> <per> <batch> <size> <tok_hash>
read -r tag _ver global_total global_id _rest < "$PLAN"
[ "$tag" = plan ] || { echo "train-cloud: bad plan header in $PLAN" >&2; exit 1; }
echo "train-cloud: global_total=$global_total"
echo "train-cloud: global_id=$global_id"
echo "train-cloud: checkpoint=$CHECKPOINT batch=$BATCH micro=${MICRO_BATCH:-1} max_shards=$MAX_SHARDS"

export TRAIN_BATCH="$BATCH"
export MICRO_BATCH="${MICRO_BATCH:-1}"
export CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-100}"
export FUT_CACHE="${FUT_CACHE:-run/futhark-cuda.cache}"

trained=0
# Segment line: segment <k> <offset> <docs> <corpus_id> <tw> <vw> <steps> <seg_start> <seg_end>
while read -r tag k offset _docs corpus_id _tw _vw _steps seg_start seg_end; do
  [ "$tag" = segment ] || continue
  marker="$RUN_DIR/shard-$k-$SIZE.done"
  [ -f "$marker" ] && continue
  corpus="$RUN_DIR/shard-$k-$SIZE.corpus"
  if [ ! -f "$corpus" ]; then
    echo "train-cloud: corpus for shard $k not present — stopping cleanly here." >&2
    echo "  (transfer more shards to continue: $corpus)" >&2
    break
  fi
  echo "train-cloud: shard $k  global $seg_start..$seg_end / $global_total"
  "$trainer" train-segment "$corpus" "$CHECKPOINT" "$global_total" \
    "$seg_start" "$seg_end" "$offset" "$global_id" "$corpus_id" "$SIZE"
  touch "$marker"
  trained=$((trained + 1))
  if [ "$MAX_SHARDS" -gt 0 ] && [ "$trained" -ge "$MAX_SHARDS" ]; then
    echo "train-cloud: reached MAX_SHARDS=$MAX_SHARDS — stopping."
    break
  fi
done < "$PLAN"

echo "train-cloud: finished ($trained shard(s) this run). Checkpoint: $CHECKPOINT"
