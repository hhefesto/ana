#!/bin/sh
# A full emit of a cone with the dev binary, as the yonedaN runs: capped (10G, low CPU
# weight), the flake's bend as BEND, log beside it.  One emit at a time (the lock).
# usage: tools/a2b/emit.sh NAME [MODULE...]   (default MODULE: Categories.Yoneda)
#   -> run/a2b/NAME (src, raw, ledger.tsv) and run/a2b/NAME.log
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
n=$1; shift
[ $# -gt 0 ] || set -- Categories.Yoneda
cd "$R" || exit 1
[ -e "run/a2b/$n" ] && { echo "run/a2b/$n exists" >&2; exit 1; }
flock "$A2B_TMP/emit.lock" env BEND="$A2B_BEND" systemd-run --user --scope -q -p MemoryMax=10G -p MemorySwapMax=2G -p CPUWeight=30 \
  timeout 7200 run/a2b/bin/agda2bend-O0 emit run/a2b/export2 "run/a2b/$n" "$@" > "run/a2b/$n.log" 2>&1
echo "exit $?" >> "run/a2b/$n.log"
tail -2 "run/a2b/$n.log"
