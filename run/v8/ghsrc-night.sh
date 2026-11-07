#!/usr/bin/env bash
# R5c's units of the GitHub shards as each ends (11-05): the same a2bsrc.sh run5c.sh would run for them at the deadline, N at a time (a shard's
# decl-new alone is 20 minutes, and they are 30 or more), so the tail starts with them done.  Each writes "NAME DONE" in a2bsrc15.log, which run5c.sh skips.
# It stops at DEADLINE less 15 minutes; run5c.sh waits for this unit and runs what is left.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') ghsrc: $*"; }
DL=$(( $(date -d "${DEADLINE:-2026-11-05 21:00}" +%s) - 900 ))
A=/home/hhefesto/src/agda2bend/run/a2b
N=${N:-2}
active() { systemctl --user is-active -q "$1"; }
while [ "$(date +%s)" -lt "$DL" ]; do
  for d in $A/corpus-gh[0-9]*; do
    [ -d "$d" ] || continue
    e=${d##*/corpus-}; n=a2b$e
    case $e in *-*) continue ;; esac
    grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
    active a2b-$e && continue
    [ -s $d/ledger.tsv ] || continue
    [ -e run/v8/ghsrc.failed.$e ] && continue
    mkdir run/v8/ghsrc.claim.$e 2>/dev/null || continue
    while [ "$(jobs -rp | wc -l)" -ge "$N" ]; do wait -n; done
    k=${e#gh}; say "$e"
    ( CHECK_PROCS=4 CHECKD_N=2 CHECKD_PORT=$((47400 + 4 * (k % 90))) run/v5/clean/a2bsrc.sh $e >> run/v8/a2bsrc-$e.log 2>&1 \
        && echo "$(date '+%F %T') $n DONE" >> run/v8/a2bsrc15.log \
        || { touch run/v8/ghsrc.failed.$e; say "$e FAILED (run/v8/a2bsrc-$e.log)"; } 
      rmdir run/v8/ghsrc.claim.$e ) &
  done
  sleep 120
done
wait
say "end"
