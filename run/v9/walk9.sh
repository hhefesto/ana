#!/usr/bin/env bash
# R9's walks (2026-11-17; docs/r9/PLAN.md).  The user, 11-17: "Longer tasks within 2,048 tokens. For example,
# one session could fill several holes in the same file in turn, with the file carried along. That needs new
# data collected on olimpo."  bend-walk (bend/Walk.bend) on every Bend stream's checked units with their laws
# (f4's exlaw parts, and col10's, col10b's and col10c's from f6, f6b, f6c), each part with its stream's BASE,
# every check a new run of Bend 2.0.39 in the trees the streams were checked in.  Nothing is rented.  A thin
# shim: the logic is bend-walk's.
#   walk9.sh          the jobs (run/v9/walk9/jobs), then P workers (default 12) over them, a part each
#   walk9.sh stats    the parts' counts summed
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
ulimit -s unlimited
W=run/v9/walk9
G=$PWD/$W/gcroot-walk/bin/bend-walk
TOK=$PWD/weights/code32k.bpe
export BEND=$PWD/run/v5/gcroot-bend-2.0.39/bin/bend TIMEOUT=${TIMEOUT:-60} KMAX=${KMAX:-5}
P=${P:-12}
say() { echo "$(date '+%F %T') walk9: $*"; }
srcs() { local s o= SRCS=run/v5/clean/src/own:run/v8/collect9/src/bend:run/v6/collect/src/bend:run/v8/collect/src/bend:run/v5/collect/src/bend
  for d in run/code-sources*/curated run/code-sources*/own run/v9/collect10/src/bend run/v9/collect10b/src/bend run/v9/collect10c/src/bend; do
    [ -d $d ] && SRCS=$SRCS:$d; done
  for s in ${SRCS//:/ }; do o=$o${o:+:}$PWD/$s; done; echo "$o"; }
jobs() {  # TAG UNITS BASE, a line each
  awk '$6=="law" {print $1, $2, $4}' run/v9/f4/q/jobs | sort -u | while read -r n k b; do
    [ -s run/v9/f4/law/$n.$k.nul ] && echo "$n.$k run/v9/f4/law/$n.$k.nul $b"; done
  for f in f6:col10 f6b:col10b f6c:col10c; do
    for u in run/v9/${f%%:*}/law/out/*.nul; do echo "${f##*:}.$(basename $u .nul) $u run/v9/${f%%:*}/base.tsv"; done; done; }
one() { local tag=$1 u=$2 b=$3 o=$PWD/$W/parts/$1.nul
  [ -e $o.stats ] && return 0
  BEND_SRC=$(srcs) BASE=$PWD/$b $G $TOK $PWD/$u $o > $W/logs/$tag.out 2>&1 || say "$tag FAILED ($W/logs/$tag.out)"; }
case ${1:-run} in
  stats)
    cat $W/parts/*.nul.stats | awk -F'\t' '{s[$1]+=$2} END{for(k in s) print k"\t"s[k]}' | sort; exit 0 ;;
esac
mkdir -p $W/parts $W/logs
jobs > $W/jobs
say "$(wc -l < $W/jobs) parts, $P workers, $(srcs | tr ':' '\n' | wc -l) trees"
export -f one srcs say; export W G TOK
# the largest first
while read -r tag u b; do echo "$(stat -L -c %s $u) $tag $u $b"; done < $W/jobs | sort -rn | cut -d' ' -f2- \
  | xargs -P $P -L 1 bash -c 'one "$@"' _
n=$(ls $W/parts/*.nul.stats 2>/dev/null | wc -l)
say "done: $n of $(wc -l < $W/jobs) parts"
bash $0 stats
