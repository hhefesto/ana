#!/usr/bin/env bash
# Delfos's GitHub shards back here (11-05, the user: "Move all current tasks to just delfos"; ana's streams and the mix stay on olimpo,
# so a shard's units run here).  A shard comes over when its unit on delfos has ended, into a name ghsrc.sh does not see until it is whole.
# 20 minutes before the deadline it stops those still going and copies what they reached, then writes fromd.done, which run5c.sh waits for.
cd /home/hhefesto/src/ana || exit 1
set -o pipefail  # (an ssh that fails must not read as "no shard is running")
D=${DELFOS:-192.168.3.6}; R=src/agda2bend/run/a2b; A=$HOME/$R
say() { echo "$(date '+%F %T') $*"; }
DL=$(( $(date -d "${DEADLINE:-2026-11-05 21:00}" +%s) - 1200 ))
RS="rsync -a --timeout=300"
take() {  # the shard $1, if it has not come yet
  local e=$1
  [ -e $A/corpus-$e ] && return 0
  rm -rf $A/.in-corpus-$e
  $RS $D:$R/ev-$e/ $A/ev-$e/ && $RS $D:$R/$e.log $A/$e.log && $RS $D:$R/corpus-$e/ $A/.in-corpus-$e/ || { say "$e: copy failed"; return 1; }
  mv $A/.in-corpus-$e $A/corpus-$e && say "$e: $(cut -f1 $A/corpus-$e/ledger.tsv | sort -u | wc -l) modules"
}
shards() { ssh -o ConnectTimeout=20 $D "cd $R && ls -d corpus-gh[0-9]* 2>/dev/null | sed 's/corpus-//'"; }
running() { ssh -o ConnectTimeout=20 $D "systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-gh[0-9]*'" | awk '{print $1}' | sed 's/a2b-//; s/.service//'; }
say "up"
while [ "$(date +%s)" -lt "$DL" ]; do
  # (the list first, then what runs: a shard that starts between the two is then not in the list yet, not taken half done)
  list=$(shards) && run=$(running) || { sleep 300; continue; }
  for e in $list; do
    case " $(echo $run) " in *" $e "*) continue ;; esac
    take $e
  done
  sleep 300
done
say "the deadline: stopping delfos's shards"
ssh -o ConnectTimeout=20 $D "systemctl --user stop ana-help-ghsched ana-help-gh ana-help-gh2 ana-help-gh3 'a2b-gh[0-9]*'"
sleep 20
ok=1; for e in $(shards); do take $e || ok=; done
[ -n "$ok" ] && touch run/v8/fromd.done
say "end${ok:+: all here}"
