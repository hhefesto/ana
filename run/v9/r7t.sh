#!/usr/bin/env bash
# run/v9/r7t.sh (11-15): a small copy of run7.sh's inputs in /tmp/bx/r7t/root, to try its filler, plan-windows and validation stages
# (lines 81-83 and 86-end) before the R7 chain gets there.  Writes only under /tmp/bx/r7t.
# Then: cd /tmp/bx/r7t/root; PWJOBS=2 TICK=5 bash /tmp/bx/r7t/run7t.sh  (11-15 15:46: rc=0, "end: run/v9/R7 is ready"; 920
# sessions, 1 shard, 411 windows; prose 3000 pieces as its own language; R7valid 150 sessions, 19 held-out files, 111 windows).
set -e
A=/home/hhefesto/src/ana; R=/tmp/bx/r7t/root
mkdir -p $R && cd $R
head_pairs() { LC_ALL=C gawk -v n=$2 'BEGIN{RS="\0"; ORS="\0"} NR > 2*n {exit} {print}' "$1"; }
mkdir -p run/v9/f5 run/v8 run/v6 weights run/v9/mix7 run/v8/R5dsrc/bend run/v9/theory/prose run/v9/f5/valid/a run/v9/mlog run/v2/results
ln -sfn $(readlink -f $A/run/v9/f5/gcroot-cv2) run/v9/f5/gcroot-cv2
ln -sfn $A/run/v8/r5d.a2b run/v8/r5d.a2b
for t in prepare windows plan-segment plan-windows mix; do ln -sfn $(readlink -f $A/run/v6/gcroot-bend-$t) run/v6/gcroot-bend-$t; done
ln -sfn $A/weights/code32k.bpe weights/code32k.bpe
head_pairs $A/run/v9/f5/mugen/a2bgh1/transcripts.train.nul 600 > run/v9/mix7/bend
for l in haskell agda lean nix; do
  head_pairs $A/run/v9/mixg/$l 80 > run/v9/mix7/$l
  mkdir -p run/v2/transcripts/$l
  head_pairs $A/run/v2/transcripts/$l/files-hi.nul 150 > run/v2/transcripts/$l/files-hi.nul
  head_pairs $A/run/v2/transcripts/$l/files-lo.nul 50 > run/v2/transcripts/$l/files-lo.nul
done
for l in bend haskell agda lean nix; do ln -sfn $A/run/v2/results/$l.holdout.nul run/v2/results/$l.holdout.nul; done
head_pairs $A/run/v8/R5dsrc/bend/files-hi.nul 3000 > run/v8/R5dsrc/bend/files-hi.nul; touch run/v8/R5dsrc/bend/files.done
head_pairs $A/run/v9/theory/prose/files-hi.nul 3000 > run/v9/theory/prose/files-hi.nul
head_pairs $(find $A/run/v9/f5/valid -name transcripts.train.nul -size +100k | head -n 1) 150 > run/v9/f5/valid/a/transcripts.train.nul
: > run/v9/mlog/valid.nul
# the script: run7.sh's head (to line 38), its session count (81-83) and its filler on (86-end)
{ sed -n 1,38p $A/run/v9/run7.sh | sed "s|^cd /home/hhefesto/src/ana|cd $R|"; sed -n 81,83p $A/run/v9/run7.sh; sed -n '86,$p' $A/run/v9/run7.sh; } > /tmp/bx/r7t/run7t.sh
for f in run/v9/mix7/* run/v8/R5dsrc/bend/files-hi.nul run/v9/theory/prose/files-hi.nul run/v9/f5/valid/a/transcripts.train.nul; do
  printf '%s %s\n' "$(tr -cd '\0' < $f | wc -c)" "$f"; done
