#!/usr/bin/env bash
# fillmore.sh PLANDIR PLANLOG [DOCS] (11-06, "on all cylinders"): the shards plan-windows last failed with "the filler corpus has no
# unused document" get DOCS more documents (default 1000, 2 NUL fields each) from another shard's slice, and their half-made .corpus
# files go, so that plan-windows' next run makes only those shards (a built shard is skipped).  R5b, 11-06 02:32: 157 of 311 failed at
# about window 4,800, with 5,082 documents a slice against about 4,940 windows a shard.  A document in two shards' pools is one
# more copy of a file that the plan already has dozens of (FILLER_COPIES); the .corpus files keep no ids.  The parts of the plan stay.
# Prints how many shards it gave more to.  Rounds kept in fill-N.more, so a second round takes from another slice.
set -eu
D=$1; L=$2; DOCS=${3:-1000}
L=$(readlink -f "$L"); cd "$D/parts"
n=$(ls | grep -c '^fill-[0-9]*\.nul$')
# (the failures of the last run only: the log's last "building" on)
failed=$(tac "$L" | sed '/plan-windows: building/q' | grep 'no unused document' | sed 's/.*shard \([0-9]*\):.*/\1/' | sort -un)
c=0
for s in $failed; do
  f=$(printf 'fill-%06d' "$s")
  r=$(cat "$f.more" 2>/dev/null || echo 0); r=$((r + 1))
  src=$(printf 'fill-%06d.nul' $(( (s + n / 2 + 7 * (r - 1)) % n )))
  head -z -n $((2 * DOCS)) "$src" > "$f.nul.add"
  cat "$f.nul.add" >> "$f.nul"
  rm -f "$f.nul.add" "$f.corpus" "$f.corpus.lengths"
  echo "$r" > "$f.more"
  c=$((c + 1))
done
echo "$c"
