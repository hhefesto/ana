#!/bin/sh
# Probe a dropped item: the gated module OUT/src/MODPATH plus the named items from the
# pre-gate OUT/raw/MODPATH, checked together (5 min cap).  LINES_OUT lines of output (30).
# usage: tools/a2b/probe.sh OUT MODPATH AGDANAME...
R=$(cd "$(dirname "$0")/../.." && pwd)
out=$1; mp=$2; shift 2
p=$out/src/$(dirname $mp)/Probe_$(basename $mp)
cp $out/src/$mp $p
for n in "$@"; do
  awk -v n="# Agda: $n" '$0==n{on=1} on&&/^$/{exit} on{print}' $out/raw/$mp >> $p
  echo >> $p
done
timeout 300 "$R/run/gcroot-bend/bin/bend" $p --check-only 2>&1 | head -${LINES_OUT:-30}
rm -f $p
