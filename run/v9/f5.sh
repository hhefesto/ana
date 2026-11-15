#!/usr/bin/env bash
# R7's f5 (2026-11-15; docs/r7/PLAN.md).  f4's render again, with the authors' laws in the asks, then R7's fixed
# validation set split off.  The user, 11-15: "May I build the authors'-law ask in Transcript.bend now? Yes", and
# "Work on this" (the authors'-law request; f4.sh join, the mix, the filler, plan windows; changes 1, 7 and 8).
# f4's law jobs (its exlaw outputs law/N.K.nul; the authors' laws are all of their units', none of a2b's or the
# night's, so the render-only jobs' parts are f4's as they are) rendered by bend-transcript with
# AUTHLAW (bend-corpus-v2 authlaw ask: a unit's authors' laws, stated only, as the spec; Transcript.bend "The
# authors' laws in the asks"); f4's laws check on every part.  Then join, as f4.sh's, each stream split by
# bend-corpus-v2 valid split (CorpusV2/ValidText.bend: a held-out file's sessions into run/v9/f5/valid, in the
# same layout, the rest trained).  Nothing is rented here.  A thin shim: the logic is bend-corpus-v2's and
# bend-transcript's.
#   f5.sh ask     the authors' laws for the asks: run/v9/f5/authlaw.ask (from f4's authlaw.pass)
#   f5.sh plan    the jobs (f4's)
#   f5.sh work    a worker: renders the law jobs not DONE and not claimed, largest first
#   f5.sh retry   the claims not DONE dropped, then work again in this process
#   f5.sh join    each job's stream whose parts are all DONE (as f4.sh's), split into train and valid; the
#                 linked streams (f2's) split the same way
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=run/v9/f5
F4=run/v9/f4
F2=run/v9/f2
T=$F/gcroot/bin/bend-transcript
CV=$F/gcroot-cv2/bin/bend-corpus-v2
L=$F4/gcroot-laws/bin/bend-agent-laws
Q=$F/q
export VALID_K=${VALID_K:-2}
say() { echo "$(date '+%F %T') $*"; }
size() { stat -L -c %s "$1"; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
kind() { case $1 in agda|haskell|lean|nix|hist-*) echo link ;; a2b*|night) echo render ;; *) echo law ;; esac; }
ask() {
  [ -s $F4/authlaw/authlaw.pass ] || { say "no $F4/authlaw/authlaw.pass"; exit 1; }
  $CV authlaw ask $F4/authlaw/authlaw.pass $F/authlaw.ask.tmp > $F/authlaw.ask.log 2>&1 && mv $F/authlaw.ask.tmp $F/authlaw.ask \
    || { say "authlaw ask FAILED ($F/authlaw.ask.log)"; exit 1; }
  say "$(cat $F/authlaw.ask.log)"; }
plan() {
  [ -s $F4/q/jobs ] || { say "no $F4/q/jobs"; exit 1; }
  mkdir -p $Q; cp $F4/q/jobs $F4/q/parts $Q/
  say "plan: $(wc -l < $Q/jobs) jobs ($(grep -c " law$" $Q/jobs) rendered again, $(grep -c " render$" $Q/jobs) f4's parts, $(grep -c " link$" $Q/jobs) f2's streams)"; }
# render --------------------------------------------------------------------------------------------------------
# a law job's input: f4's exlaw output
input() { echo $F4/law/$1.$2.nul; }
# where a job's parts are: a law job's here, a render-only job's f4's
parts() { [ "$(kind $1)" = law ] && echo $Q || echo $F4/q; }
next_job() { local n k r b o kd
  while read -r n k r b o kd; do
    [ "$kd" = law ] || continue
    [ -e $Q/$n.$k/DONE ] && continue
    [ -d $Q/claim-$n.$k ] && continue
    echo "$(size $(input $n $k)) $n $k"
  done < $Q/jobs | sort -rn | while read -r _ n k; do mkdir $Q/claim-$n.$k 2>/dev/null && { echo "$n $k"; break; }; done; }
laws() { local o=$1 n=$2 k ok=1
  for k in 0 1; do SHARD=$k SHARDS=2 $L weights/code32k.bpe $o/part.nul > $o/laws.$k.log 2>&1 & done
  wait
  for k in 0 1; do tail -n 1 $o/laws.$k.log | grep -q ', 0 failed' || ok=; done
  [ -n "$ok" ] || { say "$n: laws FAILED ($o/laws.*.log)"; return 1; }
  touch $o/DONE; say "$n: DONE, $(pairs $o/part.nul) sessions"; }
work() { local bad=0 j n k r b o kd w e in
  [ -s $F/authlaw.ask ] || { say "no $F/authlaw.ask (f5.sh ask)"; exit 1; }
  while :; do
    j=$(next_job); [ -n "$j" ] || break
    read -r n k <<< "$j"; read -r _ _ r b o kd < <(awk -v n=$n -v k=$k '$1 == n && $2 == k' $Q/jobs)
    in=$(input $n $k)
    [ -s $in ] || { say "$n.$k: no input $in"; bad=$((bad + 1)); continue; }
    w=$Q/$n.$k; rm -rf $w; mkdir -p $w
    say "$n.$k: claimed ($in, $o)"
    e=(TRANSCRIPT_FORMAT=mugen MUGEN_ONLY=$o SIZES=$w/sizes.tsv AUTHLAW=$F/authlaw.ask)
    [ "$b" = - ] || e+=(BASE=$b)
    [ "$o" = form2-night ] && e+=(NIGHT=$F2/night/night.nul)
    if env "${e[@]}" $T weights/code32k.bpe $in $w/part.nul 2048 > $w/render.log 2>&1; then
      laws $w $n.$k || bad=$((bad + 1))
    else say "$n.$k: render FAILED ($w/render.log)"; bad=$((bad + 1)); fi
  done
  say "f5: none left, $bad failed"
  [ $bad = 0 ]; }
retry() { local n k r b o kd x=0
  while read -r n k r b o kd; do [ -e $Q/$n.$k/DONE ] || { [ -d $Q/claim-$n.$k ] && rmdir $Q/claim-$n.$k && x=$((x + 1)); }; done < $Q/jobs
  say "retry: $x claims dropped"
  work; }
# join ----------------------------------------------------------------------------------------------------------
# a stream into its place (D, from $F) for training and the same place under $F/valid
split() { local i=$1 d=$2
  mkdir -p $F/$d $F/valid/$d
  $CV valid split $i $F/$d/transcripts.train.nul $F/valid/$d/transcripts.train.nul >> $F/split.log 2>&1 || { say "$d: valid split FAILED ($F/split.log)"; return 1; }
  touch $F/$d/DONE $F/valid/$d/DONE; }
shapes() { local i=$1 o=$2
  LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v m="$o.main" -v c="$o.chain" -v x="$o.fix" \
    'NR % 2 == 1 {s = $0; sub(/.*\//, "", s); f = (s ~ /^mugen-chain-/) ? c : (s ~ /^mugen-fix-/) ? x : m} {print > f}' "$i"
  touch "$o.main" "$o.chain" "$o.fix"; }
link() { local n=$1 d ok=1
  for d in mugen/$n mugen/chain/$n fix/$n; do
    [ -e $F2/$d/transcripts.train.nul ] || continue
    split $F2/$d/transcripts.train.nul $d || ok=
  done
  [ -n "$ok" ] && { touch $F/$n.joined; say "$n: split from $F2"; }; }
join() { local n p k ok t pq
  mkdir -p $F/j
  while read -r n p; do
    [ -e $F/$n.joined ] && continue
    if [ "$(kind $n)" = link ]; then link $n; continue; fi
    pq=$(parts $n)
    ok=1; for k in $(seq 0 $((p - 1))); do [ -e $pq/$n.$k/DONE ] || ok=; done
    [ -n "$ok" ] || { say "$n: not all of its $p parts DONE ($pq)"; continue; }
    t=$F/j/$n
    for k in $(seq 0 $((p - 1))); do cat $pq/$n.$k/part.nul; done > $t.nul
    for k in $(seq 0 $((p - 1))); do cat $pq/$n.$k/sizes.tsv; done > $t.sizes.tsv
    case $n in
      night) split $t.nul fix/night || continue; mv $t.sizes.tsv $F/fix/night/sizes.tsv; rm -f $t.nul ;;
      *) shapes $t.nul $t
         split $t.main mugen/$n && split $t.chain mugen/chain/$n && split $t.fix fix/$n || continue
         mv $t.sizes.tsv $F/mugen/$n/sizes.tsv; rm -f $t.nul $t.main $t.chain $t.fix ;;
    esac
    touch $F/$n.joined
    say "$n: joined"
  done < $Q/parts
  say "join: $(ls $F/*.joined 2>/dev/null | wc -l) of $(wc -l < $Q/parts) streams; $(grep -c . $F/split.log 2>/dev/null) splits"; }
case ${1:-} in
  ask) ask ;;
  plan) plan ;;
  work) work ;;
  retry) retry ;;
  join) join ;;
  *) echo "usage: f5.sh ask|plan|work|retry|join" >&2; exit 2 ;;
esac
