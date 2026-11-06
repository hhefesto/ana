#!/usr/bin/env bash
# The no-copies plan (11-04; the user, asked "a second plan with no copies, so you can choose on Friday": "yes").
# R5c's streams, every session once: run/v8/R5n beside run/v8/R5c.
# repair-mix ratio=1 cap=1: a unit with a first-time session needs no copy of it for its one repair, and a repair whose
# unit has none is dropped (derive=none).  The user's 4:1 then holds over each language, not over each unit:
# the share is set so that repairs (with the free ones: ana's own) are at most a quarter of the first-time sessions.
# Nix has no first-time shape and no copies: its mix stays.  The filler is R5c's (col9 and the emits' files in), read K times as the windows need
# (K from the sessions, as in every plan); it pads a window's end, it is not a session.
# When R5c's plan has ended (they use the same streams, and two plan-windows at once would pass the memory).
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep 120; done; }
stat() { awk -v k="$2" '$1==k {print $2; f=1} END {if (!f) print 0}' "$1"; }
# the percent of units that keep their repair: first-time / 4, less the free repairs, of the repairs at 100%
shareof() { awk -v f="$1" -v r="$2" -v x="$3" 'BEGIN {if (r<1) {print 100; exit} s=int(100*(f/4-x)/r); if (s>100) s=100; if (s<1) s=1; print s}'; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
export CV=$PWD/run/v6/mugen/chain/gcroot-bend-corpus-v2/bin/bend-corpus-v2
N=run/v8/mixn; M=run/v6/mix; mkdir -p $N

# (11-05: its mixes beside R5c's plan-windows, which holds to 5 jobs for them: one after the other R5n landed at about 18:00 on Friday.  R5c's mix
# ending means run/v8/r5c.a2b is settled; R5n's plan needs R5c's filler, not R5c's plan.)
say "waiting for R5c's mix"
while active ana-run5c && [ ! -e run/v8/mix3/bend.done ]; do sleep 120; done
[ -e run/v8/mix3/bend.done ] || die "R5c's mix did not end (run/v8/run5c.log)"

say "Bend"
if [ ! -e $N/bend.done ]; then
  R5C=1 MG=1 FF=1 CH=1 RATIO=1 CAP=1 DERIVE=none run/v5/clean/mix6.sh $N/bend-dry dry > $N/bend-dry.log 2>&1 || die "Bend dry mix ($N/bend-dry.log)"
  [ "$(stat $N/bend-dry.stats out-copy)" = 0 ] || die "copies in Bend's dry mix"
  f=$(stat $N/bend-dry.stats out-first); r=$(stat $N/bend-dry.stats out-repair); x=$(stat $N/bend-dry.stats out-free-repair)
  sh=$(shareof $f $r $x)
  say "bend dry: $f first-time, $r repairs, $x free: share $sh"
  R5C=1 MG=1 FF=1 CH=1 RATIO=1 CAP=1 DERIVE=none SHARE=$sh run/v5/clean/mix6.sh $N/bend > $N/bend.log 2>&1 || die "Bend mix ($N/bend.log)"
  [ "$(stat $N/bend.stats out-copy)" = 0 ] || die "copies in Bend's mix"
  # (what killed R5b 48 minutes into plan-windows: mix-corpus refuses an id twice)
  n=$(LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==1' $N/bend | LC_ALL=C sort -S 2G -T /tmp/bx | LC_ALL=C uniq -d | wc -l)
  say "ids twice: $n"; [ "$n" = 0 ] || die "$n ids twice in $N/bend"
  touch $N/bend.done
fi

for l in haskell agda lean; do
  i=run/v6/mugen/$l/transcripts.train.nul; [ $l = lean ] && i=run/v6/mugen/lean/statements.nul
  [ -e $N/$l.done ] && continue
  $CV repair-mix $N/$l-dry in=$i derive=none ratio=1 cap=1 dry > $N/$l-dry.log 2>&1 || die "$l dry mix ($N/$l-dry.log)"
  f=$(stat $N/$l-dry.stats out-first); r=$(stat $N/$l-dry.stats out-repair)
  sh=$(shareof $f $r 0)
  say "$l dry: $f first-time, $r repairs: share $sh"
  $CV repair-mix $N/$l in=$i derive=none ratio=1 cap=1 share=$sh > $N/$l.log 2>&1 || die "$l mix ($N/$l.log)"
  [ "$(stat $N/$l.stats out-copy)" = 0 ] || die "copies in $l's mix"
  touch $N/$l.done
done
ln -sfn $PWD/$M/nix $N/nix

say "waiting for R5c's plan"
waitfor ana-run5c ana-run5b ana-fill5c
bend=$(count $N/bend); oth=0
for l in haskell agda lean nix; do oth=$((oth + $(count $N/$l))); done
say "sessions: bend $bend, the other four $oth"

[ -e run/v8/R5csrc/bend/files.done ] || die "no filler (run/v8/R5csrc/bend/files.done)"
S=run/v8/R5nsrc; mkdir -p $S/bend
# (11-06: 75, it was 55: run5c.sh says why.)
docs=$(( (bend + oth) * 75 / 100 / 1000 )); K=$(( docs * 1000 / ($(tr -cd '\0' < run/v8/R5csrc/bend/files-hi.nul | wc -c) / 2) + 1 ))
ln -sfn $PWD/run/v8/R5csrc/bend/files-hi.nul $S/bend/files-hi.nul; : > $S/bend/files-lo.nul; touch $S/bend/files.done
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
# (11-05: as many shards at once as leave the guard's 8 G, at 1.8 G a job)
pwj() { awk '/^MemAvailable/ {j=int(($2/1048576-8)/1.8); print (j<4?4:(j>8?8:j))}' /proc/meminfo; }
env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=${PWJOBS:-$(pwj)} TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows run/v8/R5n fp100m 16 $specs > run/v8/R5n.log 2>&1 || die "plan-windows (run/v8/R5n.log)"
head -1 run/v8/R5n/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: run/v8/R5n is ready"
