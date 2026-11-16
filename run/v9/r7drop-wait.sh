#!/usr/bin/env bash
# r7valid-drop.sh as soon as it can run: after ana-cv3-wait (R7 ready, its CPU check, then the nix build of
# bend-corpus-v2 into run/v9/gcroot-cv3).  So R7valid is without the 102 sessions and 9 files that have a copy in
# training by the time the user approves training (2026-11-16: "be ready to train on my approval").  Moves, never
# deletes: the old R7valid stays as R7valid.full, its inputs as R7vsrc.full (undo: move them back).  Rents nothing.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
while systemctl --user is-active -q ana-cv3-wait; do sleep 60; done
if [ -x run/v9/gcroot-cv3/bin/bend-corpus-v2 ]; then
  say "ana-cv3-wait done: $(readlink -f run/v9/gcroot-cv3)"
  bash run/v9/r7valid-drop.sh
else
  # the nix build didn't happen (it wants 22 GB free): the binary bend built from the same CorpusV2 source
  # (04:55-05:03, no source file changed since), the one the trial on copies in /tmp/bx/r7drop-sbx ran
  T=/tmp/bx/cv-drop/bend-corpus-v2
  [ -x $T ] || { say "FAILED: no run/v9/gcroot-cv3 and no $T"; exit 1; }
  say "no run/v9/gcroot-cv3 (journalctl --user -u ana-cv3-wait): using $T"
  CV=$T bash run/v9/r7valid-drop.sh
fi
