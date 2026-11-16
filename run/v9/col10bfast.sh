#!/usr/bin/env bash
# col10b's check on CHECK_PROCS (12) processes, not col10b.sh's 6 (11-15 22:5x: R7 waits on col10b's check, and by the
# time it starts the machine is idle but for it; R7 by morning, the user: "Wait for your OK in the morning").
# col10b.sh (ana-col10b, pid SH) is held (SIGSTOP) at its decl-new (pid DN), which goes on.  When decl-new ends, this
# runs col10b.sh again in a unit of its own (MemoryMax 20G): each step skips what is done, so it does the cap, trim,
# check and clean.  Then col10b.sh goes on (SIGCONT), finds every step done and says "col10b DONE" for ana-r7chain2.
# Whatever happens, col10b.sh goes on; if this run failed, the outputs it made are moved aside first (none deleted),
# so col10b.sh redoes them.  A thin shim: the steps are col10b.sh's, the logic bend-corpus-v2's and deploy's.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
SH=${SH:?col10b.sh pid}; DN=${DN:?decl-new pid}; T=run/v9/transcripts-col10b/bend
M=/tmp/bx/col10bfast.start; mkdir -p /tmp/bx; touch $M
ok=
fin() {
  if [ -z "$ok" ]; then
    for f in units.nul.full units.nul units.nul.stats results.nul results.nul.stats results.train.nul results.train.nul.stats; do
      [ -e $T/$f ] && [ $T/$f -nt $M ] && mv $T/$f $T/$f.col10bfast-failed && say "col10bfast: moved aside $T/$f"
    done
  fi
  kill -CONT $SH 2>/dev/null && say "col10bfast: col10b.sh ($SH) goes on"
}
trap fin EXIT
trap 'say "col10bfast: stopped"; exit 1' TERM INT
# decl-new's state: Z once it ends (its parent is held, so nothing reaps it), empty once it is gone
st() { [ -r /proc/$DN/stat ] && sed 's/^.*) //' /proc/$DN/stat | cut -d' ' -f1; }
while s=$(st); [ -n "$s" ] && [ "$s" != Z ]; do sleep 60; done
ec=gone; [ "$(st)" = Z ] && ec=$(sed 's/^.*) //' /proc/$DN/stat | cut -d' ' -f50)
[ "$ec" = 0 ] && [ -s $T/units.decl.nul ] || { say "col10bfast: decl-new's status $ec: col10b.sh goes on by itself"; ok=1; exit 1; }
say "col10bfast: decl-new done ($(tail -n 1 run/v9/transcripts-col10b/decl.log | cut -c1-160)); the rest, CHECK_PROCS=${CHECK_PROCS:=12}"
CHECK_PROCS=$CHECK_PROCS bash run/v9/col10b.sh
r=$?
if [ $r = 0 ] && [ -s $T/results.train.nul ]; then ok=1; say "col10bfast: done"; else say "col10bfast: col10b.sh rc=$r"; exit 1; fi
