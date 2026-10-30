#!/usr/bin/env bash
# col6's dropped units again, with Bend checks at 180 s instead of 60 (2026-10-30).
# ana-units6's col6 check began 10-28 22:33, before the 180 s deploy (10-29 17:50), so its
# bend-check runs every unit with `timeout 60`, at load ~70 on 16 cores.  At that load a2bm6 lost
# 361 of 1,731 originals to the 60 s limit.  The user, 10-29 ~17:55 UTC-6, said yes to rechecking
# at 180 s what the 60 s limit lost; recheck180.sh does it for a2bm6, a2bm7, collect5 and v2, not for
# col6, the biggest stream (65,778 units).  This is recheck180.sh's again() for col6:
#   waits for ana-units6 (col6's check, hist-pick, render), then col6's units whose original no
#   check shard kept (results.[0-9]*.nul), into run/v6/transcripts-col6t, checked and rendered as
#   col6 was (TRANSCRIPT_FORMAT=2, COPIES=4; no mutate: col6 ran without MUTATE).  A real failure
#   fails fast; only the units that ran out of time cost time.  mix6.sh adds
#   run/v6/transcripts-col6t; mixgo6ff.sh waits for this unit (ana-col6t).
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
P=${PROCS:-6}
O=run/v6/transcripts-col6
T=run/v6/transcripts-col6t
say "col6t: waiting for ana-units6"
while systemctl --user is-active -q ana-units6; do sleep 300; done
say "ana-units6: $(systemctl --user show ana-units6 -p Result --value)"
say "deploy: $(readlink -f run/v5/gcroot-deploy-982e162)"
[ -e $T/DONE ] && { say "col6t: done already"; exit 0; }
ls $O/bend/results.[0-9]*.nul > /dev/null 2>&1 || { say "col6t: no check shards in $O/bend: col6's check did not end"; exit 1; }
mkdir -p $T/bend
if [ ! -s $T/bend/units.nul ]; then
  cp $O/bend/files-lo.nul $O/bend/files-hi.nul $T/bend/
  python3 -I - $O/bend/units.nul $T/bend/units.nul.tmp $O/bend/results.[0-9]*.nul <<'PY' || { say "col6t units FAILED"; exit 1; }
import sys
def pairs(p):
    d = open(p, 'rb').read().split(b'\0')
    return [(d[i], d[i + 1]) for i in range(0, len(d) - 1, 2)]
kept = set()
for r in sys.argv[3:]: kept |= {i for i, _ in pairs(r)}
n = 0
with open(sys.argv[2], 'wb') as o:
    for i, f in pairs(sys.argv[1]):
        if i not in kept: o.write(i + b'\0' + f + b'\0'); n += 1
print('dropped units', n, 'kept before', len(kept))
PY
  mv $T/bend/units.nul.tmp $T/bend/units.nul
fi
say "col6t: check+render, $(( $(tr -cd '\000' < $T/bend/units.nul | wc -c) / 2 )) units, $P checks at a time"
env CORPUS=$O/col6.jsonl OUT=$T BEND=$B BEND_SRC=run/v6/collect/src/bend MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 \
  TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=$P CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 \
  $D transcripts all bend > $T/all.log 2>&1 || { say "col6t all FAILED"; exit 1; }
touch $T/DONE
say "col6t DONE: $(grep 'check:' $T/all.log | tail -1)"
