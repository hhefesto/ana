#!/usr/bin/env bash
# col9's check, the last of it (11-04 23:40).  col9-finish.sh's four shards ended by 20:30; ana-guard stopped the fifth at
# 23:32 (the memory, not the check), 530 units kept and 721 of its units still past the last kept one, nothing kept since
# 22:21 (they sit in a few slow files).  Here: what shard 4 kept goes with the rest, and those 721 are checked on 6 processes,
# so that the hash spreads them, at the same 90 s.  Then col9.sh goes on from the render.  Steps keep what they finished.
cd /home/hhefesto/src/ana || exit 1
export LC_ALL=C
V=run/v8; T=$V/transcripts-col9; F=$V/c9f; P=$F/transcripts-col9; G=$V/c9g; O=$G/transcripts-col9; E=$G/e
say() { echo "$(date '+%F %T') $*"; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
mkdir -p $O/bend $E
[ -s $T/bend/results.nul ] && { say "results already there"; exec run/v5/clean/col9.sh; }
if [ ! -s $E/s.ids ]; then
  cp ${PART4:?the stopped shard 4 part.0} $E/part.4 || exit 1
  for k in 0 1 2 3; do : > $E/part.$k; done
  run/v8/check-salvage $E/s $T/bend/units.nul $E/part.0 $E/part.1 $E/part.2 $E/part.3 $E/part.4 > $E/salvage.log 2>&1 || { say "check-salvage FAILED"; tail -3 $E/salvage.log; exit 1; }
  tail -1 $E/salvage.log | cut -c1-120
fi
if [ ! -s $G/done.ids ]; then
  # rest.ids of shard 4 of 5 (Check.bend's shard.mine, the file before `#`), less what s.ids says it decided
  gawk 'BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    FILENAME == ARGV[1] { dec[$0] = 1; next }
    { if ($0 in dec) next; f = $0; sub(/#.*/, "", f); h = 7; n = length(f)
      for (i = 1; i <= n; i++) h = (h * 31 + ord[substr(f, i, 1)]) % 1000003
      if (h % 5 == 4) print }' $E/s.ids $F/rest.ids | sort -u > $G/left.ids
  comm -23 $F/all.ids $G/left.ids > $G/done.ids
  say "left $(wc -l < $G/left.ids), passed over $(wc -l < $G/done.ids)"
fi
if [ ! -s $O/bend/results.prev.nul.stats ]; then
  cat $P/bend/results.prev.nul $P/bend/results.0.nul $P/bend/results.1.nul $P/bend/results.2.nul $P/bend/results.3.nul $E/s.nul > $O/bend/results.prev.nul
  n=$(count $O/bend/results.prev.nul)
  printf 'kept %s\nrecovered-from-killed-shards %s\nunits %s\n' $n $n $n > $O/bend/results.prev.nul.stats
  say "kept so far $n"
fi
ln -sf $PWD/$T/bend/units.nul $PWD/$T/bend/files-hi.nul $PWD/$T/bend/files-lo.nul $O/bend/
ln -sf $PWD/$T/col9.jsonl $O/col9.jsonl
DP=$(readlink -f run/v5/gcroot-deploy-982e162); B=$(readlink -f run/v5/gcroot-bend-2.0.39)
say "check, what is left"
env CORPUS=$O/col9.jsonl OUT=$O BEND=$B/bin/bend BEND_SRC=$V/collect9/src/bend MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 TIMEOUT=90 DONE=$PWD/$G/done.ids CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 UNIT_JOBS=4 $DP/bin/deploy transcripts check bend
rc=$?
say "check rc=$rc: $(tr '\n' ' ' < $O/bend/results.nul.stats 2>/dev/null)"
[ $rc = 0 ] && [ -s $O/bend/results.nul ] || exit 1
mv $O/bend/results.nul.stats $T/bend/results.nul.stats && mv $O/bend/results.nul $T/bend/results.nul
say "results in $T: $(count $T/bend/results.nul) kept; col9.sh goes on from the render"
exec run/v5/clean/col9.sh
