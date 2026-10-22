#!/bin/sh
# Check one Bend file with the locked bend, under the lock.  usage: tools/a2b/chk.sh FILE [LINES]
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
f=$(realpath "$1")
cd "$R"
flock "$A2B_LOCK" systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=2G run/gcroot-bend/bin/bend "$f" --check-only 2>&1 | head -${2:-16}
