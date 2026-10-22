#!/bin/sh
# Export agda-categories modules one per process into run/a2b/export2 (ops).  Reads lines
# "M" (export M if missing) or "rm M" (delete M's old export first, so the 2.1 exporter
# writes its data/record copies' clauses) on stdin.  Each process is capped at 14G and
# 20 minutes, so a giant module costs at most that; the stub imports one module at a time.
# usage: tools/a2b/export-each.sh < LIST
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
cd "$R/run/a2b/everything" || exit 1
X=$R/run/a2b/gcroot-agda-export/bin/agda-export
last=$A2B_TMP/export-each.last
ts() { TZ=Etc/GMT+6 date '+%F %T UTC-6'; }
while read -r a b; do
  if [ "$a" = rm ]; then M=$b; rm -f ../export2/$M.sexp; else M=$a; fi
  [ -f ../export2/$M.sexp ] && continue
  printf 'module Stub where\nimport %s\n' "$M" > Stub.agda
  s=$(date +%s)
  systemd-run --user --scope -q -p MemoryMax=14G -p MemorySwapMax=2G timeout 1200 $X --export-dir=../export2 --export-skip-existing Stub.agda +RTS -M12g -RTS > "$last" 2>&1
  r=$?
  rm -f ../export2/*.part ../export2/Stub.sexp
  echo "[$(ts)] $M exit $r $(( $(date +%s) - s ))s files $(ls ../export2 | wc -l) $(grep -c 'Heap exhausted\|rror' "$last") errs"
done
echo "[$(ts)] == done"
