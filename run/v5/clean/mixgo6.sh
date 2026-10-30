#!/usr/bin/env bash
# The training mix, for real (the user, 2026-10-30 00:1x: "training mix has go-ahead with the cap of
# 4 per unit"): mix6.sh (ratio=4 cap=4 derive=whole; FF=0, the bend-ff streams still wait for the
# user's word) now, on the streams there are, to run/v6/mix/bend-now; then, when every stream run
# has ended (run 6's, run 7's, the agda2bend intakes), again to run/v6/mix/bend, the mix to train on.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
mkdir -p run/v6/mix
say "mix6 now: start"
run/v5/clean/mix6.sh run/v6/mix/bend-now > run/v6/mix/bend-now.log 2>&1
say "mix6 now: exit $?"
tail -30 run/v6/mix/bend-now.log
for u in ana-units6 ana-recheck6 ana-refill6 ana-retree6 ana-hist5 ana-upg6 ana-upg2 ana-gav6 ana-upg6b ana-br6 ana-sub6 ana-brf6 ana-sess7 ana-gen5 ana-upg5 ana-a2bm6 ana-col7 ana-recheck180 ana-a2bum ana-a2bplfa4 ana-a2baa3 ana-a2bm9 ana-a2bhs ana-a2bpre; do
  while systemctl --user is-active -q $u; do sleep 300; done
  say "$u: $(systemctl --user show $u -p Result --value)"
done
say "mix6 final: start"
run/v5/clean/mix6.sh run/v6/mix/bend > run/v6/mix/bend.log 2>&1
say "mix6 final: exit $?"
tail -30 run/v6/mix/bend.log
