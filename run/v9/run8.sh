#!/usr/bin/env bash
# R8's corpus (2026-11-17, docs/r8/PLAN.md): R7's (below) with the user, 11-17: "Do start the rebuild with your
# recommendations. Add the edgar code too. The filler should be De-LaTeX-ed."  Mix: col10c (El cubo de Edgar) in
# EXTRA, CAP 2; then (later stages) the R8 pass, the de-LaTeX-ed prose (run/v9/theory8), the packing order.
# Was: R7's corpus (2026-11-15; docs/r7/PLAN.md, pipeline steps 2-4).
# weights and work on these" (the eight changes); 11-15: "Work on this" (the authors'-law request, join, the mix, the
# filler, plan windows; changes 1, 7 and 8), "Keep them, as R6 did" (R5g's Haskell, Agda, Lean and Nix sessions),
# "Add mugen's transcripts to the corpus".  Renting waits for the user's approval: nothing is rented here.
# As run/v9/run6.sh, with:
#   - the Bend streams f5's (the authors' laws in the asks, a look before each retry; f5.sh), each split by file into
#     train and R7's fixed validation set (CorpusV2/Valid.bend); col10's new code when f6.sh has joined it; mugen's
#     own chats (run/v9/mlog, CorpusV2/MugenLog.bend), split the same way;
#   - the history streams' repairs (hist-drop) made again from f5's streams, as f4.sh's join;
#   - change 1: each Bend source file at most K (3) times in the filler (R6: 24), the file split as the sessions are
#     (a held-out file's text in no window), and change 7: the theory prose (run/v9/theory/filler.sh,
#     bend-theory-cut) as a language of its own in the filler, prose, with no sessions, its PER such that it and the
#     code run out of filler together;
#   - change 8: R7valid, the validation sessions as windows of their own (plan-windows on them, their held-out files
#     as the filler): run/v9/R7valid/shard-0-fp100m.corpus is the trainer's VALID_CORPUS.
# A thin shim: the logic is bend-corpus-v2's (repair-mix, valid split, hist-drop) and bend-plan-windows'.
#   run7.sh            wait for f5's workers, retry, join, then all of the above
#   MIXONLY=1          the mixes only, then stop
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
F=run/v9/f5; F2=run/v9/f2
export CV=$PWD/$F/gcroot-cv2/bin/bend-corpus-v2
HD=run/v5/gcroot-bend-corpus-v2-hd/bin/bend-corpus-v2
CAP=${CAP:-2}; K=${K:-3}
N=run/v9/mix8; G=run/v9/mixg; S=run/v9/R8src; P=run/v9/R8; VS=run/v9/R8vsrc; VP=run/v9/R8valid; L=run/v8/r5d.a2b
PROSE=run/v9/theory8/prose/files-hi.nul; ML=run/v9/mlog
TICK=${TICK:-120}
export VALID_K=${VALID_K:-2}
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
stat() { awk -v k="$2" '$1==k {print $2; f=1} END {if (!f) print 0}' "$1"; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
twice() { LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==1' "$1" | LC_ALL=C sort -S 2G -T /tmp/bx | LC_ALL=C uniq -d | wc -l; }
mkdir -p $N /tmp/bx
[ -x "$CV" ] || die "no $CV"
[ -s $L ] || die "no $L"

# f5: its workers, a retry, the join
while active $(systemctl --user list-units --plain --no-legend 'ana-f5-r*' | awk '{print $1}'); do sleep $TICK; done
bash run/v9/f5.sh retry || say "f5 retry: some jobs failed again"
bash run/v9/f5.sh join
bad=$(awk '{print $1}' $F/q/parts | while read -r n; do [ -e $F/$n.joined ] || echo $n; done | tr '\n' ' ')
[ -z "$bad" ] || say "f5: not joined, left out: $bad"
# the history streams' NAME.train.nul from f5's NAME (its train part), as f4.sh's join
for s in v2 collect5 own5; do
  [ -e $F/mugen/$s/DONE ] && [ -e $F/mugen/hist-$s/DONE ] || { say "hist-$s: no f5 stream"; continue; }
  [ -s $F/mugen/hist-$s/$s.train.nul ] && continue
  $HD hist-drop $F/mugen/$s/transcripts.train.nul $F/mugen/hist-$s/$s.train.nul.tmp run/v6/hist-$s/units.kept > $F/mugen/hist-$s/drop.log 2>&1 \
    && mv $F/mugen/hist-$s/$s.train.nul.tmp $F/mugen/hist-$s/$s.train.nul && say "hist-$s: $(tail -n 3 $F/mugen/hist-$s/drop.log | tr '\n' ' ')" \
    || die "hist-$s: drop ($F/mugen/hist-$s/drop.log)"
done
# mugen's own chats, split as the streams are; the user, 11-15: "secrets, emails and netsem out".  MugenLog.bend
# leaves out the private sessions; this looks again at what it kept, and if any line looks private (an email, a key,
# a token, netsem, a password) the chats are all left out of R7 and the lines counted, none shown.
MLOK=1
if [ -s $ML/mlog.nul ]; then
  n=$(tr '\0' '\n' < $ML/mlog.nul | grep -c -i -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|github_pat_|sk-[A-Za-z0-9]{20}|netsem|password|passwd|secret')
  [ "$n" = 0 ] && say "mlog: no line looks private" || { MLOK=; say "mlog: $n lines look private ($ML/mlog.nul): mugen's chats left out"; }
fi
if [ -n "$MLOK" ] && [ -s $ML/mlog.nul ] && [ ! -e $ML/split.done ]; then
  $CV valid split $ML/mlog.nul $ML/train.nul $ML/valid.nul > $ML/split.log 2>&1 && touch $ML/split.done || die "mlog split ($ML/split.log)"
fi
EXTRA=; [ -e run/v9/f6/col10.joined ] && EXTRA="run/v9/transcripts-col10/bend/transcripts.train.nul" || say "col10: not joined yet (run/v9/f6.sh): left out"
# run 10b: the 16 unlicensed repositories (the user, 11-15: "Include them"; run/v9/col10b.sh, f6.sh into run/v9/f6b)
[ -e run/v9/f6b/col10b.joined ] && EXTRA="$EXTRA run/v9/transcripts-col10b/bend/transcripts.train.nul" || say "col10b: not joined yet (run/v9/f6.sh N=col10b): left out"
# run 10c: El cubo de Edgar (the user, 11-16/11-17: "Add the edgar code too"; run/v9/col10c.sh, f6.sh into run/v9/f6c)
[ -e run/v9/f6c/col10c.joined ] && EXTRA="$EXTRA run/v9/transcripts-col10c/bend/transcripts.train.nul" || die "col10c: not joined (run/v9/col10c-f6.sh)"
[ -n "$MLOK" ] && [ -s $ML/train.nul ] && EXTRA="$EXTRA $PWD/$ML/train.nul"
# change 6, the authors' laws' prove units (run/v9/f7.sh), and change 5, the sorts with fuel (run/v9/f8.sh)
[ -e run/v9/f7/rd/prove.joined ] && EXTRA="$EXTRA run/v9/transcripts-prove/bend/transcripts.train.nul" || say "prove: not joined yet (run/v9/f7.sh): left out"
[ -e run/v9/f8/rd/sorts.joined ] && EXTRA="$EXTRA run/v9/transcripts-sorts/bend/transcripts.train.nul" || say "sorts: not joined yet (run/v9/f8.sh): left out"

say "Bend"
if [ ! -e $N/bend.done ]; then
  EXTRA="$EXTRA" MGR=$F/mugen CHR=$F/mugen/chain FXR=$F/fix A2BLIST=$L R5C=1 MG=1 FF=1 CH=1 FX=1 RATIO=0 CAP=$CAP DERIVE=none \
    run/v5/clean/mix6.sh $N/bend > $N/bend.log 2>&1 || die "Bend mix ($N/bend.log)"
  [ "$(stat $N/bend.stats out-copy)" = 0 ] || die "copies in Bend's mix"
  say "bend: $(stat $N/bend.stats out-first) first-time, $(stat $N/bend.stats out-repair) repairs, $(stat $N/bend.stats out-free-repair) free, $(stat $N/bend.stats out-other) other; $(stat $N/bend.stats drop-cap) over the cap $CAP"
  n=$(twice $N/bend); say "ids twice: $n"; [ "$n" = 0 ] || die "$n ids twice in $N/bend"
  touch $N/bend.done
fi
grep 'not there\|not in the mugen shape' $N/bend.log | head -20
# the other four: R5g's mixes, as R6's
for l in haskell agda lean nix; do
  [ -e $G/$l.done ] || die "no R5g mix for $l ($G/$l.done)"
  ln -sfn $PWD/$G/$l $N/$l; ln -sfn $PWD/$G/$l.stats $N/$l.stats; touch $N/$l.done
done
[ -z "$MIXONLY" ] || { say "end: the mixes (MIXONLY)"; exit 0; }
# R8's pass (bend/R8.bend; the user, 11-17: "Do start the rebuild with your recommendations"): each language's mix
# less its give-up endings, at most R8_CAP (3) sessions a declaration (its last place for a kind it has not had),
# into $N/LANG.r8
R8=run/v9/gcroot-r8/bin/bend-r8
[ -x $R8 ] || die "no $R8"
for l in bend haskell agda lean nix; do
  [ -e $N/$l.r8.done ] && continue
  R8_CAP=${R8_CAP:-3} $R8 $N/$l $N/$l.r8.tmp > $N/$l.r8.log 2>&1 && mv $N/$l.r8.tmp.stats $N/$l.r8.stats && mv $N/$l.r8.tmp $N/$l.r8 && touch $N/$l.r8.done || die "r8 $l ($N/$l.r8.log)"
  say "r8 $l: $(tr "\n" " " < $N/$l.r8.stats)"
done
# the private pairs out (the user, 11-15: "secrets, emails and netsem out"; 11-17's assessment found 10 of the
# user's own sessions holding an address or a key's comment): $N/LANG.r8p (run/v9/r8priv.sh, bend/NulFilter.bend)
bash run/v9/r8priv.sh
for l in bend haskell agda lean nix; do [ -e $N/$l.r8p.done ] || die "r8p $l ($N/$l.r8p.log)"; done
bend=$(count $N/bend.r8p); oth=0
for l in haskell agda lean nix; do oth=$((oth + $(count $N/$l.r8p))); done
say "sessions after R8's pass: bend $bend, the other four $oth"

# the filler: Bend's files split (change 8) and K times (change 1), the prose (change 7)
[ -e run/v8/R5dsrc/bend/files.done ] || die "no Bend filler (run/v8/R5dsrc/bend/files.done)"
[ -s $PROSE ] || die "no prose ($PROSE: run/v9/theory/filler.sh)"
mkdir -p $S/bend $S/prose $VS/bend
if [ ! -e $S/bend/files.done ]; then
  $CV valid split run/v8/R5dsrc/bend/files-hi.nul $S/bend/files-hi.nul $VS/bend/files-hi.nul > $S/bend/split.log 2>&1 || die "filler split ($S/bend/split.log)"
  : > $S/bend/files-lo.nul; touch $S/bend/files.done
fi
# (fcut, not cut: a function named cut took run8.sh's later `cut -c1-80`, 11-17)
# the packing's fix (the user, 11-17: "Fix"): every filler text cut into pieces of at most FILL_MAXB bytes (4096),
# the private ones out (bend/NulFilter.bend): best fit takes a piece, not a whole file, for a gap.  The whole
# texts stay as they were (Bend's: $S/bend/files-whole.nul)
NF=run/v9/gcroot-nf/bin/bend-nul-filter; MAXB=${FILL_MAXB:-4096}
[ -x $NF ] || die "no $NF"
fcut() { [ -e "$2.done" ] && return 0
  NF_MAXB=${3:-$MAXB} NF_PRIVATE=$HOME/.config/ana/private-needles $NF "$1" "$2.tmp" > "$2.log" 2>&1 && mv "$2.tmp.stats" "$2.stats" \
    && { [ ! -L "$2" ] || rm "$2"; } && mv "$2.tmp" "$2" && touch "$2.done" && say "cut $2: $(tr '\n' ' ' < "$2.stats")" || say "FAILED: cut $1 ($2.log)"; }
[ -e $S/bend/files-whole.nul ] || [ -L $S/bend/files-hi.nul ] || mv $S/bend/files-hi.nul $S/bend/files-whole.nul
ln -sfn $PWD/$N/bend.r8p $S/bend/transcripts.train.nul
ln -sfn $PWD/run/v2/results/bend.holdout.nul $S/bend/results.holdout.nul
fcut $S/bend/files-whole.nul $S/bend/files-hi.nul &
for l in haskell agda lean nix; do mkdir -p $S/$l
  ln -sfn $PWD/$N/$l.r8p $S/$l/transcripts.train.nul
  fcut run/v2/transcripts/$l/files-hi.nul $S/$l/files-hi.nul &
  fcut run/v2/transcripts/$l/files-lo.nul $S/$l/files-lo.nul &
  ln -sfn $PWD/run/v2/results/$l.holdout.nul $S/$l/results.holdout.nul
done
# the prose finer (PROSE_MAXB, 1024 bytes, about a mean gap): R8's first try gave it 11 of 212 files a round and 5% of
# shard 0's filler tokens; the user, 11-16: "fillers shouldn't be latex, it should be regular English prose"
fcut $PROSE $S/prose/files-hi.nul ${PROSE_MAXB:-1024} &
wait
for f in bend/files-hi haskell/files-hi haskell/files-lo agda/files-hi agda/files-lo lean/files-hi lean/files-lo nix/files-hi nix/files-lo prose/files-hi; do
  [ -e $S/$f.nul.done ] || die "filler cut $f ($S/$f.nul.log)"; done
# each filler list in the order of a hash of its ids (as the validation set's below): plan-windows gives shard k the
# k-th slice, and in file order shard 1's prose was all the Stacks project's, shard 7's all the 1lab's, the books
# of dl/books8 in a shard or two (11-17, R8's second try); the hash multiplies at each byte (48271, mod 2^31 - 1): the
# validation set's (31, mod 10^9 + 7) keeps ids that share a long prefix in their own order
shuf1() { [ -e "$1.shuf" ] && return 0
  LC_ALL=C gawk 'BEGIN {RS = "\0"; ORS = "\0"; for (i = 1; i < 256; i++) o[sprintf("%c", i)] = i}
      NR % 2 == 1 {id = $0; next}
      {n++; I[n] = id; X[n] = $0; h = 7; for (j = 1; j <= length(id); j++) h = ((h * 31 + o[substr(id, j, 1)]) * 48271) % 2147483647; H[n] = h * 1000000 + n % 1000000}
      END {PROCINFO["sorted_in"] = "@val_num_asc"; for (k in H) {print I[k]; print X[k]}}' "$1" > "$1.tmp" \
    && [ "$(count "$1.tmp")" = "$(count "$1")" ] && mv "$1.tmp" "$1" && touch "$1.shuf" && say "shuffled $1" || say "FAILED: shuffle $1"; }
for f in bend/files-hi haskell/files-hi haskell/files-lo agda/files-hi agda/files-lo lean/files-hi lean/files-lo nix/files-hi nix/files-lo prose/files-hi; do
  shuf1 $S/$f.nul & done
wait
for f in bend/files-hi haskell/files-hi haskell/files-lo agda/files-hi agda/files-lo lean/files-hi lean/files-lo nix/files-hi nix/files-lo prose/files-hi; do
  [ -e $S/$f.nul.shuf ] || die "filler shuffle $f"; done
: > $S/prose/files-lo.nul; : > $S/prose/transcripts.train.nul; : > $S/prose/results.holdout.nul
per() { awk -v n=$1 -v t=$((bend + oth)) 'BEGIN {p=int(200*n/t+0.5); if (p<1) p=1; print p}'; }
bf=$(count $S/bend/files-hi.nul); pf=$(count $S/prose/files-hi.nul); pb=$(per $bend)
code=$((bf * K)); for l in haskell agda lean nix; do code=$((code + $(count $S/$l/files-hi.nul) + $(count $S/$l/files-lo.nul))); done
# the prose's PER: the prose runs dry with the last code language (each language's files, Bend's K times, at its PER a
# round), so every slice of the filler has prose in it.  11-15 23:2x: at Bend's pace (dry with Bend's copies, PER ~787)
# the last ~30 slices are only Haskell's, Lean's and Nix's files, and bend-windows' best fit replayed on R6's real gaps
# (tools/fillsim/FillSim.hs, bytes per token measured with code32k.bpe) refused 1-2 shards there; spread over every
# round (PER ~53), none, also with 35% fewer tokens a file
pr=$(( (bf * K + pb - 1) / pb ))
for l in haskell lean agda nix; do
  lf=$(( $(count $S/$l/files-hi.nul) + $(count $S/$l/files-lo.nul) )); lp=$(per $(count $N/$l.r8p))
  [ $(( (lf + lp - 1) / lp )) -gt $pr ] && pr=$(( (lf + lp - 1) / lp ))
done
pp=$(( (pf + pr - 1) / pr ))
specs="bend:$pb"; for l in haskell lean agda nix; do specs="$specs $l:$(per $(count $N/$l.r8p))"; done; specs="$specs prose:$pp"
need=$(( (bend + oth) * 80 / 100 ))
say "filler: Bend $bf files x $K, the other four's and Bend's $code, prose $pf pieces; sessions $((bend + oth)) (R6's filler was 88% of its sessions: about $need wanted)"
[ $((code + pf)) -ge $need ] || say "WARNING: filler $((code + pf)) under $need: a shard may run out (plan-windows refuses it)"
say "plan-windows $specs, Bend's files $K times"
pwj() { awk '/^MemAvailable/ {j=int(($2/1048576-8)/1.8); print (j<4?4:(j>8?8:j))}' /proc/meminfo; }
tools() { echo TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v9/gcroot-r8-windows/bin/bend-windows WINDOW_FILL=${WINDOW_FILL:-950} BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix; }
ok=
for j in ${PWJOBS:-$(pwj)} 4 3; do
  say "plan-windows: $j jobs"
  if env FILLER_COPIES=bend:$K OUT=$S SHARD=8000 JOBS=$j $(tools) run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows $P fp100m 16 $specs >> $P.log 2>&1; then ok=1; break; fi
  say "plan-windows failed at $j jobs ($P.log)"; sleep $TICK
done
[ -n "$ok" ] || die "plan-windows ($P.log)"
head -n 1 $P/plan-fp100m-b16-windows.tsv | cut -c1-80

# change 8: the validation windows.  Every held-out Bend session (f5's valid/, mugen's), once each by id, as one
# language, in the order of a hash of its id (the trainer reads the first EVALS windows: every stream in them, not
# the first stream's); its filler the held-out files (copies are fine here: nothing trains on it)
if [ ! -e $VS/bend/transcripts.done ]; then
  { find $F/valid -name transcripts.train.nul | LC_ALL=C sort | xargs cat; [ -n "$MLOK" ] && [ -s $ML/valid.nul ] && cat $ML/valid.nul; } \
    | LC_ALL=C gawk 'BEGIN {RS = "\0"; ORS = "\0"; for (i = 1; i < 256; i++) o[sprintf("%c", i)] = i}
        NR % 2 == 1 {id = $0; next}
        !(id in seen) {seen[id]; n++; I[n] = id; X[n] = $0; h = 7; for (j = 1; j <= length(id); j++) h = (h * 31 + o[substr(id, j, 1)]) % 1000000007; H[n] = h * 100000 + n % 100000}
        END {PROCINFO["sorted_in"] = "@val_num_asc"; for (k in H) {print I[k]; print X[k]}}' > $VS/bend/transcripts.train.nul
  # R8's pass on them too: the give-up endings out, no cap (a fixed set)
  R8_CAP=1000000 $R8 $VS/bend/transcripts.train.nul $VS/bend/r8.nul > $VS/bend/r8.log 2>&1 && mv $VS/bend/r8.nul $VS/bend/transcripts.train.nul && mv $VS/bend/r8.nul.stats $VS/bend/r8.stats || die "r8 validation ($VS/bend/r8.log)"
  say "r8 validation: $(tr "\n" " " < $VS/bend/r8.stats)"
  # the private ones out, as the training sessions'
  NF_MAXB=0 NF_PRIVATE=$HOME/.config/ana/private-needles $NF $VS/bend/transcripts.train.nul $VS/bend/r8p.nul > $VS/bend/r8p.log 2>&1 \
    && mv $VS/bend/r8p.nul $VS/bend/transcripts.train.nul && mv $VS/bend/r8p.nul.stats $VS/bend/r8p.stats || die "r8p validation ($VS/bend/r8p.log)"
  say "r8p validation: $(tr "\n" " " < $VS/bend/r8p.stats)"
  : > $VS/bend/files-lo.nul; : > $VS/bend/results.holdout.nul; touch $VS/bend/files.done $VS/bend/transcripts.done
fi
# its filler cut too, as the training filler (the packing)
[ -e $VS/bend/files-whole.nul ] || [ -L $VS/bend/files-hi.nul ] || mv $VS/bend/files-hi.nul $VS/bend/files-whole.nul
fcut $VS/bend/files-whole.nul $VS/bend/files-hi.nul; [ -e $VS/bend/files-hi.nul.done ] || die "validation filler cut ($VS/bend/files-hi.nul.log)"
vn=$(count $VS/bend/transcripts.train.nul); vf=$(count $VS/bend/files-hi.nul)
vk=$(awk -v n=$vn -v f=$vf 'BEGIN {k=(f>0)?int(n/f)+2:1; print k}')
say "validation: $vn sessions, $vf held-out files (x$vk in its filler)"
env FILLER_COPIES=bend:$vk OUT=$VS SHARD=$((vn + 1)) JOBS=1 $(tools) run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows $VP fp100m 16 bend:1 >> $VP.log 2>&1 || die "validation plan-windows ($VP.log)"
ls -la $VP/shard-0-fp100m.corpus
say "end: $P is ready, VALID_CORPUS=$PWD/$VP/shard-0-fp100m.corpus; nothing rented (the user's approval first)"
