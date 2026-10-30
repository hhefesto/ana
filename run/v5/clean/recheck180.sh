#!/usr/bin/env bash
# The units the 60 s Bend check timed out on, again at 180 s, once the machine is quieter.  The
# user, 2026-10-29 ~17:55 UTC-6, "yes" to: "Earlier checks lost correct programs to the 60 s limit
# (361 of 1,731 originals in one stream).  Should I recheck those at 180 s once the machine is
# quieter?"  (Load was ~80 on 16 cores.)  run/v5/gcroot-deploy-982e162 gives Bend checks 180 s
# since 17:50 (deploy-982e162-t180).  Timeouts at 60 s: a2bm6 361 originals (+29 holes), a2bm7 29
# (+4), recheck-collect5 276 (+26), recheck-v2 188 + 2 (+4).  The checks keep no per-unit verdict,
# so every dropped (or stale) unit of those streams is checked again; a real failure fails fast.
#  1. a2bm6, a2bm7: the units their check dropped, into run/v6/transcripts-a2bm6t, -a2bm7t (new
#     streams of mix6.sh), checked, mutated and rendered as the originals were.
#  2. recheck-collect5 (repo), recheck-v2 (curated, own): the stale units again (OUT
#     run/v6/recheck-NAME/CLASS-t180); a unit that checks now leaves CLASS/stale.ids and NAME/stale.ids
#     (the 60 s lists kept as stale.ids.t60), so mix6.sh's fresh() keeps its transcripts.
# Waits for ana-units6 (the big check) and ana-refill6 (it rewrites recheck-v2's curated/stale.ids).
# Not rechecked: collect5's own 10-19 check (209 timeouts among 8,482 dropped; Bend of 10-16) and
# port5 (6).  At the end, if mixafter6 is done, mix6.sh dry into run/v6/mix/dry-t180.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
P=${PROCS:-4}
for u in ana-units6 ana-refill6; do
  while systemctl --user is-active -q $u; do sleep 300; done
  say "$u: $(systemctl --user show $u -p Result --value)"
done
say "deploy: $(readlink -f run/v5/gcroot-deploy-982e162)"

# 1. NAME CORPUS SRC: NAME's dropped units into transcripts-NAMEt
again() {
  local O=run/v6/transcripts-$1 T=run/v6/transcripts-$1t
  [ -e $T/DONE ] && { say "$1t: done already"; return 0; }
  mkdir -p $T/bend
  if [ ! -s $T/bend/units.nul ]; then
    cp $O/bend/files-lo.nul $O/bend/files-hi.nul $T/bend/
    python3 -I - $O/bend/units.nul $T/bend/units.nul.tmp $O/bend/results.[0-9]*.nul <<'PY' || { say "$1t units FAILED"; return 1; }
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
  say "$1t: check+render, $(( $(tr -cd '\000' < $T/bend/units.nul | wc -c) / 2 )) units"
  env CORPUS=$2 OUT=$T BEND=$B BEND_SRC=$3 MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 TRANSCRIPT_FORMAT=2 \
    COPIES=4 CHECK_PROCS=$P CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "$1t all FAILED"; return 1; }
  touch $T/DONE
  say "$1t DONE: $(grep 'check:' $T/all.log | tail -1)"
}
again a2bm6 run/v5/transcripts-a2bm5/a2bm5.jsonl run/v5/clean/src/a2bmf
again a2bm7 run/v6/transcripts-a2bm7/a2bm7.jsonl run/v5/clean/src/a2bm7

# 2. NAME CLASS SRC UNITS...: CLASS's stale units again; those that check leave stale.ids
restale() {
  local N=$1 C=run/v6/recheck-$1/$2 T=run/v6/recheck-$1/$2-t180 SRC=$3; shift 3
  [ -e $T/DONE ] && { say "$N $(basename $C): done already"; return 0; }
  [ -e $C/stale.ids.t60 ] || cp $C/stale.ids $C/stale.ids.t60
  mkdir -p $T/bend
  python3 -I - $C/stale.ids.t60 $T/bend/units.nul "$@" <<'PY' || { say "$N units FAILED"; return 1; }
import sys
want = set(l.rstrip(b'\n') for l in open(sys.argv[1], 'rb') if l.strip())
seen = set()
with open(sys.argv[2], 'wb') as o:
    for p in sys.argv[3:]:
        d = open(p, 'rb').read().split(b'\0')
        for i in range(0, len(d) - 1, 2):
            if d[i] in want and d[i] not in seen:
                seen.add(d[i]); o.write(d[i] + b'\0' + d[i + 1] + b'\0')
print('stale', len(want), 'found', len(seen))
PY
  say "$N $(basename $C): check $(( $(tr -cd '\000' < $T/bend/units.nul | wc -c) / 2 )) stale units"
  if [ -s $T/bend/units.nul ]; then
    env OUT=$T BEND=$B BEND_SRC=$SRC MAX=1000000 MAX_HI=1000000 HOLDOUT_PCT=0 TRANSCRIPT_FORMAT=2 \
      COPIES=4 CHECK_PROCS=$P CHECK_JOBS=1 $D transcripts check bend > $T/check.log 2>&1 || { say "$N check FAILED"; return 1; }
  fi
  [ -e $T/bend/results.nul ] || : > $T/bend/results.nul
  python3 -I - $C/stale.ids.t60 $T/bend/results.nul $C/stale.ids.tmp <<'PY' || { say "$N stale FAILED"; return 1; }
import sys
d = open(sys.argv[2], 'rb').read().split(b'\0')
ok = set(d[i] for i in range(0, len(d) - 1, 2))
a = [l.rstrip(b'\n') for l in open(sys.argv[1], 'rb') if l.strip()]
keep = [u for u in a if u not in ok]
open(sys.argv[3], 'wb').write(b''.join(u + b'\n' for u in keep))
print('stale at 60 s', len(a), 'check at 180 s', len(a) - len(keep), 'stale now', len(keep))
PY
  mv $C/stale.ids.tmp $C/stale.ids
  touch $T/DONE
}
# NAME/stale.ids: its classes' lists again
restale.all() {
  local R=run/v6/recheck-$1; shift
  [ -e $R/stale.ids.t60 ] || cp $R/stale.ids $R/stale.ids.t60
  cat "$@" > $R/stale.ids.tmp && mv $R/stale.ids.tmp $R/stale.ids
  say "recheck-$(basename $R): stale.ids $(wc -l < $R/stale.ids.t60) -> $(wc -l < $R/stale.ids)"
}
R=run/v6/recheck-collect5
restale collect5 repo run/v5/collect/src/bend $R/repo/bend/units.nul && restale.all collect5 $R/repo/stale.ids
R=run/v6/recheck-v2
restale v2 curated $R/src/curated $R/curated/bend/units.nul $R/curated-fill/bend/units.nul && \
restale v2 own $R/src/own $R/own/bend/units.nul && restale.all v2 $R/curated/stale.ids $R/own/stale.ids

if systemctl --user is-active -q ana-mixafter6; then
  say "mixafter6 still running: its dry mix will count these"
else
  mkdir -p run/v6/mix
  run/v5/clean/mix6.sh run/v6/mix/dry-t180 dry > run/v6/mix/dry-t180.log 2>&1
  say "mix6 dry: exit $?"; tail -12 run/v6/mix/dry-t180.log
fi
say "recheck180 DONE"
