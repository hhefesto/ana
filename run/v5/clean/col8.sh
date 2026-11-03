#!/usr/bin/env bash
# Run 8's collection, first half (2026-11-02; the user's goal 34718: close the Bend generation,
# bring in what is cheap; 34762: new public Bend code): tools/corpus-v2/collect/bend-run8.cfg
# (runs 6-7's repositories as growth, BendHub, the upstream since run 6's pin, 20 new repositories
# found by hand), `bend-corpus-v2 collect ... all`, then as col7.sh: the held vault/holdout units,
# sources, units, decl-new held/seen (every run-6/7 stream seen), cap: run/v8/transcripts-col8/bend/
# units.nul.full.  No Python (no history repairs this run); the trim (4 mutants a unit, in Bend),
# the check and the render are the second half.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/clean/bend-corpus-v2
V=run/v8; CFG=tools/corpus-v2/collect/bend-run8.cfg
C=$V/collect/bend; SRC=$V/collect/src/bend; T=$V/transcripts-col8
mkdir -p $V/collect/src
if ! grep -q '^EXIT 0' $V/collect/collect.log 2>/dev/null; then
  touch $V/collect/src/PINS.tsv
  [ -d $V/collect/keycache ] || cp -a run/v7/collect/keycache $V/collect/keycache
  say "col8: collect ($(grep -c '^growth ' $CFG) growth, $(grep -c '^repo ' $CFG) new, hub, upstream)"
  { $CV collect $CFG all; echo "EXIT $?"; } >> $V/collect/collect.log 2>&1
  grep -q '^EXIT 0' $V/collect/collect.log || { say "collect FAILED"; tail -5 $V/collect/collect.log; exit 1; }
fi
cat $C/summary.txt 2>/dev/null
[ -s $C/bend.jsonl ] || { say "col8: no train files"; exit 0; }
mkdir -p $T
[ -e $T/col8.jsonl ] || cp $C/bend.jsonl $T/col8.jsonl
SEEN=
for h in vault holdout; do
  HJ=$C/$h/bend.jsonl; HT=$T/held/v8-$h
  [ -s $HJ ] || continue
  SEEN="$SEEN held=$HJ"
  if [ ! -e $HT/bend/units.nul ]; then
    mkdir -p $HT
    HE="CORPUS=$HJ OUT=$HT BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
    say "col8 held $h units"
    env $HE $D transcripts sources bend > $HT/sources.log 2>&1 && env $HE CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $HT/units.log 2>&1 || { say "held $h FAILED"; exit 1; }
  fi
  SEEN="$SEEN held=$HT/bend/units.nul"
done
E="CORPUS=$T/col8.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "col8 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "col8 units"; env $E CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  for x in run/v5/transcripts-port5 run/v5/transcripts-a2bm5; do [ -e $x/bend/results.train.nul ] && SEEN="$SEEN seen=$x/bend/results.train.nul"; done
  for x in run/v6/transcripts-col6 run/v6/transcripts-upg6 run/v6/transcripts-upg2 run/v6/transcripts-gav6 run/v6/transcripts-upg6b run/v6/transcripts-br6 run/v6/transcripts-sub6 run/v6/transcripts-brf6 run/v7/transcripts-col7; do
    [ -s $x/bend/units.decl.nul ] && SEEN="$SEEN seen=$x/bend/units.decl.nul"; done
  for h in run/v6/transcripts-col6/held/v6-vault run/v6/transcripts-col6/held/v6-holdout run/v7/transcripts-col7/held/v7-vault run/v7/transcripts-col7/held/v7-holdout; do
    [ -e $h/bend/units.nul ] && SEEN="$SEEN held=$h/bend/units.nul"; done
  say "col8 decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) held=run/v6/collect/bend/vault/bend.jsonl held=run/v6/collect/bend/holdout/bend.jsonl held=run/v7/collect/bend/vault/bend.jsonl held=run/v7/collect/bend/holdout/bend.jsonl seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-own5/bend/results.train.nul $SEEN > $T/decl.log 2>&1 || { say "decl FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  say "col8 decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul.full cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
say "col8: first half DONE ($T/bend/units.nul.full)"
