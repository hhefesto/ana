#!/usr/bin/env bash
# The final training mix with the bend-ff streams (the user, 2026-10-30 06:4x: "the bend-ff stream
# should go into the training mix (don't see why not)").  Replaces mixgo6.sh's wait (unit
# ana-mixgo6, stopped at 06:4x; its now-mix, FF=0, is run/v6/mix/bend-now): when every stream run
# has ended (mixgo6.sh's list, plus ff6.sh's three: ana-ff6, ana-ff6c, ana-ff6s), mix6.sh with
# FF=1 (ratio=4 cap=4 derive=whole) to run/v6/mix/bend, the mix to train on.  ana-a2bum now waits
# for the fresh agda-unimath emit (the user 10-30: "Do start a fresh agda-unimath").
# 10-30 07:5x: waits for ana-col6t too (recheck180c.sh: col6's units the 60 s limit dropped, at 180 s).
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
mkdir -p run/v6/mix
say "mixgo6ff: waiting (FF=1)"
for u in ana-units6 ana-recheck6 ana-refill6 ana-retree6 ana-hist5 ana-upg6 ana-upg2 ana-gav6 ana-upg6b ana-br6 ana-sub6 ana-brf6 ana-sess7 ana-gen5 ana-upg5 ana-a2bm6 ana-col7 ana-recheck180 ana-a2bum ana-a2bplfa4 ana-a2baa3 ana-a2bm9 ana-a2bhs ana-a2bpre ana-ff6 ana-ff6c ana-ff6s ana-col6t; do
  while systemctl --user is-active -q $u; do sleep 300; done
  say "$u: $(systemctl --user show $u -p Result --value)"
done
say "mix6 final (FF=1): start"
FF=1 run/v5/clean/mix6.sh run/v6/mix/bend > run/v6/mix/bend.log 2>&1
say "mix6 final (FF=1): exit $?"
tail -30 run/v6/mix/bend.log
