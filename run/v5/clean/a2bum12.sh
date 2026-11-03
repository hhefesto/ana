#!/usr/bin/env bash
# agda-unimath again, through agda2bend 7adf6f3 -O2 (bin/agda2bend-O2-dg58; agda2bend's
# run/a2b/ev-um/umemit12.sh, unit a2b-umemit12, 11-01 06:58 to 11-03 06:24, "emit exit 0":
# 2,934 modules, 7,627 definitions checked, 3,040 dropped; corpus-um12/corpus: 935 files, 5,755
# defs, against corpus-um's 874 and 5,025), into transcripts (2026-11-03; the user's goal 34718:
# close the Bend generation, bring in what is cheap; the plan 34760: "umemit12: let it finish.
# Then one small stream adds only the definitions earlier streams lack").  No Python (the user
# 10-14).  The units are the corpus copies' (corpus/, as files-jsonl's JSON lines, ids
# a2b:mods/PATH, as a2bum's); the tree is the emit's own modules (src/), since a corpus copy
# leaves out the items wider than A2B_CORPUS_LINE and "checks against the same imports"
# (agda2bend's HANDOFF): a tree of corpus copies misses those items, so a module importing one
# fails (a2bum.sh's tree was the copies: 4,410 of its 4,901 units failed; 11 of 12 sampled
# foundation modules fail against the copies and all 12 pass against src/).  decl-new sees every
# earlier a2b stream's train units (a2bum's too), so only declarations no earlier run has become
# units.  Then a2bv.sh's steps (cap, trim
# in Bend, check, render).  agda-unimath's held-out directory (finite-algebra) is in neither
# corpus.  mix6.sh adds run/v6/transcripts-a2bum12/bend/transcripts.train.nul.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
A=/home/hhefesto/src/agda2bend
N=a2bum12; C=$A/run/a2b/corpus-um12
T=run/v6/transcripts-$N; SRC=run/v5/clean/src/$N
mkdir -p $T/bend
grep -q 'emit exit 0' $A/run/a2b/ev-um/umemit12.log || { say "$N: umemit12 did not end well"; exit 1; }
if [ ! -d $SRC ]; then
  rm -rf $SRC.tmp; mkdir -p $SRC.tmp
  cp -a $C/src $SRC.tmp/mods || { say "$N tree FAILED"; exit 1; }
  mv $SRC.tmp $SRC
fi
if [ ! -s $T/$N.jsonl ]; then
  $CV files-jsonl a2b:mods $C/corpus $T/$N.jsonl > $T/files.log 2>&1 || { say "$N files-jsonl FAILED"; exit 1; }
  cat $T/$N.jsonl.stats
fi
E="CORPUS=$T/$N.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "$N sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "$N units"; env $E CHUNK=25 UNIT_JOBS=2 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
SEENX=; for x in a2bm6 a2bm7 a2bm8 a2bm9 a2bm6t a2bm7t a2bplfa a2bplfa2 a2bplfa3 a2bplfa4 a2baa a2baa2 a2baa3 a2bhs a2bpre a2bum; do
  [ -e run/v6/transcripts-$x/bend/results.train.nul ] && SEENX="$SEENX seen=run/v6/transcripts-$x/bend/results.train.nul"; done
say "$N: seen also:$SEENX"
if [ ! -e $T/bend/units.decl.nul ]; then
  say "$N decl-new held/seen"
  $CV decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-a2bm5/bend/results.train.nul $SEENX > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
  cat $T/bend/units.decl.nul.stats
fi
if [ ! -e $T/bend/units.nul.full ]; then
  say "$N decl-new cap"
  $CV decl-new $T/bend/units.decl.nul $T/bend/units.nul.full cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  $CV trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
  cat $T/bend/units.nul.stats
fi
say "$N check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-2} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=2 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "$N DONE"
