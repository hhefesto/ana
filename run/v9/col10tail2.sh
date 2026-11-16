#!/usr/bin/env bash
# col10's check, rebalanced again (2026-11-15 21:3x; as run/v9/col10tail.sh).  col10tail's 7 processes shard by
# file (Check.bend's hash mod 7), and shard 2 got bendJVM's big files (runtime/scheduler, runtime/binary64,
# java/threads, java/strings: about 186 units left at about 80 s and up to 12.7 GB a check, so one at a time),
# about 5 h alone, while shards 0, 1 and 6 ended by 21:20 (about 4 s a unit).  bendJVM so far: 67 of 237 decided
# units kept, all but 3 from runtime/threads.bend; java/natives 0 of 48, hostio 0 of 12, trace 0 of 10.  So its
# undecided units (HOLD, about 330, 7 h on one process) are held back from R7, listed in e/deferred.ids for a later
# check (R8), not dropped from the collection.  Here: freeze ana-col10tail; a shard that finished is `=` (its
# results.K.nul kept), a shard still running gives a copy of its part.0; thaw and stop it; check-salvage
# (bend/CheckSalvage.bend; `=` for a finished shard) the decided ids and the kept results; check the rest, HOLD's
# passed over, on 8 processes (8 is prime to 7: shard 2's files spread), same TIMEOUT 180; col10tail's kept, the
# finished shards' and the salvaged in front as results.prev.nul; then ana-r7chain2 again (col10.sh goes on from
# clean), as col10tail.sh.  The units a running shard dropped after its last kept one are checked again.
# A thin shim: the logic is check-salvage's and deploy's (Bend).  Nothing rented, nothing of col10's deleted.
set -u
shopt -s nullglob
cd /home/hhefesto/src/ana || exit 1
export LC_ALL=C BEND_NO_TELEMETRY=1
V=run/v9; T=$V/transcripts-col10; G1=$V/col10tail; O1=$G1/transcripts-col10; E1=$G1/e
G=$V/col10tail2; O=$G/transcripts-col10; E=$G/e
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CS=$G/check-salvage   # bend bend/CheckSalvage.bend -o run/v9/col10tail2/check-salvage (the `=` part)
PROCS=${PROCS:-8}
HOLD=${HOLD:-^repo:MatheusBBarni__bendJVM/}   # ids held back from R7's check (above)
say() { echo "$(date '+%F %T') col10tail2: $*"; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
chain() {  # ana-r7chain2 again, as it was started (11-15)
  systemctl --user reset-failed ana-r7chain2 2>/dev/null
  systemd-run --user -q --unit=ana-r7chain2 -p WorkingDirectory=$PWD -p MemoryMax=20G \
    bash -c "bash run/v9/r7chain2.sh >> run/v9/r7chain2.log 2>&1" && say "ana-r7chain2 started again"; }
mkdir -p $O/bend $E
[ -x $CS ] || { say "no $CS"; exit 1; }
if [ -s $T/bend/results.nul ]; then say "col10's results.nul is there already"; chain; exit 0; fi

if [ ! -s $E/parts ]; then
  systemctl --user is-active -q ana-col10tail || { say "ana-col10tail is not running: no parts to take"; exit 1; }
  systemctl --user freeze ana-col10tail || { say "freeze failed"; exit 1; }
  : > $E/parts.tmp; ok=1
  for k in 0 1 2 3 4 5 6; do
    if [ -s $O1/bend/results.$k.nul ] && [ -s $O1/bend/results.$k.nul.stats ]; then
      cp $O1/bend/results.$k.nul $E/results.$k.nul && cp $O1/bend/results.$k.nul.stats $E/results.$k.nul.stats || ok=
      echo = >> $E/parts.tmp; say "shard $k: finished, $(count $E/results.$k.nul) kept"
    else
      d=$(grep -o '/tmp/tmp\.[A-Za-z0-9]*' $O1/bend/check.$k.out | head -n 1)
      if [ -n "$d" ] && [ -e "$d/part.0" ]; then
        cp $d/part.0 $E/part.$k || ok=
      elif [ -n "$d" ] && [ -d "$d" ]; then
        : > $E/part.$k   # running, nothing kept yet
      else
        say "shard $k: neither results.$k.nul nor a work directory ($d)"; ok=
      fi
      echo $E/part.$k >> $E/parts.tmp
    fi
  done
  systemctl --user thaw ana-col10tail
  [ -n "$ok" ] || { say "taking the parts FAILED: ana-col10tail goes on"; rm -f $E/parts.tmp; exit 1; }
  systemctl --user stop ana-col10tail
  mv $E/parts.tmp $E/parts
  say "ana-col10tail stopped; parts: $(tr '\n' ' ' < $E/parts)"
fi

if [ ! -s $E/s.ids ]; then
  $CS $E/s $T/bend/units.nul $(cat $E/parts) > $E/salvage.log 2>&1 \
    || { say "check-salvage FAILED ($E/salvage.log)"; rm -f $E/s.ids; exit 1; }
  say "salvage: $(tail -n 1 $E/salvage.log)"
fi
if [ ! -s $E/held.ids ]; then
  gawk 'BEGIN{RS="\0"} NR%2==1' $T/bend/units.nul | grep -E "$HOLD" > $E/held.ids
  cat $E1/s.ids $E/s.ids | grep -E "$HOLD" | sort -u > $E/held.decided
  sort -u $E/held.ids | comm -23 - $E/held.decided > $E/deferred.ids
  say "held back ($HOLD): $(wc -l < $E/held.ids) units, $(wc -l < $E/deferred.ids) of them undecided (e/deferred.ids, for R8)"
fi
cat $E1/s.ids $E/s.ids $E/held.ids > $E/done.ids

if [ ! -s $O/bend/results.prev.nul.stats ]; then
  cat $O1/bend/results.prev.nul $E/results.?.nul $E/s.nul > $O/bend/results.prev.nul
  n=$(count $O/bend/results.prev.nul)
  printf 'kept %s\nrecovered-from-killed-shards %s\nunits %s\n' $n $n $n > $O/bend/results.prev.nul.stats
  say "kept so far $n (col10tail's $(count $O1/bend/results.prev.nul), finished shards' and salvaged)"
fi
ln -sf $PWD/$T/bend/units.nul $PWD/$T/bend/files-hi.nul $PWD/$T/bend/files-lo.nul $O/bend/
ln -sf $PWD/$T/col10.jsonl $O/col10.jsonl

say "check, what is left: $PROCS processes"
env CORPUS=$O/col10.jsonl OUT=$O BEND=$B BEND_SRC=$V/collect10/src/bend MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 TIMEOUT=180 \
  DONE=$PWD/$E/done.ids CHECK_PROCS=$PROCS CHECK_JOBS=1 UNIT_JOBS=4 $D transcripts check bend > $O/check.log 2>&1
rc=$?
say "check rc=$rc: $(tr '\n' ' ' < $O/bend/results.nul.stats 2>/dev/null)"
if [ $rc = 0 ] && [ -s $O/bend/results.nul ]; then
  mv $O/bend/results.nul.stats $T/bend/results.nul.stats && mv $O/bend/results.nul $T/bend/results.nul
  say "col10's results: $(count $T/bend/results.nul) kept"
else
  say "the rest's check FAILED ($O/check.log): col10.sh checks everything again"
fi
chain
