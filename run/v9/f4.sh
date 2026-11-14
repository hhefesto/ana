#!/usr/bin/env bash
# R7's Bend streams (2026-11-14; docs/r7/PLAN.md).  The user, 11-14: "stop the training, pull the latest weights and
# work on these" (the eight corpus changes), "We'll only concentrate in bend at the time being".  f3.sh's way, on
# f3's own results: exlaw again on f3's exlaw outputs (a unit with laws passes through, `skip.has-laws`; the rest are
# probed with the head's own data types and Base's Maybe, CorpusV2/ExlawText.bend "The file's own data types"), then
# every Bend job rendered again (bend/Transcript.bend: a look before each retry, the laws in fill and repair asks).
# Layout as f3's under run/v9/f4.  Nothing is rented here.  A thin shim: the logic is bend-corpus-v2's and
# bend-transcript's.
#   f4.sh plan    the chunks (f3's law/out, linked) and the jobs (f3's)
#   f4.sh law     a worker: exlaw on the chunks not DONE and not claimed, largest first
#   f4.sh work    a worker: renders the jobs whose chunks are all DONE (no exlaw: at once), largest first
#   f4.sh retry   the claims not DONE dropped (law and render), then law and work again in this process
#   f4.sh join    each job's stream whose parts are all DONE, as f3.sh's join; the linked streams
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=run/v9/f4
F2=run/v9/f2
F3=run/v9/f3
T=$F/gcroot/bin/bend-transcript
L=$F/gcroot-laws/bin/bend-agent-laws
CV=$F/gcroot-cv2/bin/bend-corpus-v2
HD=run/v5/gcroot-bend-corpus-v2-hd/bin/bend-corpus-v2
Q=$F/q
CHUNK=${CHUNK:-300}
# the trees the streams were checked in (run/*/run.sh, col9-olimpo.sh, the own runs), then Eval's
SRCS=run/v5/clean/src/own:run/v8/collect9/src/bend:run/v6/collect/src/bend:run/v8/collect/src/bend:run/v5/collect/src/bend
for d in run/code-sources*/curated run/code-sources*/own; do SRCS=$SRCS:$d; done
say() { echo "$(date '+%F %T') $*"; }
size() { stat -L -c %s "$1"; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
# a job's kind: law (exlaw, then render), render, link
kind() { case $1 in agda|haskell|lean|nix|hist-*) echo link ;; a2b*|night) echo render ;; *) echo law ;; esac; }
plan() {
  [ -s $F3/q/jobs ] || { say "no $F3/q/jobs"; exit 1; }
  mkdir -p $Q $F/law/in $F/law/out
  local c
  while read -r c _ _; do
    [ -s $F3/law/out/$c.nul ] || { say "no $F3/law/out/$c.nul"; exit 1; }
    ln -sfn $PWD/$F3/law/out/$c.nul $F/law/in/$c.nul
  done < $F3/q/chunks
  cp $F3/q/jobs $F3/q/chunks $F3/q/nchunks $F3/q/parts $Q/
  say "plan: $(wc -l < $Q/jobs) jobs ($(grep -c " law$" $Q/jobs) with exlaw, $(grep -c " render$" $Q/jobs) render only, $(grep -c " link$" $Q/jobs) linked), $(wc -l < $Q/chunks) chunks (f3's exlaw outputs)"
}
# exlaw ---------------------------------------------------------------------------------------------------------
next_chunk() { local c
  while read -r c _ _; do
    [ -e $F/law/out/$c.nul ] && continue
    [ -d $Q/lclaim-$c ] && continue
    echo "$(size $F/law/in/$c.nul) $c"
  done < $Q/chunks | sort -rn | while read -r _ c; do mkdir $Q/lclaim-$c 2>/dev/null && { echo $c; break; }; done; }
law() { local c bad=0
  while :; do
    c=$(next_chunk); [ -n "$c" ] || break
    if BEND_SRC=$SRCS TIMEOUT=${TIMEOUT:-30} TRIES=${TRIES:-6} $CV exlaw $F/law/in/$c.nul $F/law/out/$c.nul > $F/law/out/$c.out 2>&1; then
      say "$c: $(tail -n 1 $F/law/out/$c.out)"
    else say "$c: exlaw FAILED ($F/law/out/$c.out): its units pass through without laws"; bad=$((bad + 1))
      cp $F/law/in/$c.nul $F/law/out/$c.nul.tmp && mv $F/law/out/$c.nul.tmp $F/law/out/$c.nul; touch $F/law/out/$c.failed; fi
  done
  say "law: none left, $bad failed"
  [ $bad = 0 ]; }
# render --------------------------------------------------------------------------------------------------------
# a job's results: f2's input, or (law) its chunks' outputs in order once all are DONE ("": not yet)
input() { local n=$1 k=$2 r=$3 kd=$4 m c
  [ "$kd" = law ] || { echo $r; return; }
  [ -s $F/law/$n.$k.nul ] && { echo $F/law/$n.$k.nul; return; }
  m=$(awk -v n=$n -v k=$k '$1 == n && $2 == k {print $3}' $Q/nchunks)
  for c in $(seq 0 $((m - 1))); do [ -e $F/law/out/$n.$k.$c.nul ] || return 0; done
  for c in $(seq 0 $((m - 1))); do cat $F/law/out/$n.$k.$c.nul; done > $F/law/$n.$k.nul.tmp && mv $F/law/$n.$k.nul.tmp $F/law/$n.$k.nul
  echo $F/law/$n.$k.nul; }
next_job() { local n k r b o kd
  while read -r n k r b o kd; do
    [ "$kd" = link ] && continue
    [ -e $Q/$n.$k/DONE ] && continue
    [ -d $Q/claim-$n.$k ] && continue
    echo "$(size $r) $n $k"
  done < $Q/jobs | sort -rn | while read -r _ n k; do
    read -r _ _ r _ _ kd < <(awk -v n=$n -v k=$k '$1 == n && $2 == k' $Q/jobs)
    [ "$kd" = law ] && [ -z "$(input $n $k $r $kd)" ] && continue
    mkdir $Q/claim-$n.$k 2>/dev/null && { echo "$n $k"; break; }
  done; }
pending() { local n k r b o kd
  while read -r n k r b o kd; do [ "$kd" = link ] || [ -e $Q/$n.$k/DONE ] || [ -d $Q/claim-$n.$k ] || echo $n.$k; done < $Q/jobs | wc -l; }
# chunks with no output yet (a law worker's, or none's yet)
inlaw() { local c
  while read -r c _ _; do [ -e $F/law/out/$c.nul ] || echo $c; done < $Q/chunks | wc -l; }
laws() { local o=$1 n=$2 k ok=1
  for k in 0 1; do SHARD=$k SHARDS=2 $L weights/code32k.bpe $o/part.nul > $o/laws.$k.log 2>&1 & done
  wait
  for k in 0 1; do tail -n 1 $o/laws.$k.log | grep -q ', 0 failed' || ok=; done
  [ -n "$ok" ] || { say "$n: laws FAILED ($o/laws.*.log)"; return 1; }
  touch $o/DONE; say "$n: DONE, $(pairs $o/part.nul) sessions"; }
work() { local bad=0 j n k r b o kd w e in
  while :; do
    j=$(next_job)
    if [ -z "$j" ]; then
      # chunks still being given laws: wait for them; else none left
      [ "$(pending)" -gt 0 ] && [ "$(inlaw)" -gt 0 ] && { sleep 60; continue; }
      break
    fi
    read -r n k <<< "$j"; read -r _ _ r b o kd < <(awk -v n=$n -v k=$k '$1 == n && $2 == k' $Q/jobs)
    in=$(input $n $k $r $kd)
    w=$Q/$n.$k; rm -rf $w; mkdir -p $w
    say "$n.$k: claimed ($in, $o)"
    e=(TRANSCRIPT_FORMAT=mugen MUGEN_ONLY=$o SIZES=$w/sizes.tsv)
    [ "$b" = - ] || e+=(BASE=$b)
    [ "$o" = form2-night ] && e+=(NIGHT=$F2/night/night.nul)
    if env "${e[@]}" $T weights/code32k.bpe $in $w/part.nul 2048 > $w/render.log 2>&1; then
      laws $w $n.$k || bad=$((bad + 1))
    else say "$n.$k: render FAILED ($w/render.log)"; bad=$((bad + 1)); fi
  done
  say "f3: none left, $bad failed"
  [ $bad = 0 ]; }
retry() { local c n k r b o kd x=0
  while read -r c _ _; do [ -e $F/law/out/$c.nul ] || { [ -d $Q/lclaim-$c ] && rmdir $Q/lclaim-$c && x=$((x + 1)); }; done < $Q/chunks
  while read -r n k r b o kd; do [ -e $Q/$n.$k/DONE ] || { [ -d $Q/claim-$n.$k ] && rmdir $Q/claim-$n.$k && x=$((x + 1)); }; done < $Q/jobs
  say "retry: $x claims dropped"
  law; work; }
# join ----------------------------------------------------------------------------------------------------------
shapes() { local i=$1 o=$2
  LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v m="$o.main" -v c="$o.chain" -v x="$o.fix" \
    'NR % 2 == 1 {s = $0; sub(/.*\//, "", s); f = (s ~ /^mugen-chain-/) ? c : (s ~ /^mugen-fix-/) ? x : m} {print > f}' "$i"
  touch "$o.main" "$o.chain" "$o.fix"; }
link() { local n=$1 d
  for d in mugen/$n mugen/chain/$n fix/$n; do
    [ -e $F2/$d ] || continue
    mkdir -p $(dirname $F/$d); ln -sfn $PWD/$F2/$d $F/$d
  done
  touch $F/$n.joined; say "$n: linked from $F2"; }
join() { local n p k ok t
  while read -r n p; do
    [ -e $F/$n.joined ] && continue
    if [ "$(kind $n)" = link ]; then link $n; continue; fi
    ok=1; for k in $(seq 0 $((p - 1))); do [ -e $Q/$n.$k/DONE ] || ok=; done
    [ -n "$ok" ] || { say "$n: not all of its $p parts DONE"; continue; }
    t=$F/j/$n; mkdir -p $F/j
    for k in $(seq 0 $((p - 1))); do cat $Q/$n.$k/part.nul; done > $t.nul
    for k in $(seq 0 $((p - 1))); do cat $Q/$n.$k/sizes.tsv; done > $t.sizes.tsv
    case $n in
      night) mkdir -p $F/fix/night; mv $t.nul $F/fix/night/transcripts.train.nul; mv $t.sizes.tsv $F/fix/night/sizes.tsv; touch $F/fix/night/DONE ;;
      *) shapes $t.nul $t
         mkdir -p $F/mugen/$n $F/mugen/chain/$n $F/fix/$n
         mv $t.main $F/mugen/$n/transcripts.train.nul; mv $t.chain $F/mugen/chain/$n/transcripts.train.nul; mv $t.fix $F/fix/$n/transcripts.train.nul
         mv $t.sizes.tsv $F/mugen/$n/sizes.tsv; rm -f $t.nul
         touch $F/mugen/$n/DONE $F/mugen/chain/$n/DONE $F/fix/$n/DONE ;;
    esac
    touch $F/$n.joined
    say "$n: joined"
  done < $Q/parts
  # the history streams' NAME.train.nul (f2's, linked) read the new NAME's stream: made again here
  local S
  for S in v2 collect5 own5; do
    [ -e $F/mugen/$S/DONE ] && [ -e $F2/mugen/hist-$S/DONE ] || continue
    [ -L $F/mugen/hist-$S ] && { rm $F/mugen/hist-$S; mkdir -p $F/mugen/hist-$S; cp -a $F2/mugen/hist-$S/transcripts.train.nul $F2/mugen/hist-$S/sizes.tsv $F2/mugen/hist-$S/DONE $F/mugen/hist-$S/ 2>/dev/null; }
    [ -s $F/mugen/hist-$S/$S.train.nul ] && continue
    $HD hist-drop $F/mugen/$S/transcripts.train.nul $F/mugen/hist-$S/$S.train.nul.tmp run/v6/hist-$S/units.kept > $F/mugen/hist-$S/drop.log 2>&1 \
      && mv $F/mugen/hist-$S/$S.train.nul.tmp $F/mugen/hist-$S/$S.train.nul && say "hist-$S: $(tail -n 3 $F/mugen/hist-$S/drop.log | tr '\n' ' ')" \
      || say "hist-$S: drop FAILED"
  done; }
case "${1:-}" in
  plan) plan ;;
  law) law ;;
  work) work ;;
  retry) retry ;;
  join) join ;;
  *) echo "usage: f4.sh plan|law|work|retry|join" >&2; exit 2 ;;
esac
