#!/bin/sh
# Dev build of agda2bend: Bend -> C, then clang -O0 (about 2 min), under capped scopes.
# Writes run/a2b/bin/agda2bend-O0.  usage: tools/a2b/build.sh
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
. "$R/tools/a2b/env.sh"
cd "$R"
flock "$A2B_LOCK" systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=2G "$A2B_BEND" bend/Agda2Bend.bend -o run/a2b/bin/agda2bend.c
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=2G "$A2B_CC" -std=c11 -O0 run/a2b/bin/agda2bend.c -lpthread -lm -o run/a2b/bin/agda2bend-O0.new
mv run/a2b/bin/agda2bend-O0.new run/a2b/bin/agda2bend-O0
echo built
