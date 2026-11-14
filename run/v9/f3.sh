#!/usr/bin/env bash
# Form 2's kinds, every Bend stream rendered again (2026-11-13; docs/form2/KINDS.md, bend/Transcript.bend "Form 2's
# kinds", bend/CorpusV2/Exlaw.bend).  The user, 11-13: the prose "In the request, and ana also writes it as a `#` comment
# above her function"; laws "Example laws from running the original, plus the file's own general laws when it has them";
# "Yes do start and keep going including making the full mix. Only wait for my approval to rent a box."
# From run/v9/f2's jobs (f2.sh plan: each stream's results, cut into parts of about 40 MB):
#   - a Bend job but agda2bend's (proofs), the history streams' and the nights': exlaw first, in chunks of CHUNK (300)
#     units (bend-corpus-v2 exlaw, BEND_SRC the trees the streams were checked in, a unit's the first whose copy of its
#     file holds its body), the chunks joined in order into the job's results;
#   - every Bend job (agda2bend's too) and the nights: bend-transcript as f2.sh's, bend-agent-laws 0 failed or not DONE;
#   - the other languages' and the history streams': f2's, linked (the kinds change none of their sessions).
# Layout as f2's under run/v9/f3 (mugen/NAME, mugen/chain/NAME, fix/NAME), so run6.sh mixes it with MGR=, CHR=, FXR=.
# A thin shim: the logic is bend-corpus-v2's and bend-transcript's.
#   f3.sh plan    the chunks and the jobs
#   f3.sh law     a worker: exlaw on the chunks not DONE and not claimed, largest first
#   f3.sh work    a worker: renders the jobs whose chunks are all DONE (no exlaw: at once), largest first
#   f3.sh retry   the claims not DONE dropped (law and render), then law and work again in this process
#   f3.sh join    each job's stream whose parts are all DONE, as f2.sh's join; the linked streams
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=run/v9/f3
F2=run/v9/f2
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
size() { stat -c %s "$1"; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
# a job's kind: law (exlaw, then render), render, link
kind() { case $1 in agda|haskell|lean|nix|hist-*) echo link ;; a2b*|night) echo render ;; *) echo law ;; esac; }
plan() {
  [ -s $F2/q/jobs ] || { say "no $F2/q/jobs"; exit 1; }
  mkdir -p $Q $F/law/in $F/law/out
  : > $Q/jobs.tmp; : > $Q/chunks.tmp
  local n k r b o c m
  while read -r n k r b o; do
    echo "$n $k $r $b $o $(kind $n)" >> $Q/jobs.tmp
    [ "$(kind $n)" = law ] || continue
    LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v c=$CHUNK -v o=$F/law/in/$n.$k 'NR % 2 == 1 {p = int((NR - 1) / 2 / c)} {print > (o "." p ".nul")}' $r
    m=$(ls $F/law/in/$n.$k.*.nul | wc -l)
    for c in $(seq 0 $((m - 1))); do echo "$n.$k.$c $n $k" >> $Q/chunks.tmp; done
    echo "$n $k $m" >> $Q/nchunks.tmp
  done < $F2/q/jobs
  cp $F2/q/parts $Q/parts
  mv $Q/jobs.tmp $Q/jobs; mv $Q/chunks.tmp $Q/chunks; mv $Q/nchunks.tmp $Q/nchunks
  say "plan: $(wc -l < $Q/jobs) jobs ($(grep -c ' law$' $Q/jobs) with exlaw, $(grep -c ' render$' $Q/jobs) render only, $(grep -c ' link$' $Q/jobs) linked), $(wc -l < $Q/chunks) chunks of $CHUNK units"
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
  *) echo "usage: f3.sh plan|law|work|retry|join" >&2; exit 2 ;;
esac
