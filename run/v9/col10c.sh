#!/usr/bin/env bash
# Run 10c: El cubo de Edgar, the user's own public repository (2026-11-16; the user: "after everything has been
# deployed and laws added, add the edgar repo to ana's training corpus").  As run/v9/col10b.sh, with
# tools/corpus-v2/collect/bend-run10c.cfg, under run/v9/collect10c and transcripts-col10c: the collection, sources,
# units, decl-new (less every unit an earlier stream trained on or held out, col10's and col10b's), the cap, trim,
# the check and clean (HOLDOUT_PCT=0).  No render here: run/v9/f6.sh N=col10c F6=run/v9/f6c renders the checked
# units in the mugen shape with their laws.  Nothing rented.  A thin shim: the logic is bend-corpus-v2's and deploy's.
# A thin shim: the logic is bend-corpus-v2's and deploy's.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
DN=run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2
V=run/v9; CFG=tools/corpus-v2/collect/bend-run10c.cfg
C=$V/collect10c/bend; SRC=$V/collect10c/src/bend; T=$V/transcripts-col10c
mkdir -p $V/collect10c/src
if ! grep -q '^EXIT 0' $V/collect10c/collect.log 2>/dev/null; then
  touch $V/collect10c/src/PINS.tsv
  [ -d $V/collect10c/keycache ] || cp -a run/v9/collect10b/keycache $V/collect10c/keycache
  say "col10c: collect ($(grep -c '^repo ' $CFG) new)"
  # col10fix's bend-corpus-v2: a corpus file gone since 11-09 has its cached keys stand (as col10b's, 11-15)
  { run/v9/col10fix/bend-corpus-v2 collect $CFG all; echo "EXIT $?"; } >> $V/collect10c/collect.log 2>&1
  grep -q '^EXIT 0' $V/collect10c/collect.log || { say "collect FAILED"; tail -5 $V/collect10c/collect.log; exit 1; }
fi
cat $C/summary.txt 2>/dev/null
[ -s $C/bend.jsonl ] || { say "col10c: no train files"; exit 0; }
mkdir -p $T
[ -e $T/col10c.jsonl ] || cp $C/bend.jsonl $T/col10c.jsonl
HELD=
for h in vault holdout; do
  HJ=$C/$h/bend.jsonl; HT=$T/held/v10c-$h
  [ -s $HJ ] || continue
  HELD="$HELD held=$HJ"
  if [ ! -e $HT/bend/units.nul ]; then
    mkdir -p $HT
    HE="CORPUS=$HJ OUT=$HT BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
    say "col10c held $h units"
    env $HE $D transcripts sources bend > $HT/sources.log 2>&1 && env $HE CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $HT/units.log 2>&1 || { say "held $h FAILED"; exit 1; }
  fi
  HELD="$HELD held=$HT/bend/units.nul"
done
E="CORPUS=$T/col10c.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "col10c sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "col10c units"; env $E CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
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
  # col10's units first: a unit col10 has is not new here
  K=run/v9/transcripts-col10
  while [ ! -e $K/bend/units.decl.nul ]; do
    systemctl --user -q is-active ana-col10 || { say "col10c: col10 stopped before its decl-new"; exit 1; }
    sleep 300
  done
  SEEN="$SEEN seen=$K/bend/units.decl.nul seen=run/v9/transcripts-col10b/bend/units.decl.nul"
  for h in run/v9/transcripts-col10b/held/v10b-vault run/v9/transcripts-col10b/held/v10b-holdout; do [ -e $h/bend/units.nul ] && HELD="$HELD held=$h/bend/units.nul"; done
  for h in vault holdout; do [ -s run/v9/collect10b/bend/$h/bend.jsonl ] && HELD="$HELD held=run/v9/collect10b/bend/$h/bend.jsonl"; done
  for h in $K/held/v10-vault $K/held/v10-holdout; do [ -e $h/bend/units.nul ] && HELD="$HELD held=$h/bend/units.nul"; done
  for h in vault holdout; do [ -s run/v9/collect10/bend/$h/bend.jsonl ] && HELD="$HELD held=run/v9/collect10/bend/$h/bend.jsonl"; done
  say "col10c decl-new held/seen ($(echo $SEEN | wc -w) seen, $(echo $HELD | wc -w) held)"
  $DN decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) $HELD $SEEN > $T/decl.log 2>&1 || { say "decl FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  say "col10c decl-new cap"
  $DN decl-new $T/bend/units.decl.nul $T/bend/units.nul.full cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "col10c trim"
  $CV trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
  cut -c1-120 $T/bend/units.nul.stats
fi
if [ ! -s $T/bend/results.nul ]; then
  say "col10c check"
  env $E TIMEOUT=180 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 UNIT_JOBS=4 $D transcripts check bend > $T/check.log 2>&1 || { say "check FAILED"; exit 1; }
fi
say "col10c check: $(tr '\n' ' ' < $T/bend/results.nul.stats 2>/dev/null)"
if [ ! -s $T/bend/results.train.nul ]; then
  say "col10c clean"
  env $E $D transcripts clean bend > $T/clean.log 2>&1 || { say "clean FAILED"; exit 1; }
fi
say "col10c clean: $(tr '\n' ' ' < $T/bend/results.train.nul.stats 2>/dev/null)"
say "col10c DONE (checked and cleaned; the render is f6.sh's)"
