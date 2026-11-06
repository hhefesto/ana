#!/usr/bin/env bash
# The GitHub shards' cut for R5c (run5c.sh, at GHCUT): stop the shards here and on delfos, and bring over what delfos's reached.
# A shard whose units a2bsrc.sh has begun (its tree is copied) stays as it is; the others are mirrored, including those fromd.sh copied at 20:45.
cd /home/hhefesto/src/ana || exit 1
set -o pipefail
D=${DELFOS:-192.168.3.6}; R=src/agda2bend/run/a2b; A=$HOME/$R
RS="rsync -a --delete --timeout=600"
say() { echo "$(date '+%F %T') $*"; }
say "cut"
# (a glob only: a name that is not loaded fails the whole command, which is how delfos's shards outlived fromd.sh)
systemctl --user stop ana-ghsched2 2>/dev/null
systemctl --user stop 'a2b-gh[0-9]*'
ssh -o ConnectTimeout=20 $D "systemctl --user stop 'ana-help-ghsched*'; systemctl --user stop 'a2b-gh[0-9]*'" || say "delfos: stop failed"
sleep 20
list=$(ssh -o ConnectTimeout=20 $D "cd $R && ls -d corpus-gh[0-9]* 2>/dev/null | sed 's/corpus-//'") || { say "delfos: no list"; exit 1; }
ok=1
for e in $list; do
  [ -d run/v5/clean/src/a2b$e ] && continue
  $RS $D:$R/ev-$e/ $A/ev-$e/ && $RS $D:$R/$e.log $A/$e.log && $RS $D:$R/corpus-$e/ $A/corpus-$e/ || { say "$e: copy failed"; ok=; continue; }
  say "$e: $(cut -f1 $A/corpus-$e/ledger.tsv | sort -u | wc -l) modules"
done
say "end${ok:+: all here}"
[ -n "$ok" ]
