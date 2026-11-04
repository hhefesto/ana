#!/usr/bin/env bash
# The chains (docs/MUGEN-SHAPE.md "Chains", 2026-11-04): one session a unit with wrong edits and their
# recorded errors before the fix, each Bend stream's into run/v6/mugen/chain/NAME/transcripts.train.nul, with
# no checker run (MUGEN_ONLY=chain over the stream's results, its look-ups from its own base.tsv), and
# bend-agent-laws on it (0 failed or the stream is not DONE).  Each worker takes the largest stream not
# DONE and not claimed (mkdir, atomic) until none is left; start as many as the memory takes (about 2 GB each).
#   chain6.sh              a worker
#   chain6.sh night        ana's own mistakes: the nights' format 2 transcripts on own5's results, into .../night
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
C=run/v6/mugen/chain
T=$C/gcroot-bend-transcript/bin/bend-transcript
L=$C/gcroot-bend-agent-laws/bin/bend-agent-laws
say() { echo "$(date '+%F %T') $*"; }
laws() { local o=$1 n=$2 k ok=1
  for k in 0 1; do SHARD=$k SHARDS=2 $L weights/code32k.bpe $o/transcripts.train.nul > $o/laws.$k.log 2>&1 & done
  wait
  for k in 0 1; do tail -n 1 $o/laws.$k.log | grep -q ', 0 failed' || ok=; done
  [ -n "$ok" ] || { say "$n: laws FAILED"; return 1; }
  touch $o/DONE; say "$n: DONE, $(( $(tr -cd '\0' < $o/transcripts.train.nul | wc -c) / 2 )) sessions"; }
if [ "${1:-}" = night ]; then
  o=$C/night; rm -rf $o; mkdir -p $o
  cat run/v5/act5/ws/night*/accepted/bend-fix/transcripts.train.nul run/v5/act5/ws/night*/accepted/bend-act/transcripts.train.nul > $o/night.nul
  env TRANSCRIPT_FORMAT=mugen MUGEN_ONLY=night NIGHT=$o/night.nul BASE=run/v6/mugen/own5/base.tsv SIZES=$o/sizes.tsv \
    $T weights/code32k.bpe run/v5/transcripts-own5/bend/results.train.nul $o/transcripts.train.nul 2048 > $o/render.log 2>&1 || { say "night: render FAILED"; exit 1; }
  rm -f $o/night.nul
  laws $o night; exit
fi
results() { [ "$1" = v2 ] && { echo run/v2/results/bend.train.nul; return; }; ls run/v[5-8]/transcripts-$1/bend/results.train.nul 2>/dev/null | head -1; }
next() { local d n r
  for d in run/v6/mugen/*/DONE; do
    d=${d%/DONE}; n=${d##*/}
    case $n in hist-*|chain|haskell|agda|lean|nix|*.old) continue ;; esac
    r=$(results $n); [ -s "$r" ] || continue
    [ -e $C/$n/DONE ] && continue
    [ -d $C/q/claim-$n ] && continue
    echo "$(stat -c %s $r) $n"
  done | sort -rn | while read -r _ n; do mkdir $C/q/claim-$n 2>/dev/null && { echo $n; break; }; done; }
mkdir -p $C/q
bad=0
while :; do
  n=$(next); [ -n "$n" ] || break
  o=$C/$n; r=$(results $n); rm -rf $o; mkdir -p $o
  say "$n: claimed ($r)"
  if env TRANSCRIPT_FORMAT=mugen MUGEN_ONLY=chain BASE=run/v6/mugen/$n/base.tsv SIZES=$o/sizes.tsv \
       $T weights/code32k.bpe $r $o/part.nul 2048 > $o/render.log 2>&1; then
    mv $o/part.nul $o/transcripts.train.nul; laws $o $n || bad=$((bad + 1))
  else say "$n: render FAILED ($o/render.log)"; bad=$((bad + 1)); fi
done
say "chain6: none left, $bad failed"
[ $bad = 0 ]
