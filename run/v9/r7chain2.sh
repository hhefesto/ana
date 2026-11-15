#!/usr/bin/env bash
# R7's corpus, end to end on olimpo (2026-11-15, the second chain; docs/r7/PLAN.md).  The user, 11-15: "be ready to
# train on my approval"; R7's list (61774): the authors'-law asks (f5), the join, the mix, the filler; changes 1, 5,
# 6, 7, 8; then the user's OK to rent.  Nothing is rented here.  A thin shim; the logic is Bend's.
#   1. run 10's and run 10b's collections (ana-col10, ana-col10b): their collect stops at keys, on the corpus files
#      deleted on 11-09; it goes on from keys with run/v9/col10fix's bend-corpus-v2 (the files' cached keys), then
#      col10.sh, then col10b.sh (its decl-new sees col10's units)
#   2. their render with laws (f6.sh: run/v9/f6 for col10, run/v9/f6b for col10b)
#   3. the prove units (ana-f7, f7.sh) and the sorts (ana-f8, f8.sh): waited for
#   4. mugen's chats again (run/v9/mlog: export.sh, then mugenlog), so today's turns go in
#   5. the prose (run/v9/theory/prose.log), then run7.sh: f5's workers, retry, join, the mix, the filler, the plan,
#      the validation windows
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') r7chain2: $*"; }
active() { systemctl --user is-active -q "$1"; }
V=run/v9; CVX=$V/col10fix/bend-corpus-v2
while active ana-cv2gone; do sleep 60; done
grep -q '^rc=0' $V/col10fix/build.log || { say "the fixed bend-corpus-v2 did not build ($V/col10fix/build.log)"; exit 1; }
# a collection whose collect stopped at keys: go on from there
resume() { local n=$1 d=$2 cfg=$3 l=$V/$2/collect.log last
  grep -q '^EXIT 0' $l && return 0
  last=$(grep -o 'collect: [a-z-]*:' $l | tail -n 1)
  case "$last" in "collect: nul:"|"collect: keys:") ;;
    *) say "$n: its collect stopped at '$last', not at keys: not resumed ($l)"; return 1 ;; esac
  say "$n: collect again from keys"
  { $CVX collect $cfg keys pre gate split check; echo "EXIT $?"; } >> $l 2>&1
  grep -q '^EXIT 0' $l || { say "$n: collect FAILED again ($l)"; return 1; }
  say "$n: collect done"; }
while active ana-col10b; do sleep 60; done
b10=; grep -q 'col10b DONE' $V/col10b.log || { resume col10b collect10b tools/corpus-v2/collect/bend-run10b.cfg && b10=1; }
while active ana-col10; do sleep 120; done
if ! grep -q 'col10 DONE' $V/col10.log; then
  resume col10 collect10 tools/corpus-v2/collect/bend-run10.cfg && { say "col10.sh"; bash $V/col10.sh >> $V/col10.log 2>&1; }
fi
grep -q 'col10 DONE' $V/col10.log && say "col10: $(grep 'col10 clean:' $V/col10.log | tail -n 1)" || say "col10 did not finish ($V/col10.log): R7 goes on without it"
if [ -n "$b10" ] || grep -q '^EXIT 0' $V/collect10b/collect.log 2>/dev/null; then
  grep -q 'col10b DONE' $V/col10b.log || { say "col10b.sh"; bash $V/col10b.sh >> $V/col10b.log 2>&1; }
fi
grep -q 'col10b DONE' $V/col10b.log && say "col10b: $(grep 'col10b clean:' $V/col10b.log | tail -n 1)" || say "col10b did not finish ($V/col10b.log): R7 goes on without it"
if grep -q 'col10 DONE' $V/col10.log; then
  say "f6 (col10's render)"; P=${P:-8} bash $V/f6.sh > $V/f6.log 2>&1 || say "f6 FAILED ($V/f6.log): R7 goes on without col10"
fi
if grep -q 'col10b DONE' $V/col10b.log; then
  say "f6 (col10b's render)"
  F6=$V/f6b N=col10b R=$V/transcripts-col10b/bend/results.train.nul SRCS=$V/collect10b/src/bend P=${P:-8} bash $V/f6.sh > $V/f6b.log 2>&1 \
    || say "f6 FAILED ($V/f6b.log): R7 goes on without col10b"
fi
while active ana-f7; do sleep 60; done
grep -q 'f7: DONE' $V/f7/f7.log && say "f7: $(grep 'joined:' $V/f7/f7.log | tail -n 1)" || say "f7 did not finish ($V/f7/f7.log): R7 goes on without the prove units"
while active ana-f8; do sleep 60; done
grep -q 'f8: DONE' $V/f8/f8.log && say "f8: $(grep 'joined:' $V/f8/f8.log | tail -n 1)" || say "f8 did not finish ($V/f8/f8.log): R7 goes on without the sorts"
# mugen's chats, today's turns too
ML=$V/mlog
if bash $ML/export.sh $ML/raw.nul > $ML/export.log 2>&1 && $V/col10fix/gcroot-cv2/bin/bend-corpus-v2 mugenlog weights/code32k.bpe $ML/raw.nul $ML/mlog.tmp 2048 > $ML/mlog.log 2>&1; then
  mv $ML/mlog.tmp $ML/mlog.nul; rm -f $ML/split.done; say "mlog: $(head -n 1 $ML/mlog.log)"
else say "mlog again FAILED ($ML/export.log, $ML/mlog.log): the 10:51 one stays"; fi
while active ana-prose; do sleep 60; done
grep -q '^rc=0' $V/theory/prose.log || { say "prose FAILED ($V/theory/prose.log)"; exit 1; }
say "run7"; bash $V/run7.sh > $V/run7.log 2>&1; r=$?
say "run7 rc=$r ($V/run7.log)"; tail -n 4 $V/run7.log
exit $r
