#!/usr/bin/env bash
# collect5.7.1's laws back into R6 (2026-11-13; the user: "Investigate the hang and fix if viable. Fix with care
# and continue."). Holds ana-run6 frozen while it is still only waiting for the renders (they go on: their own
# units), waits for the fixed bend-corpus-v2 (run/v9/f3/gcroot-cv2-spfix), redoes the chunk into law/redo
# (f3-redo-chunk.sh, at most 1 h), and swaps it in only when every check holds:
#   exit 0; as many NUL pairs as the input; a log line a unit; the first units' lines the same as the hung
#   run's log (the old binary's, up to the unit it hung on).
# The swap keeps every old file in law/redo and sets the collect5.7 render job aside, so run6's retry renders
# it again with the laws. Any failed check: nothing moves, collect5.7.1 stays passed through. ana-run6 is
# thawed on every exit.
set -uo pipefail
cd ~/src/ana
F=run/v9/f3; C=collect5.7.1; J=collect5.7; R=$F/law/redo; LOG=$R/swap.log
say() { echo "$(date '+%F %T') $*" | tee -a $LOG; }
mkdir -p $R
cg=/sys/fs/cgroup$(systemctl --user show ana-run6 -p ControlGroup --value)
systemctl --user freeze ana-run6 || { say "could not freeze ana-run6: nothing done"; exit 1; }
trap 'systemctl --user thaw ana-run6; say "ana-run6 thawed"' EXIT
late=$(while read -r p; do tr '\0' ' ' < /proc/$p/cmdline; echo; done < $cg/cgroup.procs | grep -v -e '^/run/current-system/sw/bin/bash run/v9/run6.sh' -e '^sleep ' -e '^$')
[ -z "$late" ] || { say "run6 already past the renders ($late): nothing done"; exit 1; }
say "ana-run6 held (waiting for the renders)"
while systemctl --user is-active -q ana-cv2-spfix; do sleep 15; done
CV=$(readlink -f $F/gcroot-cv2-spfix)/bin/bend-corpus-v2
[ -x "$CV" ] || { say "no fixed binary ($F/cv2-spfix.build.log)"; exit 1; }
say "redo $C with $CV"
timeout 3600 bash run/v9/f3-redo-chunk.sh $CV $C >> $LOG 2>&1; rc=$?
[ $rc = 0 ] || { say "redo failed (exit $rc): $C stays passed through"; exit 1; }
nin=$(tr -cd '\0' < $F/law/in/$C.nul | wc -c); nout=$(tr -cd '\0' < $R/$C.nul | wc -c)
[ "$nin" = "$nout" ] || { say "NULs: in $nin, out $nout: no swap"; exit 1; }
units=$(( nin / 2 )); lines=$(grep -c '' $R/$C.nul.log)
[ "$lines" = "$units" ] || { say "log: $lines lines for $units units: no swap"; exit 1; }
old=$F/law/out/$C.nul.log; k=$(grep -c '' $old)
cmp -s <(head -n $k $old) <(head -n $k $R/$C.nul.log) || { say "the first $k units differ from the hung run's log: no swap"; diff <(head -n $k $old) <(head -n $k $R/$C.nul.log) | head -20 >> $LOG; exit 1; }
say "checks hold: $units units, the first $k as before; unit $((k + 1)): $(sed -n "$((k + 1))p" $R/$C.nul.log | cut -c1-160)"
mv $F/law/out/$C.nul $R/$C.nul.passthrough && mv $F/law/out/$C.nul.log $R/$C.nul.log.hung && mv $F/law/out/$C.failed $R/$C.failed.old \
  && mv $F/law/out/$C.out $R/$C.out.hung && mv $R/$C.nul.stats $F/law/out/$C.nul.stats && mv $R/$C.nul.log $F/law/out/$C.nul.log \
  && mv $R/$C.out $F/law/out/$C.out && mv $R/$C.nul $F/law/out/$C.nul || { say "a move failed: look at $R and $F/law/out"; exit 1; }
[ -e $F/law/$J.nul ] && mv $F/law/$J.nul $R/$J.nul.unlawed
[ -d $F/q/$J ] && mv $F/q/$J $R/q-$J.unlawed
say "swapped: $C has its laws ($(tail -n 1 $F/law/out/$C.out)); $J set aside for run6's retry to render again"
