#!/usr/bin/env bash
# r5c-swap.sh (11-06 03:20): the run5c.sh that started at 22:43 still reads its old text (sed -i makes a new file), with the filler at 55%, which R5b has
# shown is too little.  At "the mugen shape" nothing is in its own cgroup any more (the workers are units of their own, and it only waits for them), so stop it
# there: ana-r5watch brings it back on the new text, and steps keep what they finished.  The GitHub streams' 20 minutes each are not lost that way.
cd /home/hhefesto/src/ana || exit 1
until grep -q ' the mugen shape$' run/v8/run5c.log; do sleep 30; done
echo "$(date '+%F %T') r5c-swap: stopping run5c for r5watch to restart it on the new text" >> run/v8/r5watch.log
systemctl --user stop ana-run5c
