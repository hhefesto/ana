#!/usr/bin/env bash
# R5c's units of the smaller emits as each ends (11-05), so that the deadline's hours go to agda-unimath's: a2bsrc.sh takes
# them as they end, one at a time, each seeing the results of those before (decl-new), and writes "NAME DONE" in
# a2bsrc15.log, which run5c.sh then skips.  It stops at DEADLINE less 10 minutes; run5c.sh waits for this unit.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') a2bseq: $*"; }
DL=$(( $(date -d "${DEADLINE:-2026-11-05 21:00}" +%s) - 600 ))
A=/home/hhefesto/src/agda2bend/run/a2b
# (11-05: whichever has ended, not in order: the hours std21 runs need not hold back those already ended.  decl-new's result
# is the same set of declarations either way, each in the stream that came first.)
SEQ=${SEQ:-std21 plfa22 aa21 pm21 hs23 pre23 at1 rd1 at2 fl1}
while :; do
  left=0; took=
  for e in $SEQ; do
    n=a2b$e; grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
    left=$((left + 1))
    systemctl --user is-active -q a2b-$e && continue
    [ -s $A/corpus-$e/ledger.tsv ] || { say "no corpus-$e"; exit 1; }
    [ "$(date +%s)" -ge "$DL" ] && { say "the deadline"; exit 0; }
    say "$e"; took=1
    CHECK_PROCS=${CHECK_PROCS:-5} run/v5/clean/a2bsrc.sh $e >> run/v8/a2bsrc15.log 2>&1 || { say "a2bsrc.sh $e FAILED"; exit 1; }
    break
  done
  [ "$left" = 0 ] && break
  [ "$(date +%s)" -ge "$DL" ] && { say "the deadline, some still going"; exit 0; }
  [ -n "$took" ] || sleep 60
done
say "done"
