#!/usr/bin/env bash
# UNWIRED 2026-10-14: run 3's S1 plan (done, run/v3/S1); a run's plan comes from its run config and Bend in Phase 4; kept for reference
exit 2
# combine3.sh (2026-10-07): run 3's S1 plan, run/v3/S1: every transcript window (run/v3/T,
# windows3.sh's: format 2's and the synthetic chains) and every steady raw slice
# (run/v3/R/1..n, raw3.sh's) in one mix, the raw share R / (T + R) in training windows
# (rounded up to 4 places) so both run out together, as run/v2/combine-all.sh did. Then
# S1's boundary: the segment start nearest FRACTION (0.65) of the plan's steps, in
# run/v3/S1/BOUNDARY (S1 runs with STEPS=BOUNDARY; tools/corpus-v2/s2.sh builds S2 from it).
set -euo pipefail
cd /home/hhefesto/src/formalTransformer
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] combine3: $*"; }
tp=run/v3/T/plan-fp100m-b16-windows.tsv
[ -s "$tp" ] || { log "no $tp"; exit 1; }
tw() { awk '$1 == "segment" { s += $6 } END { print s + 0 }' "$1"; }
t=$(tw "$tp"); r=0; rs=()
for d in $(ls -d run/v3/R/[0-9]* | sort -t/ -k4 -n); do
  p=$d/plan-fp100m-b16-s2000.tsv; [ -s "$p" ] || { log "no plan in $d; stopping before it"; break; }
  r=$((r + $(tw "$p"))); rs+=("$d")
done
share=$(awk -v r="$r" -v t="$t" 'BEGIN { s = r / (t + r); printf "%.4f", int(s * 10000 + 0.9999) / 10000 }')
log "transcript windows $t, raw windows $r over ${#rs[@]} slices: raw share $share"
nix run .#deploy -- corpus-v2 combine "$share" run/v3/S1 run/v3/T "${rs[@]}"
p=run/v3/S1/plan-fp100m-b16-windows.tsv
head -1 "$p" | cut -c1-200
total=$(head -1 "$p" | awk '{ print $3 }')
b=$(awk -v t="$total" -v f="${FRACTION:-0.65}" '$1 == "segment" { d = $9 - t * f; if (d < 0) d = -d
      if (!n || d < best) { best = d; b = $9; n = 1 } } END { print b }' "$p")
echo "$b" > run/v3/S1/BOUNDARY
log "S1: $total steps, boundary $b ($(awk -v b="$b" -v t="$total" 'BEGIN { printf "%.1f", 100 * b / t }')%), ~$(awk -v b="$b" 'BEGIN { printf "%.1f", b * 1.896 / 3600 }') h at run 2's 1.896 s/step; the whole plan ~$(awk -v t="$total" 'BEGIN { printf "%.1f", t * 1.896 / 3600 }') h"
log done
