#!/usr/bin/env bash
# diloco-gate.sh — the three two-process DiLoCo verifications from the v4 plan
# (§0.1), as a script instead of a one-time manual run, so they can be re-run
# after ANY edit to Diloco.hs, the outer-sync insertion, or the launcher.
#
#   A  no-op identity: DILOCO_WORLD=1, OUTER_LR=1, MOMENTUM=0 must produce a
#      checkpoint byte-identical to a run with the machinery off entirely.
#   B  two ranks at H=1 (parameter averaging every step): every outer-sync
#      digest must agree across the ranks, and the loss must fall.
#   C  kill rank 1 mid-run: rank 0 must DIE on timeout, naming the peer's last
#      heartbeat -- never hang, never continue alone.
#
# Needs no GPU.  USE THE SEQUENTIAL TRAINER, NOT MULTICORE -- multicore's
# dynamic reduction scheduling breaks byte-identity for reasons that have
# nothing to do with DiLoCo (see train-plan-gate.sh, verified 2026-07-31).
#
#   nix build .#formal-transformer && nix build .#formal-transformer-sequential
#   deploy/diloco-gate.sh result/bin/formal-transformer \
#     result-sequential/bin/formal-transformer-sequential /tmp/diloco-gate
set -euo pipefail

CLI="$1"        # backend/app CLI (prepare-bytes, plan-segment)
TRAINER="$2"    # formal-transformer-sequential
WORK="$3"
SIZE=tiny
BATCH=2

rm -rf "$WORK"; mkdir -p "$WORK/run"

# Deterministic corpus, as in train-plan-gate.sh: documents must exceed the
# tiny preset's 16-token context to produce any window at all.
for k in 0 1 2; do
  mkdir -p "$WORK/text-$k"
  for doc in 0 1 2 3 4 5 6 7; do
    python3 - "$WORK/text-$k/doc-$doc.txt" "$k" "$doc" <<'PY'
import sys
path, shard, doc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta"]
body = " ".join(words[(shard * 7 + doc * 3 + i) % len(words)] for i in range(40))
open(path, "w").write(body + "\n")
PY
  done
  "$CLI" prepare-bytes "$WORK/run/shard-$k-$SIZE.corpus" "$WORK/text-$k"/*.txt >/dev/null
done

PLAN="$WORK/run/plan.tsv"
offset=0; start=0; lines=""
for k in 0 1 2; do
  read -r _tag _off docs corpus_id tw vw steps < <(
    "$CLI" plan-segment "$WORK/run/shard-$k-$SIZE.corpus" "$offset" "$BATCH" "$SIZE")
  end=$((start + steps))
  lines+="segment $k $offset $docs $corpus_id $tw $vw $steps $start $end"$'\n'
  offset=$((offset + docs))
  start=$end
done
total=$start
GLOBAL_ID="diloco-gate-v1"
{ echo "plan 1 $total $GLOBAL_ID hash $offset 0 $BATCH $SIZE tok"; printf '%s' "$lines"; } > "$PLAN"

export TRAIN_BATCH=$BATCH SKIP_BIGRAM_GATE=1
export CHECKPOINT_EVERY=100000 VALIDATE_EVERY=100000 VALIDATION_WINDOWS=4
status=0

fresh_run() { rm -f "$WORK/run"/*.done; }

# --- A: no-op identity --------------------------------------------------
REF="$WORK/ref.ckpt"
fresh_run
MICRO_BATCH=$BATCH "$TRAINER" train-plan "$PLAN" "$WORK/run" "$REF" "$SIZE" \
  > "$WORK/ref.log" 2>&1
NOOP="$WORK/noop.ckpt"
fresh_run
DILOCO_WORLD=1 DILOCO_RANK=0 DILOCO_H=1 DILOCO_OUTER_LR=1 DILOCO_MOMENTUM=0 \
DILOCO_DIR="$WORK/exchange-noop" MICRO_BATCH=$BATCH \
  "$TRAINER" train-plan "$PLAN" "$WORK/run" "$NOOP" "$SIZE" \
  > "$WORK/noop.log" 2>&1
if cmp -s "$REF" "$NOOP"; then
  echo "PASS A: world=1 lr=1 mu=0 is byte-identical to DiLoCo off ($(sha256sum < "$REF" | cut -c1-16))"
else
  echo "FAIL A: the no-op outer step changed the checkpoint"; status=1
fi

# --- B: two ranks, H=1, digests equal, loss falls -----------------------
CKPT2="$WORK/two.ckpt"
fresh_run
rm -rf "$WORK/exchange-two"
for rank in 0 1; do
  DILOCO_WORLD=2 DILOCO_RANK=$rank DILOCO_H=1 DILOCO_OUTER_LR=1 DILOCO_MOMENTUM=0 \
  DILOCO_TIMEOUT=120 DILOCO_DIR="$WORK/exchange-two" MICRO_BATCH=1 \
    "$TRAINER" train-plan "$PLAN" "$WORK/run" "$CKPT2" "$SIZE" \
    > "$WORK/two-rank$rank.log" 2>&1 &
  pids[$rank]=$!
done
rank_status=0
wait "${pids[0]}" || rank_status=1
wait "${pids[1]}" || rank_status=1
for rank in 0 1; do
  grep -o 'outer_step=[0-9]* step=[0-9]* rank=[0-9]* digest=[0-9a-f]* sumabs=[^ ]* sumsq=[^ ]*' \
    "$WORK/two-rank$rank.log" | sed 's/ rank=[0-9]*//' > "$WORK/digests-$rank"
done
syncs=$(wc -l < "$WORK/digests-0")
first_loss=$(grep -o 'train_loss=[0-9.]*' "$WORK/two-rank0.log" | head -1 | cut -d= -f2)
last_loss=$(grep -o 'train_loss=[0-9.]*' "$WORK/two-rank0.log" | tail -1 | cut -d= -f2)
if [ "$rank_status" = 0 ] && [ "$syncs" -gt 0 ] && cmp -s "$WORK/digests-0" "$WORK/digests-1" \
    && awk -v a="$first_loss" -v b="$last_loss" 'BEGIN { exit !(b < a) }'; then
  echo "PASS B: two ranks agreed on all $syncs digests, loss $first_loss -> $last_loss"
else
  echo "FAIL B: ranks=$rank_status syncs=$syncs loss $first_loss -> $last_loss"
  diff "$WORK/digests-0" "$WORK/digests-1" | head -4 || true
  status=1
fi

# --- C: kill rank 1, rank 0 must die on timeout naming the peer ---------
CKPT3="$WORK/dead.ckpt"
fresh_run
rm -rf "$WORK/exchange-dead"
DILOCO_WORLD=2 DILOCO_RANK=0 DILOCO_H=1 DILOCO_OUTER_LR=1 DILOCO_MOMENTUM=0 \
DILOCO_TIMEOUT=5 DILOCO_DIR="$WORK/exchange-dead" MICRO_BATCH=1 \
  "$TRAINER" train-plan "$PLAN" "$WORK/run" "$CKPT3" "$SIZE" \
  > "$WORK/dead-rank0.log" 2>&1 &
alone=$!
# Rank 1 never starts, so rank 0's first barrier can only time out.
if wait "$alone"; then
  echo "FAIL C: rank 0 finished alone -- it must die when the peer is absent"; status=1
elif grep -q 'peer rank is not making progress' "$WORK/dead-rank0.log" \
    && grep -q 'Last heartbeats' "$WORK/dead-rank0.log"; then
  echo "PASS C: rank 0 died on timeout and reported the peer's heartbeat"
else
  echo "FAIL C: rank 0 died without the timeout diagnostic"; tail -3 "$WORK/dead-rank0.log"; status=1
fi

exit $status
