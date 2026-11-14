#!/usr/bin/env bash
# R6: R5g's plan with form 2's kinds (2026-11-13; docs/form2/KINDS.md).  The user, 11-13: "Yes do start and keep going
# including making the full mix. Only wait for my approval to rent a box."  As run/v9/run5g.sh (no copies, no 4:1:
# repair-mix ratio=0, cap=4 a unit; R5d's filler), with every Bend stream from run/v9/f3.sh (the kinds; exlaw's laws and
# law mutants), the other languages' mixes R5g's (run/v9/mixg: their sessions did not change).  Into run/v9/R6, beside
# R5g, which stays as it is.  Nothing is rented here.
#   run6.sh      the driver (unit ana-run6): f3.sh plan, LAWW law workers and RW render workers (systemd units
#                ana-f3-l1.., ana-f3-r1..), waits for them, retries, joins, mixes, plans
#   MIXONLY=1    the mixes only (run/v9/mixh/NAME and NAME.stats), then stop: no filler, no plan
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=run/v9/f3
export CV=$PWD/$F/gcroot-cv2/bin/bend-corpus-v2
CAP=${CAP:-4}
LAWW=${LAWW:-10}; RW=${RW:-6}
N=run/v9/mixh; G=run/v9/mixg; S=run/v9/R6src; P=run/v9/R6; L=run/v8/r5d.a2b
TICK=${TICK:-120}
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep $TICK; done; }
stat() { awk -v k="$2" '$1==k {print $2; f=1} END {if (!f) print 0}' "$1"; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
twice() { LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==1' "$1" | LC_ALL=C sort -S 2G -T /tmp/bx | LC_ALL=C uniq -d | wc -l; }
mkdir -p $N /tmp/bx
[ -x "$CV" ] || die "no $CV"
[ -s $L ] || die "no $L"

[ -s $F/q/jobs ] || bash run/v9/f3.sh plan || die "plan"
lu=(); ru=()
for i in $(seq 1 $LAWW); do lu+=(ana-f3-l$i); done
for i in $(seq 1 $RW); do ru+=(ana-f3-r$i); done
for u in "${lu[@]}"; do active $u || systemd-run --user -q --unit=$u -p MemoryMax=3G -p WorkingDirectory=$PWD bash run/v9/f3.sh law > /dev/null; done
for u in "${ru[@]}"; do active $u || systemd-run --user -q --unit=$u -p MemoryMax=8G -p WorkingDirectory=$PWD bash run/v9/f3.sh work > /dev/null; done
say "exlaw: ${#lu[@]} workers; renders: ${#ru[@]} workers (they take a job once its chunks are DONE)"
waitfor "${lu[@]}"
say "exlaw done: $(ls $F/law/out/*.nul 2>/dev/null | wc -l) chunks, $(ls $F/law/out/*.failed 2>/dev/null | wc -l) failed (passed through)"
waitfor "${ru[@]}"
bash run/v9/f3.sh retry || say "retry: some jobs failed again"
bash run/v9/f3.sh join
bad=$(awk '{print $1}' $F/q/parts | while read -r n; do [ -e $F/$n.joined ] || echo $n; done | tr '\n' ' ')
[ -z "$bad" ] || say "not joined, left out: $bad"
# exlaw's counts over every chunk
awk '{s[$1] += $2} END {for (k in s) print k, s[k]}' $F/law/out/*.nul.stats | sort > $F/law/stats.txt
say "exlaw: $(awk '$1=="units"{u=$2} $1=="laws"{l=$2} $1=="examples"{e=$2} $1=="file-laws"{f=$2} $1=="law-mutants"{m=$2} $1=="form-mutants"{x=$2} END {print u" units, "l" given laws ("e" examples, "f" file laws), "m" law mutants, "x" form mutants"}' $F/law/stats.txt)"

say "Bend"
if [ ! -e $N/bend.done ]; then
  MGR=$F/mugen CHR=$F/mugen/chain FXR=$F/fix A2BLIST=$L R5C=1 MG=1 FF=1 CH=1 FX=1 RATIO=0 CAP=$CAP DERIVE=none \
    run/v5/clean/mix6.sh $N/bend > $N/bend.log 2>&1 || die "Bend mix ($N/bend.log)"
  [ "$(stat $N/bend.stats out-copy)" = 0 ] || die "copies in Bend's mix"
  say "bend: $(stat $N/bend.stats out-first) first-time, $(stat $N/bend.stats out-repair) repairs, $(stat $N/bend.stats out-free-repair) free, $(stat $N/bend.stats out-other) other; $(stat $N/bend.stats drop-cap) over the cap $CAP"
  n=$(twice $N/bend); say "ids twice: $n"; [ "$n" = 0 ] || die "$n ids twice in $N/bend"
  touch $N/bend.done
fi
# the other four: R5g's mixes (their sessions are f2's)
for l in haskell agda lean nix; do
  [ -e $G/$l.done ] || die "no R5g mix for $l ($G/$l.done)"
  ln -sfn $PWD/$G/$l $N/$l; ln -sfn $PWD/$G/$l.stats $N/$l.stats; touch $N/$l.done
done

bend=$(count $N/bend); oth=0
for l in haskell agda lean nix; do oth=$((oth + $(count $N/$l))); done
say "sessions: bend $bend, the other four $oth"
[ -z "$MIXONLY" ] || { say "end: the mixes (MIXONLY)"; exit 0; }

[ -e run/v8/R5dsrc/bend/files.done ] || die "no filler (run/v8/R5dsrc/bend/files.done)"
mkdir -p $S/bend
# (75%, as R5c, R5d, R5f and R5g: the filler pads a window's end, it is not a session)
docs=$(( (bend + oth) * 75 / 100 / 1000 )); K=$(( docs * 1000 / ($(tr -cd '\0' < run/v8/R5dsrc/bend/files-hi.nul | wc -c) / 2) + 1 ))
ln -sfn $PWD/run/v8/R5dsrc/bend/files-hi.nul $S/bend/files-hi.nul; : > $S/bend/files-lo.nul; touch $S/bend/files.done
ln -sfn $PWD/$N/bend $S/bend/transcripts.train.nul
ln -sfn $PWD/run/v2/results/bend.holdout.nul $S/bend/results.holdout.nul
for l in haskell agda lean nix; do mkdir -p $S/$l
  ln -sfn $PWD/$N/$l $S/$l/transcripts.train.nul
  ln -sfn $PWD/run/v2/transcripts/$l/files-hi.nul $S/$l/files-hi.nul
  ln -sfn $PWD/run/v2/transcripts/$l/files-lo.nul $S/$l/files-lo.nul
  ln -sfn $PWD/run/v2/results/$l.holdout.nul $S/$l/results.holdout.nul
done
per() { awk -v n=$1 -v t=$((bend + oth)) 'BEGIN {p=int(200*n/t+0.5); if (p<1) p=1; print p}'; }
specs="bend:$(per $bend)"; for l in haskell lean agda nix; do specs="$specs $l:$(per $(count $N/$l))"; done
say "plan-windows $specs, filler $K times"
pwj() { awk '/^MemAvailable/ {j=int(($2/1048576-8)/1.8); print (j<4?4:(j>8?8:j))}' /proc/meminfo; }
ok=
for j in ${PWJOBS:-$(pwj)} 4 3; do
  say "plan-windows: $j jobs"
  if env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=$j TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows $P fp100m 16 $specs >> $P.log 2>&1; then ok=1; break; fi
  say "plan-windows failed at $j jobs ($P.log)"; sleep $TICK
done
[ -n "$ok" ] || die "plan-windows ($P.log)"
head -n 1 $P/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: $P is ready; nothing rented (the user's approval first)"
