#!/usr/bin/env bash
# One exlaw chunk again, with the given bend-corpus-v2, into run/v9/f3/law/redo/ (2026-11-13: collect5.7.1
# hung 11 h in ex.sp, quadratic on a 2.7 MB `- expected`; the fix is ExlawText.bend's linear ex.sp).
# The chunk's settings are f3.sh's law worker's (BEND_SRC, TIMEOUT 30, TRIES 6). Nothing in law/out is
# touched: the swap is a separate, checked step.
#   bash run/v9/f3-redo-chunk.sh CV CHUNK
set -euo pipefail
CV=$1; C=$2
F=run/v9/f3
SRCS=run/v5/clean/src/own:run/v8/collect9/src/bend:run/v6/collect/src/bend:run/v8/collect/src/bend:run/v5/collect/src/bend
for d in run/code-sources*/curated run/code-sources*/own; do SRCS=$SRCS:$d; done
export BEND_NO_TELEMETRY=1
mkdir -p $F/law/redo
BEND_SRC=$SRCS TIMEOUT=30 TRIES=6 $CV exlaw $F/law/in/$C.nul $F/law/redo/$C.nul > $F/law/redo/$C.out 2>&1
echo "exit $?: $(tail -n 1 $F/law/redo/$C.out)"
