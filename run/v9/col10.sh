#!/usr/bin/env bash
# Run 10's collection (2026-11-15; R7's change 1, docs/r7/PLAN.md: new code, not replays.  The user, 11-04: "keep
# adding units until I prompt you to stop"; 11-14: "look for new bend code, laws").  As run/v5/clean/col9.sh, with
# tools/corpus-v2/collect/bend-run10.cfg (every repository run 9 took as growth, BendHub, the upstream since run 9's
# pin, the 26 licensed Bend 2 repositories `gh` found on 11-14), everything under run/v9: the collection, then
# sources, units, decl-new (less every unit an earlier stream trained on or held out), the cap, trim, the check and
# clean (HOLDOUT_PCT=0: R7's fixed validation set is split off later, by file, CorpusV2/Valid.bend).
# No render here: R7 renders the checked units in the mugen shape with their laws (run/v9/f6.sh).  Nothing rented.
# A thin shim: the logic is bend-corpus-v2's and deploy's.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
DN=run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2
V=run/v9; CFG=tools/corpus-v2/collect/bend-run10.cfg
C=$V/collect10/bend; SRC=$V/collect10/src/bend; T=$V/transcripts-col10
mkdir -p $V/collect10/src
if ! grep -q '^EXIT 0' $V/collect10/collect.log 2>/dev/null; then
  touch $V/collect10/src/PINS.tsv
  [ -d $V/collect10/keycache ] || cp -a run/v8/collect9/keycache $V/collect10/keycache
  say "col10: collect ($(grep -c '^growth ' $CFG) growth, $(grep -c '^repo ' $CFG) new, hub, upstream)"
  { run/v5/clean/bend-corpus-v2 collect $CFG all; echo "EXIT $?"; } >> $V/collect10/collect.log 2>&1
  grep -q '^EXIT 0' $V/collect10/collect.log || { say "collect FAILED"; tail -5 $V/collect10/collect.log; exit 1; }
fi
cat $C/summary.txt 2>/dev/null
[ -s $C/bend.jsonl ] || { say "col10: no train files"; exit 0; }
mkdir -p $T
[ -e $T/col10.jsonl ] || cp $C/bend.jsonl $T/col10.jsonl
HELD=
for h in vault holdout; do
  HJ=$C/$h/bend.jsonl; HT=$T/held/v10-$h
  [ -s $HJ ] || continue
  HELD="$HELD held=$HJ"
  if [ ! -e $HT/bend/units.nul ]; then
    mkdir -p $HT
    HE="CORPUS=$HJ OUT=$HT BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
    say "col10 held $h units"
    env $HE $D transcripts sources bend > $HT/sources.log 2>&1 && env $HE CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $HT/units.log 2>&1 || { say "held $h FAILED"; exit 1; }
  fi
  HELD="$HELD held=$HT/bend/units.nul"
done
E="CORPUS=$T/col10.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "col10 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "col10 units"; env $E CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  # seen: every Bend stream's trained results (agda2bend's are another tree's: left out), col6-col9's units after
  # decl-new; held: every collection's vault and holdout, as col9's, and col9's
  SEEN="seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul"
  for x in run/v[5-8]/transcripts-*/bend/results.train.nul; do
    case $x in */transcripts-a2b*) continue ;; esac; SEEN="$SEEN seen=$x"; done
  for x in run/v6/transcripts-col6 run/v7/transcripts-col7 run/v8/transcripts-col8 run/v8/transcripts-col9; do
    [ -s $x/bend/units.decl.nul ] && SEEN="$SEEN seen=$x/bend/units.decl.nul"; done
  for h in run/v6/transcripts-col6/held/v6-vault run/v6/transcripts-col6/held/v6-holdout run/v7/transcripts-col7/held/v7-vault run/v7/transcripts-col7/held/v7-holdout run/v8/transcripts-col8/held/v8-vault run/v8/transcripts-col8/held/v8-holdout run/v8/transcripts-col9/held/v9-vault run/v8/transcripts-col9/held/v9-holdout; do
    [ -e $h/bend/units.nul ] && HELD="$HELD held=$h/bend/units.nul"; done
  for c in run/v6/collect run/v7/collect run/v8/collect run/v8/collect9; do
    for h in vault holdout; do [ -s $c/bend/$h/bend.jsonl ] && HELD="$HELD held=$c/bend/$h/bend.jsonl"; done; done
  say "col10 decl-new held/seen ($(echo $SEEN | wc -w) seen, $(echo $HELD | wc -w) held)"
  $DN decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) $HELD $SEEN > $T/decl.log 2>&1 || { say "decl FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  say "col10 decl-new cap"
  $DN decl-new $T/bend/units.decl.nul $T/bend/units.nul.full cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "col10 trim"
  $CV trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
  cut -c1-120 $T/bend/units.nul.stats
fi
if [ ! -s $T/bend/results.nul ]; then
  say "col10 check"
  env $E TIMEOUT=180 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 UNIT_JOBS=4 $D transcripts check bend > $T/check.log 2>&1 || { say "check FAILED"; exit 1; }
fi
say "col10 check: $(tr '\n' ' ' < $T/bend/results.nul.stats 2>/dev/null)"
if [ ! -s $T/bend/results.train.nul ]; then
  say "col10 clean"
  env $E $D transcripts clean bend > $T/clean.log 2>&1 || { say "clean FAILED"; exit 1; }
fi
say "col10 clean: $(tr '\n' ' ' < $T/bend/results.train.nul.stats 2>/dev/null)"
say "col10 DONE (checked and cleaned; the render is f6.sh's)"
