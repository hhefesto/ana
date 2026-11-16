#!/usr/bin/env bash
# Makes R7's sample for the user (docs/r7/PLAN.md, pipeline step 4) as soon as run7.sh has the mix, so it is there in
# the morning with R7 (the user, 11-15 21:40: "Wait for your OK in the morning").  Waits on ana-r7chain2; a thin
# shim: the picking is r7sample.sh's.  Nothing rented, nothing started on a box.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
M=run/v9/mix7/bend; L=run/v9/run7.log
mixed() { [ -s $M ] && grep -q 'plan-windows\|end: run/v9/R7 is ready' $L 2>/dev/null; }
until mixed; do
  systemctl --user -q is-active ana-r7chain2 || break
  sleep 300
done
mixed || [ -s $M ] || { say "r7sample: no mix ($M): r7chain2 ended first ($(tail -n 1 $L 2>/dev/null))"; exit 1; }
say "r7sample: $M"
bash run/v9/r7sample.sh $M run/v9/R7sample.md || { say "r7sample FAILED"; exit 1; }
# what must not be in it (the user, 11-15: secrets, emails and netsem out)
n=$(grep -c -i -E 'hhefesto@|@rdataa|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|sk-[A-Za-z0-9]{20}|netsem' run/v9/R7sample.md)
say "r7sample: done, $n lines that look private (want 0)"
