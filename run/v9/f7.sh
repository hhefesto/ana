#!/usr/bin/env bash
# R7's change 6 (2026-11-15; docs/r7/PLAN.md; the user, 11-15: "Yes" to "prove sessions from the authors' laws" before
# R7): every authors' law that passed its repository's own check (run/v9/f4/authlaw/authlaw.pass) as a proposition
# unit, the law its statement and the repository's own proof its answer (bend-corpus-v2 authlaw prove,
# CorpusV2/AuthLaw.bend and AuthLawText.bend "The prove units"), a root at a time; then, as col10.sh: less every unit
# an earlier stream trained on or held out (decl-new), the cap, trim, the check and clean (deploy's stages, each
# root's units checked in that root, HOLDOUT_PCT=0: R7's fixed validation set is split off by file in the join);
# then f6.sh's render in the mugen shape, bend-agent-laws and the join (EXLAW=0 AUTHLAW=0: the law is the statement
# already) into run/v9/f5's layout (mugen/prove, mugen/chain/prove, fix/prove, valid/...), so run7.sh's mix takes it
# (EXTRA run/v9/transcripts-prove/...).  Nothing is rented.  A thin shim: the logic is Bend's.
#   f7.sh       all of it (a step whose output exists is skipped)
#   PP (3): roots walked at once; CP (6): check processes; MAXMS (20000), TCAP (2): authlaw prove's
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 GIT_TERMINAL_PROMPT=0
ulimit -s unlimited
F=${F7:-run/v9/f7}; PASS=${PASS:-run/v9/f4/authlaw/authlaw.pass}
CV=$F/gcroot-cv2/bin/bend-corpus-v2
DN=run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2
TM=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
D=run/v5/gcroot-deploy-982e162/bin/deploy
B=$PWD/run/v5/gcroot-bend-2.0.39/bin/bend
T=run/v9/transcripts-prove
say() { echo "$(date '+%F %T') f7: $*"; }
die() { say "FAILED: $*"; exit 1; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
[ -x $CV ] || die "no $CV (nix build .#bend-corpus-v2 -o $F/gcroot-cv2)"
mkdir -p $F/r $T/bend
# the roots, in their order in PASS
[ -s $F/roots ] || LC_ALL=C gawk 'BEGIN{RS="\0"; FS="\036"} NR%2==0 && $2=="pass" && !($5 in s) {s[$5]=1; print $5}' $PASS > $F/roots
NR=$(wc -l < $F/roots); say "$NR roots"
# the units, PP roots at once
pv() { local k=$1 r=$2 o=$F/r/$1
  [ -e $o/prove.done ] && return
  mkdir -p $o
  $CV authlaw prove $PASS "$r" $o/units.all.nul > $o/prove.log 2>&1 && touch $o/prove.done || say "root $k: prove FAILED ($o/prove.log)"; }
export -f pv say; export F PASS CV MAXMS TCAP
nl -v0 -w1 -s' ' $F/roots | xargs -P ${PP:-3} -L1 bash -c 'pv $0 $1'
for k in $(seq 0 $((NR - 1))); do [ -e $F/r/$k/prove.done ] || die "root $k: no units"; say "root $k: $(cat $F/r/$k/prove.log)"; done
# a unit's root (the first that gave it), then all the roots' units as one stream
if [ ! -s $F/ids.tsv ]; then
  for k in $(seq 0 $((NR - 1))); do LC_ALL=C gawk -v RS='\0' -v k=$k 'NR % 2 == 1 {print $0 "\t" k}' $F/r/$k/units.all.nul; done \
    | LC_ALL=C gawk -F'\t' '!($1 in s) {s[$1]=1; print}' > $F/ids.tsv
  cat $(for k in $(seq 0 $((NR - 1))); do echo $F/r/$k/units.all.nul; done) > $T/bend/units.all.nul
fi
say "$(pairs $T/bend/units.all.nul) units"
# decl-new: as col10.sh's (seen: every Bend stream's trained results less agda2bend's, col6-col9's units after
# decl-new; held: every collection's vault and holdout, col10's too)
if [ ! -e $T/bend/units.decl.nul ]; then
  SEEN="seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul"
  for x in run/v[5-9]/transcripts-*/bend/results.train.nul; do
    case $x in */transcripts-a2b*|$T/*) continue ;; esac; SEEN="$SEEN seen=$x"; done
  for x in run/v6/transcripts-col6 run/v7/transcripts-col7 run/v8/transcripts-col8 run/v8/transcripts-col9 run/v9/transcripts-col10; do
    [ -s $x/bend/units.decl.nul ] && SEEN="$SEEN seen=$x/bend/units.decl.nul"; done
  HELD=
  for h in run/v6/transcripts-col6/held/v6-* run/v7/transcripts-col7/held/v7-* run/v8/transcripts-col8/held/v8-* run/v8/transcripts-col9/held/v9-* run/v9/transcripts-col10/held/v10-*; do
    [ -e $h/bend/units.nul ] && HELD="$HELD held=$h/bend/units.nul"; done
  for c in run/v6/collect run/v7/collect run/v8/collect run/v8/collect9 run/v9/collect10; do
    for h in vault holdout; do [ -s $c/bend/$h/bend.jsonl ] && HELD="$HELD held=$c/bend/$h/bend.jsonl"; done; done
  say "decl-new ($(echo $SEEN | wc -w) seen, $(echo $HELD | wc -w) held)"
  $DN decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) $HELD $SEEN > $T/decl.log 2>&1 || die "decl-new ($T/decl.log)"
fi
[ -e $T/bend/units.nul.full ] || $DN decl-new $T/bend/units.decl.nul $T/bend/units.nul.full cap=:64 > $T/cap.log 2>&1 || die "cap ($T/cap.log)"
[ -e $T/bend/units.nul ] || $TM trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || die "trim ($T/trim.log)"
say "after decl-new, the cap and trim: $(pairs $T/bend/units.nul) units"
# back into the roots, each checked and cleaned there
if [ ! -e $F/split.done ]; then
  for k in $(seq 0 $((NR - 1))); do mkdir -p $F/r/$k/bend; : > $F/r/$k/bend/units.nul; done
  LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v d=$F/r 'FNR == NR {split($0, l, "\n"); for (i in l) if (l[i] != "") {split(l[i], f, "\t"); k[f[1]] = f[2]}; next}
    FNR % 2 == 1 {o = d "/" k[$0] "/bend/units.nul"} {print > o}' $F/ids.tsv $T/bend/units.nul
  touch $F/split.done
fi
for k in $(seq 0 $((NR - 1))); do
  o=$F/r/$k; r=$(sed -n "$((k + 1))p" $F/roots)
  [ -s $o/bend/units.nul ] || { say "root $k: no units left"; continue; }
  [ -s $o/bend/results.train.nul ] && continue
  say "root $k: check $(pairs $o/bend/units.nul) units ($r)"
  E="OUT=$o BEND=$B BEND_SRC=$r HOLDOUT_PCT=0"
  env $E TIMEOUT=${TIMEOUT:-180} CHECK_PROCS=${CP:-6} CHECK_JOBS=1 UNIT_JOBS=4 $D transcripts check bend > $o/check.log 2>&1 || die "root $k: check ($o/check.log)"
  env $E $D transcripts clean bend > $o/clean.log 2>&1 || die "root $k: clean ($o/clean.log)"
  say "root $k: $(tr '\n' ' ' < $o/bend/results.train.nul.stats)"
done
cat $(for k in $(seq 0 $((NR - 1))); do [ -s $F/r/$k/bend/results.train.nul ] && echo $F/r/$k/bend/results.train.nul; done) > $T/bend/results.train.nul
say "checked and cleaned: $(pairs $T/bend/results.train.nul) units"
# the render, the laws and the join: f6.sh's
F6=$F/rd N=prove R=$T/bend/results.train.nul EXLAW=0 AUTHLAW=0 bash run/v9/f6.sh || die "f6.sh's render and join"
say "DONE"
