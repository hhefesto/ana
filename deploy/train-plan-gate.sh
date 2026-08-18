#!/usr/bin/env bash
# The gate for train-plan: training a whole plan inside ONE process and ONE
# device context must produce a byte-identical checkpoint to running
# train-segment once per shard, which is what deploy/train-cloud.sh does in its
# default mode.  Also checks a mid-plan resume -- stopping after shard 0 and
# restarting must land on the same checkpoint, since that is how a rented box
# actually behaves when it dies.
#
# Needs no GPU.
#
#   nix build .#formal-transformer-sequential
#   nix build .#formal-transformer
#   deploy/train-plan-gate.sh \
#     result/bin/formal-transformer \
#     result/bin/formal-transformer-sequential \
#     /tmp/train-plan-gate
#
# USE THE SEQUENTIAL TRAINER, NOT MULTICORE.  Futhark's multicore backend
# schedules its reductions dynamically, so f32 accumulation order varies between
# runs of the same binary on the same input: two identical train-segment
# invocations produce different checkpoint hashes, and this comparison would
# fail at ~1e-7 for reasons that have nothing to do with train-plan.  Verified
# 2026-07-31.  Sequential is deterministic and this passes byte for byte.
set -euo pipefail

CLI="$1"        # backend/app CLI (prepare-bytes, plan-segment, compare-checkpoint)
TRAINER="$2"    # formal-transformer-sequential
WORK="$3"
SIZE=tiny
BATCH=2

rm -rf "$WORK"; mkdir -p "$WORK/run"

# Three shards of deterministic text.  Documents must exceed the tiny preset's
# 16-token context to produce any training window at all.
for k in 0 1 2; do
  mkdir -p "$WORK/text-$k"
  for doc in 0 1 2 3 4 5 6 7; do
    python3 - "$WORK/text-$k/doc-$doc.txt" "$k" "$doc" <<'PY'
import sys
path, shard, doc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# Deterministic, varied, and comfortably longer than the context window.
words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta"]
body = " ".join(words[(shard * 7 + doc * 3 + i) % len(words)] for i in range(40))
open(path, "w").write(body + "\n")
PY
  done
  "$CLI" prepare-bytes "$WORK/run/shard-$k-$SIZE.corpus" "$WORK/text-$k"/*.txt >/dev/null
done

# Build the plan the way deploy/plan-corpus does: per-shard document offset and
# a global step window derived from each shard's own step count.
PLAN="$WORK/run/plan.tsv"
offset=0
start=0
lines=""
for k in 0 1 2; do
  read -r _tag _off docs corpus_id tw vw steps < <(
    "$CLI" plan-segment "$WORK/run/shard-$k-$SIZE.corpus" "$offset" "$BATCH" "$SIZE")
  end=$((start + steps))
  lines+="segment $k $offset $docs $corpus_id $tw $vw $steps $start $end"$'\n'
  offset=$((offset + docs))
  start=$end
done
total=$start
GLOBAL_ID="equivalence-check-v1"
{ echo "plan 1 $total $GLOBAL_ID hash $offset 0 $BATCH $SIZE tok"; printf '%s' "$lines"; } > "$PLAN"
echo "--- plan ---"; cat "$PLAN"

export TRAIN_BATCH=$BATCH MICRO_BATCH=$BATCH SKIP_BIGRAM_GATE=1
export CHECKPOINT_EVERY=100000 VALIDATE_EVERY=100000 VALIDATION_WINDOWS=4

# A: one train-segment process per shard, exactly as train-cloud.sh does.
A="$WORK/a.ckpt"
while read -r tag k off docs corpus_id tw vw steps s e; do
  [ "$tag" = segment ] || continue
  "$TRAINER" train-segment "$WORK/run/shard-$k-$SIZE.corpus" "$A" \
    "$total" "$s" "$e" "$off" "$GLOBAL_ID" "$corpus_id" "$SIZE" > "$WORK/a-$k.log" 2>&1
done < <(grep '^segment' "$PLAN")

# B: the whole plan in one process and one context.
B="$WORK/b.ckpt"
"$TRAINER" train-plan "$PLAN" "$WORK/run" "$B" "$SIZE" > "$WORK/b.log" 2>&1

# C: mid-plan resume -- stop after one shard, then restart and finish.
C="$WORK/c.ckpt"
rm -f "$WORK/run"/*.done
MAX_SHARDS=1 "$TRAINER" train-plan "$PLAN" "$WORK/run" "$C" "$SIZE" > "$WORK/c1.log" 2>&1
"$TRAINER" train-plan "$PLAN" "$WORK/run" "$C" "$SIZE" > "$WORK/c2.log" 2>&1

echo "--- sha256 ---"
sha256sum "$A" "$B" "$C"

status=0
if cmp -s "$A" "$B"; then echo "PASS train-plan == N x train-segment (byte-identical)"
else echo "FAIL train-plan differs from train-segment"; "$CLI" compare-checkpoint "$A" "$B" || true; status=1; fi
if cmp -s "$A" "$C"; then echo "PASS mid-plan resume == uninterrupted (byte-identical)"
else echo "FAIL resume differs"; "$CLI" compare-checkpoint "$A" "$C" || true; status=1; fi
exit $status
