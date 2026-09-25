#!/usr/bin/env bash
# plan-corpus.sh — shard and plan a JSONL {id, text} corpus in a single pass.
#
# Why this exists rather than `wiki-train`: that app extracted each shard with
#   awk -v a=first -v b=last 'NR>b{exit} NR>=a' "$data"
# which rescans from line 1 for every shard, so total reads grow as the square
# of the shard count. Splitting once up front makes it linear.
#
# The corpus tools are the Bend ones (bend/Pack.bend, bend/Prepare.bend,
# bend/PlanSegment.bend), byte-identical to master's Haskell pack-stdin,
# prepare-bpe-stdin and plan-segment (docs/BEND-CORPUS-TOOLS.md records the
# comparison). They read and write files, not pipes, so every shard passes
# through a NUL-framed file on disk.
#
# Shards are prepared in parallel, one single-threaded process each: the Bend
# runtime scales this allocation-heavy work to about two cores inside one
# process, while separate processes scale with the cores. Planning (the
# cumulative step count, the completeness assertions) stays a sequential pass.
#
# The plan format, the segment records, the identity string and the
# offset-invariant document split are unchanged, so a plan written here is
# byte-identical to one written with the Haskell tools.
#
# Usage:
#   TOKENIZER=run/code32k.bpe \
#   deploy/plan-corpus.sh DATA.jsonl RUN_DIR SIZE BATCH [ARTICLES_PER_SHARD]
#
# Env:
#   PACK_TARGET  pack documents up to this many bytes before tokenizing, so
#                short documents survive windowing (128 KB clears 98% of bytes
#                at context 1024, against 52% unpacked). Pair it with a smaller
#                PER: at a 128 KB target, PER=2000 keeps a shard's text small.
#   PACK_GROUP   pack only within a repository (ids must be repo/path).
#   JOBS         shards prepared at once (default: available memory / 3 GB,
#                at most the core count; a 23 MB shard peaks near 1.7 GB).
#   BEND_TOOLS   a directory holding bend-pack, bend-prepare and
#                bend-plan-segment (default: built from this flake).
set -euo pipefail

DATA="${1:?usage: plan-corpus.sh DATA.jsonl RUN_DIR SIZE BATCH [PER]}"
RUN_DIR="${2:?missing RUN_DIR}"
SIZE="${3:?missing SIZE}"
BATCH="${4:?missing BATCH}"
PER="${5:-4000}"
TOKENIZER="${TOKENIZER:?set TOKENIZER to the .bpe artifact}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
tool() {
  if [ -n "${BEND_TOOLS:-}" ]; then
    echo "$BEND_TOOLS/$1"
  else
    echo "$(nix build --no-link --print-out-paths ".#$1")/bin/$1"
  fi
}
PACK="$(tool bend-pack)"
PREPARE="$(tool bend-prepare)"
PLANSEG="$(tool bend-plan-segment)"

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
# Packing changes the corpus bytes, so it is identity-bearing exactly like the
# batch and the tokenizer: two runs over the same JSONL with different
# PACK_TARGET must never share a plan identity. Unpacked plans keep the
# historical id unchanged.
pack_id="${PACK_TARGET:+:pack=$PACK_TARGET${PACK_GROUP:+-grouped}}"
global_id="mixed-global-v1:sha256=$data_hash:documents=$total:shard=$PER:batch=$BATCH:size=$SIZE:tokenizer=$tokenizer_hash$pack_id"

# Prepare one shard: part-k (JSONL) -> NUL stream -> [pack] -> FTCC corpus.
# Every intermediate is a file; the corpus appears under its final name only
# once complete (written to .tmp, then renamed), so an interrupted run never
# leaves a short corpus that looks finished. On a packed run the pack counts
# persist beside the corpus, for the completeness assertion below.
prepare_shard() {
  local k="$1"
  local part corpus nul packed filter
  part="$(printf '%s/parts/part-%06d' "$RUN_DIR" "$k")"
  corpus="$RUN_DIR/shard-$k-$SIZE.corpus"
  [ -f "$corpus" ] && return 0
  nul="$part.nul"
  # Web text contains occasional NUL bytes. JSON cannot hold a raw control
  # character in a string, so they arrive as a backslash-u escape; jq decodes
  # that to a real NUL and --raw-output0 then refuses to emit it, because a
  # NUL inside a field would break the framing that separates fields.
  #
  # They cannot be stripped textually: a record containing an escaped
  # backslash followed by the literal text u0000 has the same six bytes, and
  # deleting them leaves a dangling backslash -- invalid JSON. So remove the
  # character after decoding, via explode/implode, which needs no escape in
  # the filter. That is expensive, so it is only used on the rare parts that
  # actually contain the escape.
  if grep -q '\\u0000' "$part"; then
    filter='.id, (.text | explode | map(select(. != 0)) | implode)'
  else
    filter='.id, .text'
  fi
  jq --raw-output0 "$filter" < "$part" > "$nul"
  if [ -n "${PACK_TARGET:-}" ]; then
    # The prefix carries the shard index because ids restart per shard and
    # must stay globally distinct.
    packed="$part.packed.nul"
    if ! "$PACK" --threads 1 "$nul" "$packed" --target "$PACK_TARGET" --prefix "pack$k" \
        ${PACK_GROUP:+--group} --stats 2> "$corpus.pack.log"; then
      echo "plan-corpus: shard $k pack failed:" >&2
      cat "$corpus.pack.log" >&2
      return 1
    fi
    sed -n 's/^pack-stdin: \([0-9]*\) documents in, \([0-9]*\) packed.*/\1 \2/p' \
      "$corpus.pack.log" > "$corpus.pack.tmp"
    if [ ! -s "$corpus.pack.tmp" ]; then
      echo "plan-corpus: shard $k produced no pack stats line:" >&2
      cat "$corpus.pack.log" >&2
      return 1
    fi
    rm -f "$nul" "$corpus.pack.log"
    nul="$packed"
  fi
  if ! "$PREPARE" --threads 1 "$TOKENIZER" "$nul" "$corpus.tmp" > "$corpus.log" 2>&1; then
    echo "plan-corpus: shard $k failed to prepare from $part:" >&2
    cat "$corpus.log" >&2
    return 1
  fi
  rm -f "$nul" "$corpus.log"
  [ -f "$corpus.pack.tmp" ] && mv "$corpus.pack.tmp" "$corpus.pack"
  mv "$corpus.tmp" "$corpus"
  # The split doubles the corpus on disk. Drop each part once its corpus
  # exists; an interrupted run re-splits from the source and skips shards
  # already prepared, so this costs a rescan rather than correctness.
  if [ "${PRUNE_PARTS:-1}" = 1 ]; then rm -f "$part"; fi
}
export -f prepare_shard
export RUN_DIR SIZE TOKENIZER PACK PREPARE PACK_TARGET PACK_GROUP PRUNE_PARTS

cores="$(nproc)"
avail_gb="$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)"
jobs="${JOBS:-$(( avail_gb / 3 ))}"
[ "$jobs" -ge 1 ] || jobs=1
[ "$jobs" -le "$cores" ] || jobs="$cores"
echo "plan-corpus: preparing shards, $jobs at a time" >&2
seq 0 $(( shards - 1 )) | xargs -P "$jobs" -I{} bash -c 'prepare_shard "$@"' _ {}

segments="$PLAN.segments.tmp"
pending="$PLAN.tmp"
rm -f "$segments" "$pending"
cumulative=0
for (( k = 0; k < shards; k++ )); do
  corpus="$RUN_DIR/shard-$k-$SIZE.corpus"
  offset=$(( k * PER ))
  if [ ! -f "$corpus" ]; then
    echo "plan-corpus: shard $k has no corpus ($corpus)" >&2
    exit 1
  fi
  if [ -n "${PACK_TARGET:-}" ]; then
    if [ ! -f "$corpus.pack" ]; then
      echo "plan-corpus: shard $k has no pack-count sidecar ($corpus.pack)" >&2
      echo "  The corpus predates packing or was prepared by an older script," >&2
      echo "  so its completeness cannot be asserted. Delete $corpus and re-run." >&2
      exit 1
    fi
    read -r packed_in packed_out < "$corpus.pack"
  fi
  record="$("$PLANSEG" --threads 1 "$corpus" "$offset" "$BATCH" "$SIZE")"
  read -r tag planned_offset documents corpus_id train_windows validation_windows steps <<< "$record"
  if [ "$tag" != segment ] || [ "$planned_offset" != "$offset" ]; then
    echo "plan-corpus: invalid segment plan for shard $k: $record" >&2
    exit 1
  fi
  # Assert the shard is complete. A producer that dies mid-stream leaves a
  # corpus that is structurally valid but short, and nothing downstream would
  # notice. This caught shard 83 holding 1,625 of 4,000 documents.
  #
  # Packing changes what to count: the corpus now holds packed documents, far
  # fewer than PER, so the check moves upstream to what the packer was fed.
  # The second half asserts that everything the packer emitted reached the
  # corpus.
  if [ -n "${PACK_TARGET:-}" ]; then
    if [ "$packed_in" != "$PER" ] && [ "$k" != "$(( shards - 1 ))" ]; then
      echo "plan-corpus: shard $k is short: packed $packed_in of $PER documents" >&2
      exit 1
    fi
    if [ "$documents" != "$packed_out" ]; then
      echo "plan-corpus: shard $k lost documents: packer emitted $packed_out, corpus holds $documents" >&2
      exit 1
    fi
  fi
  if [ -z "${PACK_TARGET:-}" ] && [ "$documents" != "$PER" ] && [ "$k" != "$(( shards - 1 ))" ]; then
    echo "plan-corpus: shard $k is short: $documents of $PER documents" >&2
    echo "  delete $corpus and re-run" >&2
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
