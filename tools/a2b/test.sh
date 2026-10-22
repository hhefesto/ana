#!/bin/sh
# Dev build and run of bend/tests/agda2bend.bend (compiled: the interpreter's stack does not
# hold Level).  usage: tools/a2b/test.sh
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
cd "$R"
flock "$A2B_LOCK" systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=2G "$A2B_BEND" bend/tests/agda2bend.bend -o run/a2b/bin/tests.c
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=2G "$A2B_CC" -std=c11 -O0 run/a2b/bin/tests.c -lpthread -lm -o run/a2b/bin/tests-O0
cd bend/tests && systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=2G ../../run/a2b/bin/tests-O0
