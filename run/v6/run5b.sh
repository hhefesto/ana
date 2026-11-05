#!/usr/bin/env bash
# Run 5's plan again with the chains (docs/MUGEN-SHAPE.md "Chains", 11-04): when chain6.sh's streams are DONE, a
# dry mix for the share the hours take, Bend's mix with them, then plan-windows into run/v6/R5b.  run/v6/R5 stays as
# it is, the fallback; the other four languages' mixes and Bend's filler are R5's.  Steps keep what they finished.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep 120; done; }
export CV=$PWD/run/v6/mugen/chain/gcroot-bend-corpus-v2/bin/bend-corpus-v2
M=run/v6/mix; M2=run/v6/mix2; mkdir -p $M2
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
say "waiting for the chains"
waitfor ana-chain1 ana-chain2 ana-chain3 ana-chain4 ana-chain5 ana-chain6 ana-chain7 ana-chain8 ana-chainN
[ -e run/v6/mugen/chain/night/DONE ] || die "night not DONE"
grep -h 'FAILED' run/v6/mugen/chain/w*.log && die "a chain stream failed"
oth=0; for l in haskell agda lean nix; do [ -s $M/$l ] || die "no $M/$l"; oth=$((oth + $(count $M/$l))); done
# 11-04: the mix does not need the filler, so `run5b.sh mix` (unit ana-mix2) runs it beside the filler; bend.done says it ended well.
[ "${1:-}" = mix ] || waitfor ana-mix2
if [ ! -e $M2/bend.done ]; then
  MG=1 FF=1 CH=1 run/v5/clean/mix6.sh $M2/dry dry > $M2/dry.log 2>&1 || die "dry mix"
  fix=$(awk '$1 ~ /^out-(first|other|free-repair|derived)$/ {s+=$2} END {print s}' $M2/dry.stats)
  var=$(awk '$1 ~ /^out-(copy|repair)$/ {s+=$2} END {print s}' $M2/dry.stats)
  room=$((2500000 - oth))
  sh=$(awk -v f=$fix -v v=$var -v r=$room 'BEGIN {s=int(100*(r-f)/v); if (s>100) s=100; if (s<1) s=1; print s}')
  say "dry: Bend $fix sessions plus $var copies and repairs, room $room: share $sh"
  [ "$sh" -ge 100 ] && sh=
  MG=1 FF=1 CH=1 SHARE=$sh run/v5/clean/mix6.sh $M2/bend > $M2/bend.log 2>&1 || die "mix6"
  touch $M2/bend.done
fi
bend=$(count $M2/bend); say "bend: $bend sessions"
[ "${1:-}" = mix ] && { say "mix: end"; exit 0; }
# R5's plan first (its filler is ours; two plan-windows at once would pass the memory)
waitfor ana-r5own9
[ -e run/v6/R5src/bend/files.done ] || die "no filler (run/v6/R5src/bend/files.done)"
S=run/v6/R5bsrc; mkdir -p $S/bend
docs=$(( (bend + oth) * 55 / 100 / 1000 )); K=$(( docs * 1000 / 43000 + 1 ))
ln -sfn $PWD/run/v6/R5src/bend/files-hi.nul $S/bend/files-hi.nul; : > $S/bend/files-lo.nul; touch $S/bend/files.done
ln -sfn $PWD/$M2/bend $S/bend/transcripts.train.nul
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
# (11-05: as many shards at once as leave the guard's 8 G, at 1.8 G a job: 325 shards are 2 h at 8 and 4 at 4)
pwj() { awk '/^MemAvailable/ {j=int(($2/1048576-8)/1.8); print (j<4?4:(j>8?8:j))}' /proc/meminfo; }
env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=${PWJOBS:-$(pwj)} TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows run/v6/R5b fp100m 16 $specs > run/v6/R5b.log 2>&1 || die "plan-windows (run/v6/R5b.log)"
head -1 run/v6/R5b/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: run/v6/R5b is ready"
