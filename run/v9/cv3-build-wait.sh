#!/usr/bin/env bash
# The nix build of bend-corpus-v2 at 33a5ed8 (its `valid drop`, for r7valid-drop.sh) into run/v9/gcroot-cv3, once
# ana-r7chain2 (repair-mix, R7's windows) and ana-r7vf (the CPU check) are done (2026-11-16 05:06: the build's
# bend took 17.7 GB next to repair-mix with 4 GB left, so it was stopped).  The nix-daemon builds it, outside any
# MemoryMax of ours, hence the wait for the machine to be free.  Builds only: runs, rents and deletes nothing.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
for u in ana-r7chain2 ana-r7vf; do
  while systemctl --user is-active -q $u; do sleep 60; done
  say "$u done"
done
a=$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)
[ "$a" -ge 22 ] || { say "FAILED: only $a GB available; not building"; exit 1; }
say "nix build .#bend-corpus-v2 ($(git rev-parse --short HEAD), $a GB available)"
nix build .#bend-corpus-v2 -o run/v9/gcroot-cv3 || { say "FAILED: nix build"; exit 1; }
say "end: $(readlink -f run/v9/gcroot-cv3)"
