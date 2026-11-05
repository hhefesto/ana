#!/usr/bin/env bash
# agda2bend's 5747eec emits that never reached ana (2026-11-03; the user's goal 34718: close the
# Bend generation, bring in what is cheap): a2bv.sh waited for "KEY: exit" lines in
# ev-nu/requeue.log that requeue.sh never wrote (it was stopped with stdlib on 10-30), so its
# plfa, aa, hs and prelude streams (a2bplfa4, a2baa3, a2bhs, a2bpre) gave up on 10-31 01:28; the
# emits themselves ended (their logs run to the last module).  As a2bum12.sh, no Python: the
# units are each emit's corpus copies (files-jsonl, ids a2b:mods/PATH), the tree its own modules
# (src/: a copy leaves out the items wider than A2B_CORPUS_LINE and checks against the same
# imports; a tree of copies failed most units: a2bum 4,410 of 4,901, a2bplfa3 901 of 1,289);
# decl-new sees every earlier a2b stream's train units, so only declarations no earlier run has
# become units (an export's standard library modules too: a2bm9 has 723 of its 1,657); cap,
# trim (Bend), check, render.  mix6.sh adds run/v6/transcripts-NAME/bend/transcripts.train.nul.
#   a2bsrc.sh plfa      a2bplfa5: corpus-plfa-v5747 (PLFA part1-3 and its library cone)
#   a2bsrc.sh aa        a2baa4:   corpus-aa-v5747 (agda-algebras, Apache-2.0, and its cone)
#   a2bsrc.sh hs        a2bhs2:   corpus4v (agda2hs-base)
#   a2bsrc.sh prelude   a2bpre2:  corpus5v (agda-prelude)
#   a2bsrc.sh all       the four in turn (each after a2bum12 and the one before)
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
K=${1:?usage: a2bsrc.sh plfa|aa|hs|prelude|all}
if [ "$K" = all ]; then
  while systemctl --user is-active -q ana-a2bum12; do sleep 300; done
  for k in plfa aa hs prelude; do "$0" $k || exit 1; done
  exit 0
fi
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
A=/home/hhefesto/src/agda2bend
case $K in
  plfa)    N=a2bplfa5; C=corpus-plfa-v5747 ;;
  aa)      N=a2baa4;   C=corpus-aa-v5747 ;;
  hs)      N=a2bhs2;   C=corpus4v ;;
  prelude) N=a2bpre2;  C=corpus5v ;;
  # 11-04's emits, through tools/checkd, for the last plan (run/v8/run5c.sh): PLFA's cone, the standard library and
  # agda-categories, agda-unimath with the assumptions as inputs
  plfa19)  N=a2bplfa19; C=corpus-plfa19 ;;
  std16)   N=a2bstd16;  C=corpus-std16 ;;
  um16)    N=a2bum16;   C=corpus-um16 ;;
  um19)    N=a2bum19;   C=corpus-um19 ;;
  # 11-05's, with the dropped definitions as assumptions (A2B_AUTOASSUME), wide lines broken (A2B_CORPUS_WRAP)
  std21|plfa22|um21|aa21|hs21|pre21|pm21|hs23|pre23|at1|rd1|at2|fl1) N=a2b$K; C=corpus-$K ;;
  *) echo "a2bsrc.sh: $K: plfa, aa, hs, prelude or all"; exit 2 ;;
esac
C=$A/run/a2b/$C; T=run/v6/transcripts-$N; SRC=run/v5/clean/src/$N
mkdir -p $T/bend
[ -d $C/src ] && [ -d $C/corpus ] || { say "$N: no $C/src or $C/corpus"; exit 1; }
say "$N: $C: $(tail -n 1 $C.log | cut -c1-160)"
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
SEENX=; for x in a2bm6 a2bm7 a2bm8 a2bm9 a2bm6t a2bm7t a2bplfa a2bplfa2 a2bplfa3 a2bplfa5 a2baa a2baa2 a2baa4 a2bhs2 a2bpre2 a2bum a2bum12 a2bplfa19 a2bstd16 a2bum16 a2bum19 a2bstd21 a2bplfa22 a2bum21 a2baa21 a2bhs21 a2bpre21 a2bpm21 a2bhs23 a2bpre23 a2bat1 a2brd1 a2bat2 a2bfl1; do
  [ run/v6/transcripts-$x = $T ] && continue
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
# Through agda2bend's check daemons (11-05): a check of a unit in a deep module is 30-150 ms there, 2-4 s (and up) by a bend
# of its own, which reads and checks every import each time; a2bum12's 5,296 units took 10 hours on 6 processes.  The
# daemons print what bend prints; a check's limit is theirs, the queue is no timeout's business.
U=$A/tools/checkd/units.sh; mkdir -p /tmp/bx/ud
env $E TIMEOUT=890 $U /tmp/bx/ud/$N $SRC ${CHECKD_PORT:-47300} ${CHECKD_N:-4} env TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-2} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=2 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "$N DONE"
