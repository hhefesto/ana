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
# (the first version of an id wins, and the ids of the emits are a2b:mods/PATH: the newest emits first, r5c.a2b's in
# reverse, or the old emits' smaller modules stand in for theirs; 11-05)
new=; for s in $(tac -s ' ' run/v8/r5c.a2b); do d=run/v6/transcripts-$s/bend; [ -d $d ] && new="$new $d"; done
rest=$(ls -d run/v[5-8]/transcripts-*/bend | grep -v -x -F -f <(printf '%s\n' $new))
say "filler order:$(printf ' %s' $new | sed 's|run/v6/transcripts-||g; s|/bend||g')"
# (11-05: tools/nulmix's fillunion, seconds where filler-union and keyed-order took 5.7 hours; the same bytes on R5's filler)
run/v6/gcroot-nulmix/bin/fillunion $S/bend/files-hi.nul "run 5c filler" held=run/v2/results/bend.holdout.nul run/v2/transcripts/bend $new $rest > $S/filler.log 2>&1 || { say "fillunion FAILED"; exit 1; }
mv $S/bend/files-hi.nul.tmp $S/bend/files-hi.nul; : > $S/bend/files-lo.nul; touch $S/bend/files.done
say "filler done: $(tr -cd '\0' < $S/bend/files-hi.nul | wc -c) NULs, $(du -h $S/bend/files-hi.nul | cut -f1)"
