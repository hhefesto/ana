#!/usr/bin/env bash
# What stopped at 07:50 for refl (the user, 11-05: "refl always takes priority"), started again once R5b's mix has left the memory (it peaks at 8 G):
# col9's render, um16's units, the units of the emits that have ended, the GitHub shards' units.  Each is hours run5c.sh would otherwise spend after
# the deadline.  One at a time, each when the memory has room, so the guard (under 8 G) need not stop an emit for them; if it stops them, run5c.sh takes up what is left.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
while systemctl --user is-active -q ana-mix2; do sleep 120; done
say "the mix has ended"
room() { while [ "$(awk '/^MemAvailable/ {print int($2/1048576)}' /proc/meminfo)" -lt 13 ]; do sleep 120; done; sleep 300; }
worker() { local u=$1 m=$2 cmd=$3; systemctl --user reset-failed $u 2>/dev/null
  systemd-run --user --unit=$u --collect --slice=ana-work.slice -p WorkingDirectory=$PWD -p MemoryMax=$m -p MemorySwapMax=1G -p OOMPolicy=continue -p StandardOutput=append:$PWD/$4 -p StandardError=append:$PWD/$4 /bin/sh -c "exec $cmd"; say "$u"; }
room; [ -e run/v6/mugen/col9/DONE ] || worker ana-mugen6q1 12G run/v5/clean/mugen6q.sh run/v8/ana-mugen6q1.log
room; grep -q 'a2bum16 DONE' run/v8/a2bsrc15.log || worker ana-src-um16 8G "run/v5/clean/a2bsrc.sh um16" run/v8/a2bsrc15.log
room; worker ana-a2bseq 8G "env CHECK_PROCS=4 bash run/v8/a2bseq.sh" run/v8/a2bseq.log
room; worker ana-ghsrc 12G "env N=2 bash run/v8/ghsrc.sh" run/v8/ghsrc.log
say "end"
