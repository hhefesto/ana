#!/usr/bin/env bash
# plan-corpus.sh — shard and plan a JSONL {id, text} corpus in a single pass.
#
# Why this exists rather than `wiki-train`: that app extracts each shard with
#   awk -v a=first -v b=last 'NR>b{exit} NR>=a' "$data"
# which rescans from line 1 for every shard, so total reads grow as the square
# of the shard count. At Wikipedia's 18.9 GB and 1,465 shards that was survivable
# only because the file fits in page cache. At 37 GB and ~3,400 shards it would
# read on the order of 60 TB. Splitting once up front makes it linear.
#
# Everything else -- the plan format, the segment records, the identity string,
# the offset-invariant document split -- is unchanged, so `deploy/train-cloud.sh`
# consumes the output without modification.
#
# Usage:
#   TOKENIZER=weights/enwiki-c4-32k.bpe \
#   deploy/plan-corpus.sh DATA.jsonl RUN_DIR SIZE BATCH [ARTICLES_PER_SHARD]
set -euo pipefail

DATA="${1:?usage: plan-corpus.sh DATA.jsonl RUN_DIR SIZE BATCH [PER]}"
RUN_DIR="${2:?missing RUN_DIR}"
SIZE="${3:?missing SIZE}"
BATCH="${4:?missing BATCH}"
PER="${5:-4000}"
TOKENIZER="${TOKENIZER:?set TOKENIZER to the .bpe artifact}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
CLI="${CLI:-$(nix build --no-link --print-out-paths .#formal-transformer)/bin/formal-transformer}"

test -f "$DATA" || { echo "plan-corpus: no such file: $DATA" >&2; exit 1; }
test -f "$TOKENIZER" || { echo "plan-corpus: no such tokenizer: $TOKENIZER" >&2; exit 1; }
mkdir -p "$RUN_DIR/parts"

PLAN="$RUN_DIR/plan-$SIZE-b$BATCH-s$PER.tsv"
if [ -f "$PLAN" ]; then
  echo "plan-corpus: plan already exists: $PLAN" >&2
  exit 0
fi

# One pass to split. `split -d -a 6` numbers parts in reading order, so part N
# holds documents [N*PER, (N+1)*PER) -- exactly the offsets the planner needs.
if [ -z "$(ls -A "$RUN_DIR/parts" 2>/dev/null)" ]; then
  echo "plan-corpus: splitting $DATA into ${PER}-document parts" >&2
  split -l "$PER" -d -a 6 "$DATA" "$RUN_DIR/parts/part-"
fi
echo "plan-corpus: hashing the dataset and tokenizer" >&2
data_hash="$(sha256sum "$DATA" | cut -d ' ' -f 1)"
tokenizer_hash="$(sha256sum "$TOKENIZER" | cut -d ' ' -f 1)"
total="$(wc -l < "$DATA")"
# Drive the loop from the document count, not from the surviving parts. Parts
# are pruned as they are consumed, so on a resumed run the ones already done no
# longer exist -- iterating over what is left would silently omit those shards
# from the plan, producing a plan that trains on only part of the corpus.
shards=$(( (total + PER - 1) / PER ))
echo "plan-corpus: $shards shards" >&2
global_id="mixed-global-v1:sha256=$data_hash:documents=$total:shard=$PER:batch=$BATCH:size=$SIZE:tokenizer=$tokenizer_hash"

segments="$PLAN.segments.tmp"
pending="$PLAN.tmp"
rm -f "$segments" "$pending"
cumulative=0
for (( k = 0; k < shards; k++ )); do
  part="$(printf '%s/parts/part-%06d' "$RUN_DIR" "$k")"
  corpus="$RUN_DIR/shard-$k-$SIZE.corpus"
  offset=$(( k * PER ))
  if [ ! -f "$corpus" ]; then
    # prepare-bpe-stdin reports failures on stdout and still exits 0, so the
    # output has to be inspected rather than discarded -- otherwise a rejected
    # shard (a duplicate document id, say) looks like success and only surfaces
    # as a confusing "corpus file not found" from plan-segment.
    # Web text contains occasional NUL bytes. JSON cannot hold a raw control
    # character in a string, so they arrive as a six-character backslash-u
    # escape; jq decodes that to a real NUL and --raw-output0 then refuses to
    # emit it, because a NUL inside a field would break the very framing that
    # separates fields. Stripping the escape from the raw line removes it before
    # it is ever decoded. NUL carries no meaning for a language model, so
    # dropping it loses nothing; leaving it in aborts the run thousands of
    # shards deep (C4 shard 0 has exactly one such record, at document 19112).
    prepared="$(sed 's/\\u0000//g' "$part" | jq --raw-output0 '.id, .text' \
      | "$CLI" prepare-bpe-stdin "$TOKENIZER" "$corpus")"
    if [ ! -f "$corpus" ]; then
      echo "plan-corpus: shard $k failed to prepare from $part" >&2
      echo "  $prepared" >&2
      exit 1
    fi
    # The split doubles the corpus on disk, which a 37 GB source cannot afford
    # alongside its shards. Drop each part once its corpus exists; an
    # interrupted run re-splits from the source and skips shards already
    # prepared, so this costs a rescan rather than correctness.
    [ "${PRUNE_PARTS:-1}" = 1 ] && rm -f "$part"
  fi
  record="$("$CLI" plan-segment "$corpus" "$offset" "$BATCH" "$SIZE")"
  read -r tag planned_offset documents corpus_id train_windows validation_windows steps <<< "$record"
  if [ "$tag" != segment ] || [ "$planned_offset" != "$offset" ]; then
    echo "plan-corpus: invalid segment plan for shard $k: $record" >&2
    exit 1
  fi
  segment_start=$cumulative
  cumulative=$(( cumulative + steps ))
  printf 'segment %s %s %s %s %s %s %s %s %s\n' \
    "$k" "$offset" "$documents" "$corpus_id" "$train_windows" \
    "$validation_windows" "$steps" "$segment_start" "$cumulative" >> "$segments"
  if [ $(( k % 100 )) = 0 ]; then
    echo "plan-corpus: shard $k/$shards  cumulative steps $cumulative" >&2
  fi
done

printf 'plan 1 %s %s %s %s %s %s %s %s\n' \
  "$cumulative" "$global_id" "$data_hash" "$total" "$PER" \
  "$BATCH" "$SIZE" "$tokenizer_hash" > "$pending"
cat "$segments" >> "$pending"
mv "$pending" "$PLAN"
rm -f "$segments"
echo "plan-corpus: wrote $PLAN ($cumulative global steps over $shards shards)" >&2
