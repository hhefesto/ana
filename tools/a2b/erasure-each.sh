#!/bin/sh
# Erasure sidecars into run/a2b/export2, one module per process (ops; like export-each.sh).
# usage: tools/a2b/erasure-each.sh N LIST   (worker N, its own project dir and stub module ErasureStubN)
# Each process imports one module M, compiles M's whole closure (agda-export
# --export-erasure-only) and writes every sidecar of the closure that is missing; a module
# whose sidecar exists is skipped.  Capped at 14G, 20 minutes, a 12g heap.
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
N=$1; LIST=$(realpath "$2")
X=$R/run/a2b/gcroot-agda-export/bin/agda-export
OUT=$R/run/a2b/export2
P=$A2B_TMP/erasure-proj$N
L=$A2B_TMP/erasure-run/logs
mkdir -p "$P" "$L"
printf 'name: erasure-proj%s\ndepend: standard-library agda-categories\ninclude: .\n' "$N" > "$P/erasure-proj$N.agda-lib"
cd "$P" || exit 1
ts() { TZ=Etc/GMT+6 date '+%F %T UTC-6'; }
while read -r M; do
  [ -f "$OUT/$M.erasure.sexp" ] && continue
  printf 'module ErasureStub%s where\nimport %s\n' "$N" "$M" > "ErasureStub$N.agda"
  s=$(date +%s)
  systemd-run --user --scope -q -p MemoryMax=14G -p MemorySwapMax=2G timeout 1200 "$X" --export-dir="$OUT" --export-erasure-only --export-skip-existing "ErasureStub$N.agda" +RTS -M12g -RTS > "$L/$M.log" 2>&1
  r=$?
  rm -f "$OUT/ErasureStub$N.erasure.sexp"
  echo "[$(ts)] w$N $M exit $r $(( $(date +%s) - s ))s sidecars $(ls "$OUT" | grep -c '\.erasure\.sexp$') heap $(grep -c 'Heap exhausted' "$L/$M.log") failed $(grep -c 'FAILED' "$L/$M.log") $(grep -o 'modules compiled, [0-9]* sidecars written' "$L/$M.log")"
done < "$LIST"
echo "[$(ts)] w$N == done"
