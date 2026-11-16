#!/usr/bin/env bash
# R7valid without the held-out sessions and files that have a copy in training under another name (2026-11-16,
# 04:50: 102 of 17,164 sessions, 9 of 400 filler files; run/v9/R7valid-drop.ids lists their ids, one a line).
# Held-out files are chosen by path (CorpusV2/ValidText.bend), so a renamed copy (a2bgh5 n2LTT_C/ for n2LTT/, a
# fork's references/ for tasks/) lands in training.  Only the validation side changes; training (R7) stays as it is.
# Runs after run7.sh says R7 is ready (r7drop-wait.sh starts it then; validation only, nothing deleted).  A thin shim: the drop is bend-corpus-v2's
# `valid drop` (CorpusV2/Valid.bend), the windows bend-plan-windows', the check validfixed's, as run7.sh and
# r7vf-wait.sh run them.  Nothing is deleted: the inputs move to R7vsrc.full/bend/, the old R7valid to R7valid.full
# (out of R7vsrc, so plan-windows sees only the kept ones).
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
die() { say "FAILED: $*"; exit 1; }
count() { tr -cd '\0' < "$1" | wc -c | awk '{print int($1/2)}'; }
# L, VS, VP and VFLOG can be set for a trial on copies (a sandbox under /tmp); the defaults are R7's.
L=${L:-run/v9/run7.log}; P=run/v9/R7; VS=${VS:-run/v9/R7vsrc}; VP=${VP:-run/v9/R7valid}; LIST=run/v9/R7valid-drop.ids
VFLOG=${VFLOG:-run/v9/vf/r7valid-drop.log}
CV=${CV:-$PWD/run/v9/gcroot-cv3/bin/bend-corpus-v2}
VF=run/v9/vf/validfixed
tools() { echo TOKENIZER=weights/code32k.bpe BEND_PREPARE=run/v6/gcroot-bend-prepare/bin/bend-prepare BEND_WINDOWS=run/v6/gcroot-bend-windows/bin/bend-windows BEND_PLAN_SEGMENT=run/v6/gcroot-bend-plan-segment/bin/bend-plan-segment BEND_MIX=run/v6/gcroot-bend-mix/bin/bend-mix; }
grep -q "end: $P is ready" $L 2>/dev/null || die "R7 is not ready yet ($L)"
[ -x "$CV" ] || die "no $CV"
[ -s $LIST ] || die "no $LIST"
[ -e $VP.full ] && die "$VP.full is there: the drop ran already"
[ -e $VS.full ] && die "$VS.full is there: the drop ran already"
mkdir -p $VS.full/bend
for f in transcripts.train.nul files-hi.nul; do
  [ -s $VS/bend/$f ] || die "no $VS/bend/$f"
  mv $VS/bend/$f $VS.full/bend/$f
  $CV valid drop $LIST $VS.full/bend/$f $VS/bend/$f || die "valid drop $f"
done
vn=$(count $VS/bend/transcripts.train.nul); vf=$(count $VS/bend/files-hi.nul)
vk=$(awk -v n=$vn -v f=$vf 'BEGIN {k=(f>0)?int(n/f)+2:1; print k}')
say "validation: $vn sessions, $vf held-out files (x$vk in its filler)"
# plan-windows keeps what exists (a rerun resumes), so the old R7valid must be out of the way, or its shard is kept.
if [ -e $VP ]; then mv $VP $VP.full || die "mv $VP $VP.full"; fi
[ -e $VP ] && die "$VP is still there"
if [ -e $VP.log ]; then mv $VP.log $VP.full.log || die "mv $VP.log"; fi
env FILLER_COPIES=bend:$vk OUT=$VS SHARD=$((vn + 1)) JOBS=1 $(tools) run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows $VP fp100m 16 bend:1 >> $VP.log 2>&1 || die "validation plan-windows ($VP.log)"
ls -la $VP/shard-0-fp100m.corpus || die "no $VP/shard-0-fp100m.corpus ($VP.log)"
case $VP in /*) VC=$VP/shard-0-fp100m.corpus ;; *) VC=$PWD/$VP/shard-0-fp100m.corpus ;; esac
VALID_CORPUS=$VC TOKENIZER_FILE=weights/code32k.bpe timeout 1800 $VF > $VFLOG 2>&1
grep -q 'fixed windows of' $VFLOG \
  && say "CPU: $(grep 'fixed windows of' $VFLOG | sed 's/^\[[^]]*\] //')" \
  || die "TrainDense does not read $VP on the CPU ($VFLOG)"
say "end: $VP without the copies, VALID_CORPUS=$VC; nothing rented (the user's approval first)"
