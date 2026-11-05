#!/usr/bin/env bash
# Run 5's last plan (11-04; the user's goal: close all Bend generation, then only the GPU rent is missing): R5b's
# streams plus run 9's collection (col9) and 11-04's agda2bend emits (PLFA's cone, the standard library and
# agda-categories, agda-unimath with the assumptions as inputs).  run/v6/R5b stays as it is, the fallback.
# When the emits and col9 end: their units (a2bsrc.sh), the mugen shape (mugen6q.sh), the chains (chain6.sh), a dry mix
# for the share the hours take, Bend's mix (R5C=1 MG=1 FF=1 CH=1 mix6.sh into run/v8/mix3/bend), plan-windows into
# run/v8/R5c.  The other four languages' mixes and Bend's filler are R5b's.  Steps keep what they finished.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep 120; done; }
M=run/v6/mix; M3=run/v8/mix3; mkdir -p $M3
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
worker() { systemctl --user reset-failed $1 2>/dev/null; systemd-run --user --unit=$1 --slice=ana-work.slice -p WorkingDirectory=$PWD -p MemoryMax=6G -p MemorySwapMax=1G -p OOMPolicy=continue -p StandardOutput=append:$PWD/run/v8/$1.log -p StandardError=append:$PWD/run/v8/$1.log /bin/sh -c "exec $2"; }

say "waiting for the emits and col9"
waitfor a2b-um16 a2b-std15 a2b-plfa16 ana-col9f
A=/home/hhefesto/src/agda2bend/run/a2b
for c in corpus-um16 corpus-std15 corpus-plfa16; do
  [ -s $A/$c/ledger.tsv ] || die "no $A/$c/ledger.tsv"
  say "$c: $(cut -f1 $A/$c/ledger.tsv | sort -u | wc -l) modules, $(grep -c $'\tchecked\t' $A/$c/ledger.tsv) checked"
done
grep -q 'col9 DONE' run/v8/col9-finish.log || die "col9 is not DONE (run/v8/col9-finish.log)"

say "units"
for k in plfa16 std15 um16; do
  n=a2b$k; grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
  CHECK_PROCS=${CHECK_PROCS:-5} run/v5/clean/a2bsrc.sh $k >> run/v8/a2bsrc15.log 2>&1 || die "a2bsrc.sh $k (run/v8/a2bsrc15.log)"
done

say "the mugen shape"
waitfor ana-mugen6q1 ana-mugen6q2
worker ana-mugen6q1 run/v5/clean/mugen6q.sh; worker ana-mugen6q2 run/v5/clean/mugen6q.sh
waitfor ana-mugen6q1 ana-mugen6q2
run/v5/clean/mugen6q.sh move || die "move"
for s in a2bplfa16 a2bstd15 a2bum16 col9; do [ -e run/v6/mugen/$s/DONE ] || die "run/v6/mugen/$s not DONE"; done

say "the chains"
worker ana-chain1 run/v5/clean/chain6.sh; worker ana-chain2 run/v5/clean/chain6.sh
waitfor ana-chain1 ana-chain2
for s in a2bplfa16 a2bstd15 a2bum16 col9; do [ -e run/v6/mugen/chain/$s/DONE ] || die "run/v6/mugen/chain/$s not DONE"; done

waitfor ana-mix2
export CV=$PWD/run/v6/mugen/chain/gcroot-bend-corpus-v2/bin/bend-corpus-v2
oth=0; for l in haskell agda lean nix; do [ -s $M/$l ] || die "no $M/$l"; oth=$((oth + $(count $M/$l))); done
if [ ! -e $M3/bend.done ]; then
  R5C=1 MG=1 FF=1 CH=1 run/v5/clean/mix6.sh $M3/dry dry > $M3/dry.log 2>&1 || die "dry mix"
  fix=$(awk '$1 ~ /^out-(first|other|free-repair|derived)$/ {s+=$2} END {print s}' $M3/dry.stats)
  var=$(awk '$1 ~ /^out-(copy|repair)$/ {s+=$2} END {print s}' $M3/dry.stats)
  room=$((2500000 - oth))
  sh=$(awk -v f=$fix -v v=$var -v r=$room 'BEGIN {s=int(100*(r-f)/v); if (s>100) s=100; if (s<1) s=1; print s}')
  say "dry: Bend $fix sessions plus $var copies and repairs, room $room: share $sh"
  [ "$sh" -ge 100 ] && sh=
  R5C=1 MG=1 FF=1 CH=1 SHARE=$sh run/v5/clean/mix6.sh $M3/bend > $M3/bend.log 2>&1 || die "mix6"
  touch $M3/bend.done
fi
bend=$(count $M3/bend); say "bend: $bend sessions"

# (two plan-windows at once would pass the memory)
waitfor ana-run5b
[ -e run/v6/R5src/bend/files.done ] || die "no filler (run/v6/R5src/bend/files.done)"
S=run/v8/R5csrc; mkdir -p $S/bend
docs=$(( (bend + oth) * 55 / 100 / 1000 )); K=$(( docs * 1000 / 43000 + 1 ))
ln -sfn $PWD/run/v6/R5src/bend/files-hi.nul $S/bend/files-hi.nul; : > $S/bend/files-lo.nul; touch $S/bend/files.done
ln -sfn $PWD/$M3/bend $S/bend/transcripts.train.nul
ln -sfn $PWD/run/v2/results/bend.holdout.nul $S/bend/results.holdout.nul
for l in haskell agda lean nix; do mkdir -p $S/$l
  ln -sfn $PWD/$M/$l $S/$l/transcripts.train.nul
  ln -sfn $PWD/run/v2/transcripts/$l/files-hi.nul $S/$l/files-hi.nul
  ln -sfn $PWD/run/v2/transcripts/$l/files-lo.nul $S/$l/files-lo.nul
  ln -sfn $PWD/run/v2/results/$l.holdout.nul $S/$l/results.holdout.nul
done
per() { awk -v n=$1 -v t=$((bend + oth)) 'BEGIN {p=int(200*n/t+0.5); if (p<1) p=1; print p}'; }
specs="bend:$(per $bend)"; for l in haskell lean agda nix; do specs="$specs $l:$(per $(count $M/$l))"; done
say "plan-windows $specs"
env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=${PWJOBS:-4} TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows run/v8/R5c fp100m 16 $specs > run/v8/R5c.log 2>&1 || die "plan-windows (run/v8/R5c.log)"
head -1 run/v8/R5c/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: run/v8/R5c is ready"
