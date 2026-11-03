#!/usr/bin/env bash
# Every Bend stream of the mix in the mugen shape (2026-11-03; the user 35718: "all ready to train
# ana with as much good bend code we can shortly get and a step closer to mugen as an interface
# (turn wise)"; docs/MUGEN-SHAPE.md).  The same checked units as format 2, so no new verdicts: each
# stream's results.train.nul through bend-transcript's format mugen (TRANSCRIPT_FORMAT=mugen) into
# run/v6/mugen/NAME/transcripts.train.nul (NAME: the stream's directory less `transcripts-`), its
# look-ups from `bend base` under Bend 2.0.39 (base.tsv), every presentation's size (sizes.tsv),
# and bend-agent-laws on what it wrote (laws.log, 0 failed or the stream is not DONE).  A history
# stream (hist5.sh: run/v6/hist-NAME/CLASS) gives its repairs only (MUGEN_ONLY=repair) into
# run/v6/mugen/hist-NAME/transcripts.train.nul, and NAME.train.nul there is the mugen stream less the
# made-up repairs of hist5's units.kept (hist-drop.py), as hist5.sh does for format 2.  mix6.sh
# with MG=1 takes run/v6/mugen/NAME for a stream when its DONE is there, else format 2 (and says so).
# mutate's, the port's whole-file and the nights' transcripts have no results in this layout: they
# stay format 2.
#   mugen6.sh [NAME...]   default: every stream whose results.train.nul and transcripts.train.nul
#                         are there (a stream still checking has neither), then the history streams
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=$PWD/run/v5/gcroot-bend-2.0.39/bin/bend
T=run/v6/mugen/gcroot-bend-transcript/bin/bend-transcript
L=run/v6/mugen/gcroot-bend-agent-laws/bin/bend-agent-laws
H=tools/corpus-v2/hist
M=run/v6/mugen
LAWS=${LAWS:-3}   # bend-agent-laws processes a stream
# one stream: NAME OUT RESULTS... (ONLY in the environment)
one() {
  local n=$1 o=$2; shift 2
  local r
  if [ -e $o/DONE ]; then
    local stale=
    for r in "$@"; do [ $o/DONE -ot $r ] && stale=1; done
    [ -z "$stale" ] && { say "$n: done already"; return 0; }
  fi
  mkdir -p $o; rm -f $o/DONE $o/transcripts.train.nul $o/transcripts.train.nul.tmp $o/base.tsv $o/sizes.tsv
  for r in "$@"; do
    say "$n: base $r"
    $T base $r $o/base.part $B >> $o/base.log 2>&1 || { say "$n: base FAILED"; return 1; }
    cat $o/base.part >> $o/base.tsv; rm -f $o/base.part
  done
  for r in "$@"; do
    say "$n: render $r"
    env TRANSCRIPT_FORMAT=mugen BASE=$o/base.tsv SIZES=$o/sizes.part MUGEN_ONLY=${ONLY:-} \
      $T weights/code32k.bpe $r $o/part.nul 2048 >> $o/render.log 2>&1 || { say "$n: render FAILED"; return 1; }
    cat $o/part.nul >> $o/transcripts.train.nul.tmp; cat $o/sizes.part >> $o/sizes.tsv; rm -f $o/part.nul $o/sizes.part
  done
  mv $o/transcripts.train.nul.tmp $o/transcripts.train.nul
  say "$n: laws"
  local k ok=1
  for k in $(seq 0 $((LAWS - 1))); do SHARD=$k SHARDS=$LAWS $L weights/code32k.bpe $o/transcripts.train.nul > $o/laws.$k.log 2>&1 & done
  wait
  for k in $(seq 0 $((LAWS - 1))); do tail -n 1 $o/laws.$k.log; tail -n 1 $o/laws.$k.log | grep -q ', 0 failed' || ok=; done
  [ -n "$ok" ] || { say "$n: laws FAILED"; return 1; }
  touch $o/DONE
  say "$n: DONE"
}
streams() {
  for d in run/v2/transcripts-nv run/v[5-8]/transcripts-*; do
    local n=${d##*/transcripts-}
    if [ $n = nv ]; then echo "v2 run/v2/results/bend.train.nul"; continue; fi
    [ -s $d/bend/results.train.nul ] && [ -s $d/bend/transcripts.train.nul ] && echo "$n $d/bend/results.train.nul"
  done
}
want() { [ $# -eq 0 ] && return 0; local w; for w in "${ARGS[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }
ARGS=("$@")
bad=0
while read -r n r; do
  if [ ${#ARGS[@]} -gt 0 ] && ! want $n; then continue; fi
  ONLY= one $n $M/$n $r || bad=$((bad + 1))
done < <(streams)
# the history streams: their repairs, and their stream less hist5's units' made-up repairs
for S in v2 collect5 own5; do
  if [ ${#ARGS[@]} -gt 0 ] && ! want hist-$S; then continue; fi
  h=run/v6/hist-$S
  [ -e $h/DONE ] || { say "hist-$S: no $h/DONE"; continue; }
  ONLY=repair one hist-$S $M/hist-$S $h/*/bend/results.train.nul || { bad=$((bad + 1)); continue; }
  [ -e $M/$S/DONE ] || { say "hist-$S: $M/$S not DONE"; bad=$((bad + 1)); continue; }
  if [ ! -s $M/hist-$S/$S.train.nul ] || [ $M/hist-$S/$S.train.nul -ot $M/$S/DONE ]; then
    python3 -I $H/hist-drop.py $M/$S/transcripts.train.nul $M/hist-$S/$S.train.nul.tmp $h/units.kept > $M/hist-$S/drop.log 2>&1 \
      && mv $M/hist-$S/$S.train.nul.tmp $M/hist-$S/$S.train.nul || { say "hist-$S: drop FAILED"; bad=$((bad + 1)); continue; }
    cat $M/hist-$S/drop.log
  fi
done
say "mugen6: $bad failed"
[ $bad = 0 ]
