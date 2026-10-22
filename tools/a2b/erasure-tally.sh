#!/bin/sh
# Tallies over the erasure sidecars in run/a2b/export2.  usage: tools/a2b/erasure-tally.sh
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R/run/a2b/export2" || exit 1
echo "sidecars: $(ls | grep -c '\.erasure\.sexp$')"
cat *.erasure.sexp | awk '
  /^\(erasure-module / {
    mods++
    for (f = 1; f <= NF; f++) {}
    match($0, /\(entries [0-9]+\)/); e += substr($0, RSTART+9, RLENGTH-10)
    match($0, /\(args [0-9]+\)/); a += substr($0, RSTART+6, RLENGTH-7)
    match($0, /\(erased [0-9]+\)/); er += substr($0, RSTART+8, RLENGTH-9)
    match($0, /\(unused [0-9]+\)/); un += substr($0, RSTART+8, RLENGTH-9)
    match($0, /\(failed [0-9]+\)/); fl += substr($0, RSTART+8, RLENGTH-9)
    next }
  { n++ }
  END { printf "modules %d entries %d (lines %d) args %d erased %d unused %d failed %d\n", mods, e, n, a, er, un, fl }'
