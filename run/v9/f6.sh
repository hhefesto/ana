#!/usr/bin/env bash
# R7's new code (2026-11-15; docs/r7/PLAN.md change 1): col10's checked units (run/v9/col10.sh) through what f3-f5
# did to the other streams, in one go: exlaw (f4's: the head's own data types and Base's Maybe), the authors' laws of
# col10's repositories (f4.sh authlaw's steps, its roots collect10's tree), the ask (f5.sh ask's), the render in the
# mugen shape with the laws in the asks (f5.sh work's), bend-agent-laws 0 failed, and the join split into train and
# R7's fixed validation set (f5.sh join's), into run/v9/f5's layout (mugen/col10, mugen/chain/col10, fix/col10,
# valid/...), so run7.sh's mix takes it (mix6.sh EXTRA).  Nothing is rented.  A thin shim: the logic is
# bend-corpus-v2's and bend-transcript's.
#   f6.sh          all of it (each step skipped when its output exists)
#   EXLAW=0, AUTHLAW=0  no exlaw (the units pass through) and no authors' laws: f7.sh's prove units, whose law is
#                  their statement already
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=${F6:-run/v9/f6}; F4=run/v9/f4; F5=${F5OUT:-run/v9/f5}; N=${N:-col10}
R=${R:-run/v9/transcripts-col10/bend/results.train.nul}
SRCS=${SRCS:-run/v9/collect10/src/bend}
T=run/v9/f5/gcroot/bin/bend-transcript
CV4=$F4/gcroot-cv2/bin/bend-corpus-v2
CV5=run/v9/f5/gcroot-cv2/bin/bend-corpus-v2
AL=$F4/gcroot-al/bin/bend-corpus-v2
L=$F4/gcroot-laws/bin/bend-agent-laws
B=$PWD/run/v5/gcroot-bend-2.0.39/bin/bend
P=${P:-$(nproc)}; CHUNK=${CHUNK:-300}; PART=${PART:-40000000}
export VALID_K=${VALID_K:-2}
say() { echo "$(date '+%F %T') f6: $*"; }
die() { say "FAILED: $*"; exit 1; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
[ -s $R ] || die "no $R (run/v9/col10.sh)"
mkdir -p $F/law/in $F/law/out $F/q $F/authlaw/m $F/authlaw/c
# the chunks: CHUNK units each (a unit is two NUL fields)
if [ ! -e $F/law/in.done ]; then
  LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v d=$F/law/in -v c=$CHUNK 'NR % 2 == 1 {k = int((NR - 1) / (2 * c))} {print > (d "/" sprintf("%04d", k) ".nul")}' $R
  touch $F/law/in.done; fi
say "$(pairs $R) units, $(ls $F/law/in/*.nul | wc -l) chunks"
# exlaw, P at a time (a failure passes its units through without laws, as f4's)
ex() { local c=$1 i=$F/law/in/$1.nul o=$F/law/out/$1.nul
  [ -e $o ] && return
  [ "${EXLAW:-1}" = 0 ] && { cp $i $o; return; }
  if BEND_SRC=$SRCS TIMEOUT=${TIMEOUT:-30} TRIES=${TRIES:-6} $CV4 exlaw $i $o.tmp > $F/law/out/$c.out 2>&1; then mv $o.tmp $o
  else say "$c: exlaw FAILED ($F/law/out/$c.out): its units pass through without laws"; cp $i $o; touch $F/law/out/$c.failed; fi; }
export -f ex say; export F SRCS CV4 TIMEOUT TRIES EXLAW
ls $F/law/in/*.nul | xargs -n1 basename | sed 's/\.nul$//' | xargs -P $P -I{} bash -c 'ex {}'
say "exlaw: $(ls $F/law/out/*.nul | wc -l) chunks, $(ls $F/law/out/*.failed 2>/dev/null | wc -l) failed"
# the authors' laws (f4.sh authlaw's steps, AD=run/v9/f6/authlaw, roots collect10's tree)
AD=$F/authlaw
if [ "${AUTHLAW:-1}" = 1 ] && [ ! -e $AD/authlaw.done ]; then
  export BEND=$B BEND_SRC=$PWD/$SRCS TIMEOUT=${ALTIMEOUT:-240} TOTAL_MAX=${TOTAL_MAX:-3000000}
  [ -e $AD/index.done ] || { $AL authlaw index $AD/index.nul > $AD/index.log 2>&1 && touch $AD/index.done || die "authlaw index ($AD/index.log)"; }
  say "authlaw index: $(tr '\n' ' ' < $AD/index.nul.stats)"
  ls $(cd $F && pwd)/law/in/*.nul | split -l 40 -d -a 3 - $AD/m/b
  for b in $AD/m/b[0-9][0-9][0-9]; do
    [ -e $b.done ] || { $AL authlaw match $AD/index.nul $b.nul $(cat $b) > $b.log 2>&1 && touch $b.done || die "authlaw match ($b.log)"; }; done
  W=${W:-$((4 * P))}
  [ -e $AD/plan.done ] || { $AL authlaw plan $W $AD/jobs $AD/m/b[0-9][0-9][0-9].nul > $AD/plan.log 2>&1 && touch $AD/plan.done || die "authlaw plan ($AD/plan.log)"; }
  chk() { local j=$1 c=$AD/c/c${1##*.}; [ -e $c.done ] && return; $AL authlaw check $j $c > $c.log 2>&1 && touch $c.done || say "authlaw check FAILED ($c.log)"; }
  export -f chk; export AD AL
  for k in $(seq 0 $((W - 1))); do echo $AD/jobs.$k; done | xargs -P $P -I{} bash -c 'chk {}'
  for k in $(seq 0 $((W - 1))); do [ -e $AD/c/c$k.done ] || die "authlaw check $k"; done
  for x in pass fail time files; do cat $(for k in $(seq 0 $((W - 1))); do echo $AD/c/c$k.$x; done) > $AD/authlaw.$x; done
  $AL authlaw stats $AD/authlaw.stats $(for k in $(seq 0 $((W - 1))); do echo $AD/c/c$k; done) > $AD/stats.log 2>&1 || die "authlaw stats"
  touch $AD/authlaw.done
fi
if [ "${AUTHLAW:-1}" = 1 ]; then
say "authlaw: $(tr '\n' ' ' < $AD/authlaw.stats)"
[ -s $F/authlaw.ask ] || { $CV5 authlaw ask $AD/authlaw.pass $F/authlaw.ask.tmp > $F/authlaw.ask.log 2>&1 && mv $F/authlaw.ask.tmp $F/authlaw.ask || die "authlaw ask ($F/authlaw.ask.log)"; }
say "ask: $(cat $F/authlaw.ask.log)"
fi
# BASE: `bend base` of the names the units use and do not define (f2's base.tsv, made here for col10)
[ -s $F/base.tsv ] || { $T base $R $F/base.tsv.tmp $B > $F/base.log 2>&1 && mv $F/base.tsv.tmp $F/base.tsv || die "base ($F/base.log)"; }
# the parts: the chunks' outputs in order, cut at about PART bytes
if [ ! -e $F/q/parts.done ]; then
  cat $(ls $F/law/out/*.nul | LC_ALL=C sort) | LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v d=$F/q -v m=$PART \
    'NR % 2 == 1 && s >= m {k++; s = 0} {s += length($0) + 1; print > (d "/" sprintf("p%03d", k) ".nul")}'
  touch $F/q/parts.done; fi
# the render and the laws, P/2 parts at a time (each runs two law shards)
rd() { local p=$1 w=$F/q/$1
  [ -e $w/DONE ] && return
  rm -rf $w; mkdir -p $w
  if env TRANSCRIPT_FORMAT=mugen MUGEN_ONLY=form2-all SIZES=$w/sizes.tsv $([ -s $F/authlaw.ask ] && echo AUTHLAW=$F/authlaw.ask) BASE=$F/base.tsv \
       $T weights/code32k.bpe $F/q/$p.nul $w/part.nul 2048 > $w/render.log 2>&1; then
    for k in 0 1; do SHARD=$k SHARDS=2 $L weights/code32k.bpe $w/part.nul > $w/laws.$k.log 2>&1 & done; wait
    for k in 0 1; do tail -n 1 $w/laws.$k.log | grep -q ', 0 failed' || { say "$p: laws FAILED ($w/laws.$k.log)"; return 1; }; done
    touch $w/DONE; say "$p: DONE, $(pairs $w/part.nul) sessions"
  else say "$p: render FAILED ($w/render.log)"; return 1; fi; }
export -f rd pairs; export T L
ls $F/q/p[0-9][0-9][0-9].nul | xargs -n1 basename | sed 's/\.nul$//' | xargs -P $(( P / 2 > 0 ? P / 2 : 1 )) -I{} bash -c 'rd {}'
for p in $(ls $F/q/p[0-9][0-9][0-9].nul | xargs -n1 basename | sed 's/\.nul$//'); do [ -e $F/q/$p/DONE ] || die "$p not DONE"; done
# the join, as f5.sh's: the shapes apart, each split into train (run/v9/f5/...) and valid (run/v9/f5/valid/...)
split1() { local i=$1 d=$2
  mkdir -p $F5/$d $F5/valid/$d
  $CV5 valid split $i $F5/$d/transcripts.train.nul $F5/valid/$d/transcripts.train.nul >> $F/split.log 2>&1 || die "$d: valid split ($F/split.log)"
  touch $F5/$d/DONE $F5/valid/$d/DONE; }
if [ ! -e $F/$N.joined ]; then
  t=$F/j; mkdir -p $F/j
  for p in $(ls $F/q/p[0-9][0-9][0-9].nul | LC_ALL=C sort | xargs -n1 basename | sed 's/\.nul$//'); do cat $F/q/$p/part.nul; done > $t.nul
  LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v m="$t.main" -v c="$t.chain" -v x="$t.fix" \
    'NR % 2 == 1 {s = $0; sub(/.*\//, "", s); f = (s ~ /^mugen-chain-/) ? c : (s ~ /^mugen-fix-/) ? x : m} {print > f}' $t.nul
  touch $t.main $t.chain $t.fix
  split1 $t.main mugen/$N; split1 $t.chain mugen/chain/$N; split1 $t.fix fix/$N
  rm -f $t.nul $t.main $t.chain $t.fix
  touch $F/$N.joined
fi
say "joined: $(pairs $F5/mugen/$N/transcripts.train.nul) main, $(pairs $F5/mugen/chain/$N/transcripts.train.nul) chains, $(pairs $F5/fix/$N/transcripts.train.nul) fixes trained; $(pairs $F5/valid/mugen/$N/transcripts.train.nul) main held out"
