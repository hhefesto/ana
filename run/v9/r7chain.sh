#!/usr/bin/env bash
# R7's corpus, end to end on olimpo (2026-11-15; docs/r7/PLAN.md): col10's collection and check (ana-col10, col10.sh),
# then its render (f6.sh), the prose (ana-prose, theory/filler.sh), then run7.sh (f5's join, the mix, the filler, the
# plan, the validation windows).  Nothing is rented: the user's approval comes first.  A thin shim.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') r7chain: $*"; }
active() { systemctl --user is-active -q "$1"; }
while active ana-col10; do sleep 120; done
if grep -q 'col10 DONE' run/v9/col10.log; then
  say "f6 (col10's render)"; P=${P:-8} bash run/v9/f6.sh > run/v9/f6.log 2>&1 || say "f6 FAILED (run/v9/f6.log): R7 goes on without col10"
else say "col10 did not finish (run/v9/col10.log): R7 goes on without it"; fi
while active ana-prose; do sleep 60; done
grep -q '^rc=0' run/v9/theory/prose.log || { say "prose FAILED (run/v9/theory/prose.log)"; exit 1; }
say "run7"; bash run/v9/run7.sh > run/v9/run7.log 2>&1; say "run7 rc=$?"
