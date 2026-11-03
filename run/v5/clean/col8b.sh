#!/usr/bin/env bash
# Run 8's collection, second half (2026-11-03; the user's goal 34718: close the Bend generation;
# 35718: "all ready to train ana with as much good bend code we can shortly get"): col8.sh's
# run/v8/transcripts-col8/bend/units.nul.full (30,435 units, 88,980 mutants), at most 4 mutants a
# unit (bend-corpus-v2 trim-mutants, d976edf: the user's cap of 4 repairs a unit; no unit of col8
# has more, so OUT is the same bytes), then Bend's check and format 2's render, as col7.sh's last
# steps (no history repairs this run: no Python).  CHECK_PROCS 6: ana's half of the CPUs (0-3,
# 8-11), two left for the other streams (11-03 06:56: six under a 10G cap were OOM-killed after
# 21 minutes; run again at 07:21 with CHECK_PROCS=5 under 14G).  mix6.sh adds run/v8/transcripts-col8/bend/transcripts.train.nul.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
V=run/v8; SRC=$V/collect/src/bend; T=$V/transcripts-col8
[ -s $T/bend/units.nul.full ] || { say "col8b: no $T/bend/units.nul.full (col8.sh's first half)"; exit 1; }
E="CORPUS=$T/col8.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.nul ]; then
  say "col8b trim"
  $CV trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
  cat $T/bend/units.nul.stats
fi
say "col8b check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "col8b DONE"
