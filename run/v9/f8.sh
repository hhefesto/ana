#!/usr/bin/env bash
# R7's change 5 (2026-11-15; docs/r7/PLAN.md; the user, 11-15: "Yes" to building "a sorts-with-fuel kind" before R7;
# 11-13: merge sort and quicksort need not be kept out of the corpus).  bend-sorts (bend/Sorts.bend) writes NS small
# files, each a sort written out from nothing (merge sort by turns or by halves, quicksort, insertion sort; Nat, U32,
# a Card, a Task; either order), recursing on fuel where its parts are not structurally smaller, with laws on fixed
# inputs from a reference sort.  Then, as col10.sh: units, trim, the check and clean (deploy's stages, BEND_SRC the
# files' tree, HOLDOUT_PCT=0: R7's fixed validation set is split off by file in the join; no decl-new: the files are
# new, and a decl-new by name would drop every `merge`), then f6.sh's render in the mugen shape, bend-agent-laws and
# the join (EXLAW=0 AUTHLAW=0: the laws are in the files) into run/v9/f5's layout (mugen/sorts, mugen/chain/sorts,
# fix/sorts, valid/...), so run7.sh's mix takes it (EXTRA run/v9/transcripts-sorts/...).  Nothing is rented.
# A thin shim: the logic is Bend's.
#   f8.sh       all of it (a step whose output exists is skipped)
#   NS (512): files; F8 (run/v9/f8), T8 (run/v9/transcripts-sorts), F5OUT (run/v9/f5): where it goes; CP (6): check
#   processes; P (nproc): f6.sh's
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
F=${F8:-run/v9/f8}; T=${T8:-run/v9/transcripts-sorts}; NS=${NS:-512}
SO=$F/gcroot-sorts/bin/bend-sorts
TM=run/v5/gcroot-bend-corpus-v2-d976edf/bin/bend-corpus-v2
D=run/v5/gcroot-deploy-982e162/bin/deploy
B=$PWD/run/v5/gcroot-bend-2.0.39/bin/bend
say() { echo "$(date '+%F %T') f8: $*"; }
die() { say "FAILED: $*"; exit 1; }
pairs() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }
[ -x $SO ] || die "no $SO (nix build .#bend-sorts -o $F/gcroot-sorts)"
mkdir -p $F $T/bend/src/sorts/fuel
if [ ! -e $T/bend/files.done ]; then
  $SO $T/bend $NS > $F/sorts.log 2>&1 || die "bend-sorts ($F/sorts.log)"
  : > $T/bend/files-lo.nul; touch $T/bend/files.done
fi
say "$(pairs $T/bend/files-hi.nul) files ($(cat $F/sorts.log))"
E="OUT=$T BEND=$B BEND_SRC=$(realpath $T/bend/src) MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.nul.full ]; then
  env $E CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || die "units ($T/units.log)"
  mv $T/bend/units.nul $T/bend/units.nul.full
fi
[ -e $T/bend/units.nul ] || $TM trim-mutants $T/bend/units.nul.full $T/bend/units.nul 4 > $T/trim.log 2>&1 || die "trim ($T/trim.log)"
say "$(pairs $T/bend/units.nul) units"
if [ ! -s $T/bend/results.nul ]; then
  env $E TIMEOUT=${TIMEOUT:-180} CHECK_PROCS=${CP:-6} CHECK_JOBS=1 UNIT_JOBS=4 $D transcripts check bend > $T/check.log 2>&1 || die "check ($T/check.log)"
fi
say "check: $(tr '\n' ' ' < $T/bend/results.nul.stats)"
if [ ! -s $T/bend/results.train.nul ]; then
  env $E $D transcripts clean bend > $T/clean.log 2>&1 || die "clean ($T/clean.log)"
fi
say "clean: $(tr '\n' ' ' < $T/bend/results.train.nul.stats)"
# the render, the laws and the join: f6.sh's
F6=$F/rd N=sorts R=$T/bend/results.train.nul SRCS=$T/bend/src EXLAW=0 AUTHLAW=0 bash run/v9/f6.sh || die "f6.sh's render and join"
say "DONE"
