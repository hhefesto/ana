#!/usr/bin/env bash
# Run 5's plan with the night's corpus (11-07).  The user, 11-06 23:40: "Work on augmenting the training corpus with extra
# bend code until tomorrow 9:30 am"; 11-07 00:05, to "Should I cut the corpus around 05:00 and build the new plan, so it's
# ready to rent at 09:30?": "Yes".  R5c's streams plus the GitHub shards made since (gh49 on, and delfos's gh14-19 if it
# answers at the cut) into run/v8/R5d, beside R5c, which stays as it is.
# Back from 09:30 by R5c's own hours (run/v8/mix3, run/v8/R5c.log): plan-windows 2 h 10 at 8 jobs (R5c: 4 h 12 at 4), the mix with
# its audit 2 h 16, the dry mix 1 h.  So:
#   02:00 the exports stop; 02:15 no new shard; 03:00 the shards stop (gh-cut.sh), and their units run 6 at a time;
#   the mugen shape and the chains as each stream ends; 04:00 the dry mix over what is through, for the share;
#   05:00 what is through goes in, and the rest waits for another plan.  The share misses the last hour's streams, at most a
#   point or so of repairs (24,000 sessions of 2,500,000, about 1%); the steps come from what the mix really holds.
# Then as run5c.sh: mix, filler, plan-windows.
#   run5d.sh            the driver (unit ana-run5d)
#   run5d.sh units      the new streams' units (unit ana-r5d-units)
#   run5d.sh shape      the mugen shape and the chains, in passes (unit ana-r5d-shape)
# The clock and the places can be set from the environment, as the rehearsal does (run/v8/run5d-sim.sh).
cd "${ANA:-/home/hhefesto/src/ana}" || exit 1
export BEND_NO_TELEMETRY=1
EXPSTOP=${EXPSTOP:-2026-11-07 02:00}; NONEW=${NONEW:-2026-11-07 02:15}; CUT=${CUT:-2026-11-07 03:00}
DRYAT=${DRYAT:-2026-11-07 04:00}; FREEZE=${FREEZE:-2026-11-07 05:00}
TICK=${TICK:-30}
A=${A2BDIR:-/home/hhefesto/src/agda2bend/run/a2b}
GH=${GHDIR:-/tmp/bx/gh}
L=run/v8/r5d.a2b; M=run/v6/mix; M4=run/v8/mix4; S=run/v8/R5dsrc; P=run/v8/R5d
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep $TICK; done; }
at() { local t; t=$(date -d "$1" +%s); while [ "$(date +%s)" -lt "$t" ]; do sleep $TICK; done; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
# (one by one: a name not loaded fails the whole command; 11-05)
stopu() { local u; for u in "$@"; do systemctl --user stop "$u" 2>/dev/null; done; }
worker() { systemctl --user reset-failed $1 2>/dev/null; systemd-run --user --unit=$1 --slice=ana-work.slice -p WorkingDirectory=$PWD -p MemoryMax=12G -p MemorySwapMax=1G -p OOMPolicy=continue -p StandardOutput=append:$PWD/run/v8/$1.log -p StandardError=append:$PWD/run/v8/$1.log --setenv=PATH="$PATH" /bin/sh -c "exec $2"; }
part() { systemctl --user reset-failed $1 2>/dev/null; systemd-run --user --unit=$1 --slice=ana-work.slice -p WorkingDirectory=$PWD -p OOMPolicy=continue -p StandardOutput=append:$PWD/run/v8/$1.log -p StandardError=append:$PWD/run/v8/$1.log --setenv=PATH="$PATH" --setenv=ANA="$PWD" --setenv=A2BDIR="$A" --setenv=TICK="$TICK" "$(command -v bash)" run/v8/run5d.sh $2; }
# the shards not in R5c, the biggest first (if the time runs out, the small ones are what is lost)
streams() { local d e
  for d in "$A"/corpus-gh[0-9]*; do
    [ -d "$d" ] || continue
    e=${d##*/corpus-}; case $e in *-*) continue ;; esac
    grep -qw "a2b$e" run/v8/r5c.a2b && continue
    [ -s "$d/ledger.tsv" ] || continue
    echo "$(wc -l < "$d/ledger.tsv") $e"
  done | sort -rn | cut -d' ' -f2; }
# R5c's streams and the new ones that have come through the units, the shape and the chains
through() { local k n
  tr -d '\n' < run/v8/r5c.a2b
  for k in $(streams); do n=a2b$k
    grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && [ -e run/v6/mugen/$n/DONE ] && [ -e run/v6/mugen/chain/$n/DONE ] && printf ' %s' $n
  done; echo; }

case "${1:-}" in
  units)
    # (6 at a time, as run5c.sh: nothing else is heavy by then)
    i=0
    for k in $(streams); do n=a2b$k
      grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
      while [ "$(jobs -rp | wc -l)" -ge 6 ]; do wait -n; done
      i=$((i + 1)); say "$k"
      ( CHECK_PROCS=4 CHECKD_N=2 CHECKD_PORT=$((47400 + 4 * i)) run/v5/clean/a2bsrc.sh $k >> run/v8/a2bsrc-$k.log 2>&1 \
          && echo "$(date '+%F %T') $n DONE" >> run/v8/a2bsrc15.log \
          || say "a2bsrc.sh $k FAILED, left out (run/v8/a2bsrc-$k.log)" ) &
    done
    wait
    touch run/v8/r5d.units.done; say "units: none left"
    exit 0 ;;
  shape)
    # (a stream that ends during a pass has the next; the last pass begins after the units have ended)
    while :; do
      last=; [ -e run/v8/r5d.units.done ] && last=1
      worker ana-mugen6q1 run/v5/clean/mugen6q.sh; worker ana-mugen6q2 run/v5/clean/mugen6q.sh; worker ana-mugen6q3 run/v5/clean/mugen6q.sh
      waitfor ana-mugen6q1 ana-mugen6q2 ana-mugen6q3
      run/v5/clean/mugen6q.sh move | grep -v 'not DONE'
      worker ana-chain1 run/v5/clean/chain6.sh; worker ana-chain2 run/v5/clean/chain6.sh
      waitfor ana-chain1 ana-chain2
      [ -n "$last" ] && break
      sleep $TICK
    done
    say "shape: none left"
    exit 0 ;;
esac

mkdir -p $M4 $S/bend
say "the clock: exports $EXPSTOP, new shards $NONEW, shards $CUT, dry mix $DRYAT, freeze $FREEZE"
[ -s run/v8/r5c.a2b ] || die "no run/v8/r5c.a2b"
at "$EXPSTOP"; stopu a2b-exp-gh; touch "$GH/export.ended"; say "exports stopped"
at "$NONEW"; stopu ana-ghsched2; say "no new shard"
at "$CUT"
if [ ! -e run/v8/r5d.cut ]; then
  # (gh-cut.sh stops the shards and, if delfos answers, brings over what its shards reached)
  bash run/v8/gh-cut.sh >> run/v8/gh-cut.log 2>&1 || say "gh-cut.sh: delfos's shards not here, going on (run/v8/gh-cut.log)"
  stopu 'a2b-gh[0-9]*' ana-ghsrc
  rm -rf run/v8/ghsrc.claim.*
  touch run/v8/r5d.cut
fi
say "the cut; new streams: $(streams | tr '\n' ' ')"
rm -f run/v8/r5d.units.done
part ana-r5d-units units; part ana-r5d-shape shape

at "$DRYAT"
through > $L.dry
say "dry mix over: $(cut -d' ' -f39- $L.dry)"
dryok=
if A2BLIST=$L.dry R5C=1 MG=1 FF=1 CH=1 run/v5/clean/mix6.sh $M4/dry dry > $M4/dry.log 2>&1; then dryok=1; else say "dry mix FAILED, again after the freeze (it costs an hour)"; fi

fz=$(date -d "$FREEZE" +%s)
while active ana-r5d-units ana-r5d-shape && [ "$(date +%s)" -lt "$fz" ]; do sleep $TICK; done
say "the freeze"
stopu ana-r5d-units ana-r5d-shape ana-mugen6q1 ana-mugen6q2 ana-mugen6q3
waitfor ana-chain1 ana-chain2
run/v5/clean/mugen6q.sh move | grep -v 'not DONE'
worker ana-chain1 run/v5/clean/chain6.sh; worker ana-chain2 run/v5/clean/chain6.sh
waitfor ana-chain1 ana-chain2
stopu ana-checkd-cap
through > $L
say "the plan's new streams: $(cut -d' ' -f39- $L)"
for k in $(streams); do n=a2b$k; grep -qw $n $L || say "$n: not through by the freeze, left out"; done

oth=0; for l in haskell agda lean nix; do [ -s $M/$l ] || die "no $M/$l"; oth=$((oth + $(count $M/$l))); done
if [ ! -e $M4/bend.done ]; then
  [ -n "$dryok" ] || { A2BLIST=$L R5C=1 MG=1 FF=1 CH=1 run/v5/clean/mix6.sh $M4/dry dry > $M4/dry.log 2>&1 || die "dry mix ($M4/dry.log)"; }
  fix=$(awk '$1 ~ /^out-(first|other|free-repair|derived)$/ {s+=$2} END {print s}' $M4/dry.stats)
  var=$(awk '$1 ~ /^out-(copy|repair)$/ {s+=$2} END {print s}' $M4/dry.stats)
  room=$((2500000 - oth))
  sh=$(awk -v f=$fix -v v=$var -v r=$room 'BEGIN {s=int(100*(r-f)/v); if (s>100) s=100; if (s<1) s=1; print s}')
  say "dry: Bend $fix sessions plus $var copies and repairs, room $room: share $sh"
  [ "$sh" -ge 100 ] && sh=
  A2BLIST=$L R5C=1 MG=1 FF=1 CH=1 SHARE=$sh run/v5/clean/mix6.sh $M4/bend > $M4/bend.log 2>&1 || die "mix6 ($M4/bend.log)"
  # (what killed R5b 48 minutes into plan-windows: mix-corpus refuses an id twice)
  n=$(LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==1' $M4/bend | LC_ALL=C sort -S 2G -T /tmp/bx | LC_ALL=C uniq -d | wc -l)
  say "ids twice: $n"; [ "$n" = 0 ] || die "$n ids twice in $M4/bend"
  touch $M4/bend.done
fi
bend=$(count $M4/bend); say "bend: $bend sessions"

# the filler, with the new streams' files (seconds since 11-05's fillunion)
S=$S A2BLIST=$L bash run/v8/fill5c.sh >> run/v8/fill5d.log 2>&1
[ -e $S/bend/files.done ] || die "no filler ($S/bend/files.done, run/v8/fill5d.log)"
fdocs=$(( $(tr -cd '\0' < $S/bend/files-hi.nul | wc -c) / 2 )); say "filler: $fdocs files"
# (75% as R5c, 11-06: its 64% failed 157 of 311 shards of R5b at the end of their pools)
docs=$(( (bend + oth) * 75 / 100 / 1000 )); K=$(( docs * 1000 / fdocs + 1 ))
ln -sfn $PWD/$M4/bend $S/bend/transcripts.train.nul
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
# (8 jobs have not run on this machine with this much in the plan: if the slice's cap takes a job, what is built stays, and fewer jobs go on)
ok=
for j in ${PWJOBS:-8} 5 4; do
  say "plan-windows: $j jobs"
  if env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=$j TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows $P fp100m 16 $specs >> $P.log 2>&1; then ok=1; break; fi
  say "plan-windows failed at $j jobs ($P.log)"; sleep $TICK
done
[ -n "$ok" ] || die "plan-windows ($P.log)"
head -n 1 $P/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: $P is ready"
