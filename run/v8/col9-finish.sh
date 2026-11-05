#!/usr/bin/env bash
# col9's check, closed (11-04; the user's goal: close all Bend generation, then only the GPU rent is missing).
# Delfos has the front half of what was left (c9o/front.ids), but two of its five shards sit on units whose every
# check takes its 240 s (bend-lint's bend2craft: 88 units in 4 h on shard 4), so waiting for it could take days.
# When a2b-um15 has ended and olimpo has room: stop delfos, keep what it decided (bend/CheckSalvage.bend), check what
# is left of the front here at 90 s a check (a unit that slow is dropped, not waited for; 2,850 units/h at 180 s on
# 5 processes), put every result in run/v8/transcripts-col9, and let col9.sh go on from the render. Steps keep what
# they finished, so this can be started again.
cd /home/hhefesto/src/ana || exit 1
V=run/v8; T=$V/transcripts-col9; F=$V/c9f; O=$F/transcripts-col9; D=192.168.3.6
say() { echo "$(date '+%F %T') $*"; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
mkdir -p $O/bend $F/d
[ -s $T/bend/results.nul ] && { say "results already there"; exec run/v5/clean/col9.sh; }
while systemctl --user is-active -q ${WAIT_FOR:-a2b-um15}; do sleep 120; done
if [ ! -s $F/d/s.ids ]; then
  say "stopping delfos' check"
  ssh -o BatchMode=yes $D 'systemctl --user stop ana-help-col9' || { say "could not reach delfos"; exit 1; }
  k=0
  # shard order, from each bend-check's SHARD and its children's working directory (19:30)
  for w in MTdLAetaN5 sTuOoRcI7I QVaLXL7Mpl fVx22JxG3n zmiiaDdKsI; do
    rsync -a --timeout=300 -e 'ssh -o BatchMode=yes' $D:/tmp/tmp.$w/part.0 $F/d/part.$k || { say "part $k FAILED"; exit 1; }
    k=$((k + 1))
  done
  run/v8/check-salvage $F/d/s $T/bend/units.nul $F/d/part.0 $F/d/part.1 $F/d/part.2 $F/d/part.3 $F/d/part.4 > $F/d/salvage.log 2>&1 \
    || { say "check-salvage FAILED"; tail -3 $F/d/salvage.log; exit 1; }
  cut -c1-120 $F/d/salvage.log | tail -6
fi
# what delfos has not decided of its front; everything else is decided
if [ ! -s $F/done.ids ]; then
  LC_ALL=C sort -u $F/d/s.ids > $F/d/s.sorted
  LC_ALL=C sort -u $V/c9o/front.ids > $F/front.sorted
  LC_ALL=C comm -23 $F/front.sorted $F/d/s.sorted > $F/rest.ids
  say "front $(wc -l < $F/front.sorted), of it left $(wc -l < $F/rest.ids)"
  LC_ALL=C gawk 'BEGIN{RS="\0"} FNR%2==1 { sub(/\n$/,""); print }' $T/bend/units.nul | LC_ALL=C sort -u > $F/all.ids
  LC_ALL=C comm -23 $F/all.ids $F/rest.ids > $F/done.ids
  say "units $(wc -l < $F/all.ids), passed over $(wc -l < $F/done.ids)"
fi
# what delfos decided past its front (a shard past the half) olimpo has decided too: its results stay out
if [ ! -s $O/bend/results.prev.nul.stats ]; then
  LC_ALL=C gawk 'BEGIN{RS="\0";ORS="\0"} FNR==NR { f[$0]=1; next } FNR%2==1 { k=($0 in f) } k' <(tr '\n' '\0' < $F/front.sorted) $F/d/s.nul > $F/d/s.front.nul
  say "delfos kept $(count $F/d/s.nul), in its front $(count $F/d/s.front.nul)"
  cat $V/col9-salv/s.nul $V/c9o/salv/s.nul $V/c9o/transcripts-col9/bend/results.nul $F/d/s.front.nul > $O/bend/results.prev.nul
  n=$(count $O/bend/results.prev.nul)
  printf 'kept %s\nrecovered-from-killed-shards %s\nunits %s\n' $n $n $n > $O/bend/results.prev.nul.stats
  say "kept so far $n"
fi
ln -sf $PWD/$T/bend/units.nul $PWD/$T/bend/files-hi.nul $PWD/$T/bend/files-lo.nul $O/bend/
ln -sf $PWD/$T/col9.jsonl $O/col9.jsonl
DP=$(readlink -f run/v5/gcroot-deploy-982e162); B=$(readlink -f run/v5/gcroot-bend-2.0.39)
say "check, what is left"
env CORPUS=$O/col9.jsonl OUT=$O BEND=$B/bin/bend BEND_SRC=$V/collect9/src/bend MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 TIMEOUT=90 DONE=$PWD/$F/done.ids CHECK_PROCS=${CHECK_PROCS:-5} CHECK_JOBS=1 UNIT_JOBS=4 $DP/bin/deploy transcripts check bend
rc=$?
say "check rc=$rc: $(tr '\n' ' ' < $O/bend/results.nul.stats 2>/dev/null)"
[ $rc = 0 ] && [ -s $O/bend/results.nul ] || exit 1
mv $O/bend/results.nul.stats $T/bend/results.nul.stats && mv $O/bend/results.nul $T/bend/results.nul
say "results in $T: $(count $T/bend/results.nul) kept; col9.sh goes on from the render"
exec run/v5/clean/col9.sh
