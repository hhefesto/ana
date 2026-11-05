#!/usr/bin/env bash
# R5c's filler (the user, 11-05: "Should I rebuild the Bend filler for R5c with col9 and the new agda2bend modules?" "yes"):
# Bend's files, each once, in keyed order, as run5-final.sh makes R5's, with run 9's collection and the new emits' files in.
# (120 MB and hours, so it stays out of the slice the guard stops.)  R5b's filler stays as it is, R5b's and the fallback's.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
CV=$PWD/run/v6/mugen/chain/gcroot-bend-corpus-v2/bin/bend-corpus-v2; S=run/v8/R5csrc; mkdir -p $S/bend
[ -e $S/bend/files.done ] && exit 0
say "filler"; rm -rf $S/bend.tmp
$CV filler-union $S/bend.tmp run/v2/transcripts/bend $(ls -d run/v[5-8]/transcripts-*/bend) held=run/v2/results/bend.holdout.nul > $S/filler.log 2>&1 || { say "filler-union FAILED"; exit 1; }
cat $S/bend.tmp/files-hi.nul $S/bend.tmp/files-lo.nul > $S/bend.tmp/all.nul
$CV keyed-order nul "run 5c filler" $S/bend.tmp/all.nul $S/bend/files-hi.nul >> $S/filler.log 2>&1 || { say "keyed-order FAILED"; exit 1; }
rm -rf $S/bend.tmp; : > $S/bend/files-lo.nul; touch $S/bend/files.done
say "filler done: $(tr -cd '\0' < $S/bend/files-hi.nul | wc -c) NULs, $(du -h $S/bend/files-hi.nul | cut -f1)"
