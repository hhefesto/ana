#!/usr/bin/env bash
# 11-04: filler-union hung 6 h: st.fu.dirs.of had the recursion in both branches of a strict Bool.pick, 2^n in its
# arguments (50 streams now). Fixed; R5's own plan is skipped, as the user chose R5b: the filler, then run5b.sh.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
nix build .#bend-corpus-v2 -o run/v6/gcroot-bend-corpus-v2-fu || { say "build FAILED"; exit 1; }
CV=run/v6/gcroot-bend-corpus-v2-fu/bin/bend-corpus-v2; S=run/v6/R5src
say "filler"; rm -rf $S/bend.tmp
$CV filler-union $S/bend.tmp run/v2/transcripts/bend $(ls -d run/v[5-8]/transcripts-*/bend | grep -v transcripts-col9) held=run/v2/results/bend.holdout.nul > $S/filler.log 2>&1 || { say "filler-union FAILED"; exit 1; }
cat $S/bend.tmp/files-hi.nul $S/bend.tmp/files-lo.nul > $S/bend.tmp/all.nul
mkdir -p $S/bend
$CV keyed-order nul "run 5 filler" $S/bend.tmp/all.nul $S/bend/files-hi.nul >> $S/filler.log 2>&1 || { say "keyed-order FAILED"; exit 1; }
rm -rf $S/bend.tmp; : > $S/bend/files-lo.nul; touch $S/bend/files.done
say "filler done"
while systemctl --user is-active -q ana-chain7b; do sleep 60; done
# (the filler takes 120 MB and hours, so it stays out of the slice the guard stops; run5b, 14 GB, goes in it)
exec systemd-run --user --unit=ana-run5b --slice=ana-work.slice --same-dir --collect -p StandardOutput=append:$PWD/run/v6/run5b.log -p StandardError=append:$PWD/run/v6/run5b.log bash run/v6/run5b.sh
