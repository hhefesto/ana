#!/usr/bin/env bash
# Run 5's last plan (11-04; the user's goal: close all Bend generation, then only the GPU rent is missing): R5b's
# streams plus run 9's collection (col9) and 11-04's agda2bend emits (PLFA's cone, the standard library and
# agda-categories, agda-unimath with the assumptions as inputs).  run/v6/R5b stays as it is, the fallback.
# When the emits and col9 end: their units (a2bsrc.sh), the mugen shape (mugen6q.sh), the chains (chain6.sh), a dry mix
# for the share the hours take, Bend's mix (R5C=1 MG=1 FF=1 CH=1 mix6.sh into run/v8/mix3/bend), Bend's filler with col9 and the emits' files
# (fill5c.sh), plan-windows into run/v8/R5c.  The other four languages' mixes are R5b's.  Steps keep what they finished.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
waitfor() { while active "$@"; do sleep 120; done; }
M=run/v6/mix; M3=run/v8/mix3; mkdir -p $M3
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
worker() { systemctl --user reset-failed $1 2>/dev/null; systemd-run --user --unit=$1 --slice=ana-work.slice -p WorkingDirectory=$PWD -p MemoryMax=12G -p MemorySwapMax=1G -p OOMPolicy=continue -p StandardOutput=append:$PWD/run/v8/$1.log -p StandardError=append:$PWD/run/v8/$1.log /bin/sh -c "exec $2"; }

say "waiting for the emits and col9"
A=/home/hhefesto/src/agda2bend/run/a2b
# The user, 11-05, of the assumptions run: "use it if it finishes by Thursday night with nothing lost and the gain holds
# in the corpus copy", else corpus-um16 as far as it got.  um21 is that run: um19's 107 assumed lemmas, and every definition
# the gate drops assumed from the module on (A2B_AUTOASSUME).  At the deadline an emit still going is stopped; a partial one
# is still its modules.  The other libraries' emits (11-05, the same binary; the user: "as most good bend code as you can"):
# the standard library with agda-categories and the rest of agdaPackages, PLFA, agda-algebras, agda2hs-base, agda-prelude, plutus-metatheory, Agda's own test suite, the standard library's README modules (hs23, pre23 add to hs21, pre21 what their fixes freed).
EMITS="std21 plfa22 aa21 hs21 pre21 pm21 hs23 pre23 at1 rd1 at2 fl1 tt1"  # (tt1: TypeTopology, GPL-3.0; the user, 11-05: "Yes" to the GPL and AGPL repositories, and any public code with no licence)
DL=$(date -d "${DEADLINE:-2026-11-05 21:00}" +%s)
# 11-05: the other GitHub repositories' shards (agda2bend tools/gh; ghsched.sh starts them while the emits run)
ghs() { (cd $A; ls -d corpus-gh[0-9]* 2>/dev/null | sed 's/corpus-//'); }
units() { local u e; for e in um21 $EMITS $(ghs); do u="$u a2b-$e"; done; echo $u; }
# (11-05: to the deadline itself, not until no emit runs here: at 02:48 that went on early.  The guard can stop an emit, and delfos's shards are not units here.)
while [ "$(date +%s)" -lt "$DL" ]; do sleep 120; done
# delfos's shards: fromd.sh stops them 20 minutes before the deadline and copies what they reached (half an hour more, then without what has not arrived)
while active ana-fromd && [ "$(date +%s)" -lt "$((DL + 1800))" ]; do sleep 60; done
[ -e run/v8/fromd.done ] && say "delfos's shards here: $(ghs | tr '\n' ' ')" || say "delfos's shards NOT all copied (run/v8/fromd.log), going on with: $(ghs | tr '\n' ' ')"
UM=um21; UMX=
# um21 has finished only if it reached its last module: a unit that is not active may have been stopped (the guard, a restart).  Not finished: um16 by the user's rule.
# What um21 reached, on top of um16 as one more stream (decl-new, after um16, keeps only the declarations um16 does not have), goes beyond that rule: only with the user's yes.
UM21_MODS=2934; um21m=$(cut -f1 $A/corpus-um21/ledger.tsv | sort -u | wc -l)
if active a2b-um21 || [ "$um21m" -lt "$UM21_MODS" ]; then
  UM=um16; [ -e run/v8/um21-partial.yes ] && UMX=um21
  say "um21 not finished by the deadline: $um21m of $UM21_MODS modules; partial stream: ${UMX:-no}"
fi
# (one by one: 11-05, a unit name that was not loaded failed the whole command, and um21, std21 ran on past the deadline.  Once only: a restart must not stop the GitHub shards that go on to GHCUT.)
[ -e run/v8/deadline.stopped ] || { for u in $(units); do systemctl --user stop $u 2>/dev/null; done; touch run/v8/deadline.stopped; }
if [ $UM = um21 ]; then
  lost=$(awk -F'\t' 'NR==FNR { a[$1"\t"$2]=$4; next } (($1"\t"$2) in a) && a[$1"\t"$2]=="checked" && $4!="checked" { n++ } END { print n+0 }' $A/corpus-um16/ledger.tsv $A/corpus-um21/ledger.tsv)
  # the corpus copies of the modules both reached, in defs
  defs() { (cd "$1/corpus" && find . -name '*.bend' | sort) | comm -12 - <(cd "$2/corpus" && find . -name '*.bend' | sort) | (cd "$1/corpus" && xargs cat) | grep -c '^def '; }
  d16=$(defs $A/corpus-um16 $A/corpus-um21); d21=$(defs $A/corpus-um21 $A/corpus-um16)
  say "um21 against um16, the modules both reached: $lost lost; corpus copies $d21 defs against $d16"
  # the user's rule: nothing lost, and the gain holds; else um16.  UM_FORCE=um21 or um16 overrides it.
  [ "$lost" = 0 ] && [ "$d21" -gt "$d16" ] || UM=um16
  [ -n "${UM_FORCE:-}" ] && UM=$UM_FORCE
fi
say "agda-unimath: $UM"
while active ana-col9f; do sleep 120; done
# (formal-ledger, the rest of Agda's repository: only if they were emitted)
E2=; for e in $EMITS $(ghs); do [ -s $A/corpus-$e/ledger.tsv ] && E2="$E2 $e"; done; EMITS="$E2 $UM $UMX"
A2BS="a2bplfa19"; for e in $EMITS; do A2BS="$A2BS a2b$e"; done
echo "$A2BS" > run/v8/r5c.a2b
for e in $EMITS; do c=corpus-$e
  [ -s $A/$c/ledger.tsv ] || die "no $A/$c/ledger.tsv"
  say "$c: $(cut -f1 $A/$c/ledger.tsv | sort -u | wc -l) modules, $(grep -c $'\tchecked\t' $A/$c/ledger.tsv) checked"
done
grep -q 'col9 DONE' run/v8/col9-finish.log || die "col9 is not DONE (run/v8/col9-finish.log)"

say "units"
# (run/v8/a2bseq.sh has taken the smaller emits as they ended)
waitfor ana-a2bseq ana-ghsrc ana-src-um16 ana-src-gh1 ana-srcd
# (11-05: um16 went through a2bsrc.sh early, its unit ana-src-um16, for the hour it saves here.  If um21 did win, decl-new must not take um16 for seen.)
if [ $UM = um21 ] && [ -e run/v6/transcripts-a2bum16 ]; then mv run/v6/transcripts-a2bum16 run/v6/notused-a2bum16; sed -i "/a2bum16 DONE/d" run/v8/a2bsrc15.log; fi
for k in $EMITS; do
  case $k in gh*) continue ;; esac
  n=a2b$k; grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
  CHECK_PROCS=${CHECK_PROCS:-10} run/v5/clean/a2bsrc.sh $k >> run/v8/a2bsrc15.log 2>&1 || die "a2bsrc.sh $k (run/v8/a2bsrc15.log)"
done
# (11-05 22:35: nulmix and split took about 11 hours off each plan, so the GitHub shards here and on delfos go on to GHCUT and what they reached by then goes in;
# each hour of a shard is about 3,400 checked definitions, against um21's 1,700.  gh-cut.sh stops them and brings delfos's over.)
GHCUT=$(date -d "${GHCUT:-2026-11-06 03:00}" +%s)
say "the GitHub shards go on to $(date -d @$GHCUT '+%F %T')"
while [ "$(date +%s)" -lt "$GHCUT" ]; do sleep 60; done
bash run/v8/gh-cut.sh >> run/v8/gh-cut.log 2>&1 || say "gh-cut.sh failed (run/v8/gh-cut.log), going on with what is here"
for e in $(ghs); do
  case " $EMITS " in *" $e "*) continue ;; esac
  [ -s $A/corpus-$e/ledger.tsv ] || continue
  say "corpus-$e: $(cut -f1 $A/corpus-$e/ledger.tsv | sort -u | wc -l) modules, $(grep -c $'\tchecked\t' $A/corpus-$e/ledger.tsv) checked (new since the deadline)"
  EMITS="$EMITS $e"; A2BS="$A2BS a2b$e"
done
echo "$A2BS" > run/v8/r5c.a2b
# The GitHub shards together, 6 at a time (they were 4; nothing else is heavy here by then): decl-new alone is 20 minutes a stream, whatever its size, and they have little to see in each other.
# (a shard of odd repositories is not worth stopping the night for)
i=0; for k in $EMITS; do
  case $k in gh*) ;; *) continue ;; esac
  n=a2b$k; grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
  while [ "$(jobs -rp | wc -l)" -ge 6 ]; do wait -n; done
  i=$((i + 1))
  ( CHECK_PROCS=4 CHECKD_N=2 CHECKD_PORT=$((47400 + 4 * i)) run/v5/clean/a2bsrc.sh $k >> run/v8/a2bsrc-$k.log 2>&1 && echo "$(date '+%F %T') $n DONE" >> run/v8/a2bsrc15.log ) &
done
wait
for k in $EMITS; do
  case $k in gh*) ;; *) continue ;; esac
  n=a2b$k; grep -q "$n DONE" run/v8/a2bsrc15.log 2>/dev/null && continue
  say "a2bsrc.sh $k FAILED, left out"; A2BS=${A2BS/ $n/}; echo "$A2BS" > run/v8/r5c.a2b
done

say "the filler, beside what follows"
[ -e run/v8/R5csrc/bend/files.done ] || { active ana-fill5c || { systemctl --user reset-failed ana-fill5c 2>/dev/null; systemd-run --user --unit=ana-fill5c --collect --same-dir -p StandardOutput=append:$PWD/run/v8/fill5c.log -p StandardError=append:$PWD/run/v8/fill5c.log bash run/v8/fill5c.sh; }; }

say "the mugen shape"
waitfor ana-mugen6q1 ana-mugen6q2
worker ana-mugen6q1 run/v5/clean/mugen6q.sh; worker ana-mugen6q2 run/v5/clean/mugen6q.sh
waitfor ana-mugen6q1 ana-mugen6q2
run/v5/clean/mugen6q.sh move || die "move"
# (a shard with nothing to render has no stream; it is left out, as a shard whose units failed)
for s in $A2BS col9; do [ -e run/v6/mugen/$s/DONE ] && continue
  case $s in a2bgh*) say "$s: no mugen stream, left out"; A2BS=${A2BS/ $s/}; echo "$A2BS" > run/v8/r5c.a2b ;; *) die "run/v6/mugen/$s not DONE" ;; esac
done

say "the chains"
worker ana-chain1 run/v5/clean/chain6.sh; worker ana-chain2 run/v5/clean/chain6.sh
waitfor ana-chain1 ana-chain2
for s in $A2BS col9; do [ -e run/v6/mugen/chain/$s/DONE ] && continue
  case $s in a2bgh*) say "$s: no chains, left out"; A2BS=${A2BS/ $s/}; echo "$A2BS" > run/v8/r5c.a2b ;; *) die "run/v6/mugen/chain/$s not DONE" ;; esac
done

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
  # (what killed R5b 48 minutes into plan-windows: mix-corpus refuses an id twice)
  n=$(LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==1' $M3/bend | LC_ALL=C sort -S 2G -T /tmp/bx | LC_ALL=C uniq -d | wc -l)
  say "ids twice: $n"; [ "$n" = 0 ] || die "$n ids twice in $M3/bend"
  touch $M3/bend.done
fi
bend=$(count $M3/bend); say "bend: $bend sessions"

# (two plan-windows at once would pass the memory)
waitfor ana-run5b
# R5c's own filler, with col9 and the new emits' files (the user, 11-05; fill5c.sh, started after the units, beside the mix)
waitfor ana-fill5c
S=run/v8/R5csrc
[ -e $S/bend/files.done ] || die "no filler ($S/bend/files.done, $S/filler.log)"
fdocs=$(( $(tr -cd '\0' < $S/bend/files-hi.nul | wc -c) / 2 )); say "filler: $fdocs files"
docs=$(( (bend + oth) * 55 / 100 / 1000 )); K=$(( docs * 1000 / fdocs + 1 ))
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
# (11-05: 325 shards are 2 h at 8 jobs and 4 at 4; at 1.8 G a job, 5 leave room for R5n's mix beside it, 8 G at its peak, and the guard's 8 G)
pwj() { awk '/^MemAvailable/ {j=int(($2/1048576-16)/1.8); print (j<4?4:(j>5?5:j))}' /proc/meminfo; }
env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=${PWJOBS:-$(pwj)} TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows run/v8/R5c fp100m 16 $specs > run/v8/R5c.log 2>&1 || die "plan-windows (run/v8/R5c.log)"
head -1 run/v8/R5c/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: run/v8/R5c is ready"
