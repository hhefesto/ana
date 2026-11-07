#!/usr/bin/env bash
# ckd-sup.sh OWNER STATE PORT ROOT: one tools/checkd daemon for a with.sh or units.sh that is already running (pid OWNER),
# restarted if it dies, until OWNER ends.  11-07 17:15: bun 1.4.2 had left the store (with.sh and units.sh look for
# /nix/store/*-bun-1.4.2), so every with.sh/units.sh since ran `"" checkd.js` in a loop, no daemon came up, bendc fell back
# on the real bend (2-4 s a check) and bendu waited 180 s a unit before it did (gh50: 11 units in 2 h 20).  bun is back
# (agda2bend/run/a2b/gcroot-bun); this gives the running ones their daemons, in place of their dead supervisors, so the
# emits and checks under way keep what they have done.
OWNER=$1; S=$2; PORT=$3; ROOT=$4
BUN=${BUN:-/home/hhefesto/src/agda2bend/run/a2b/gcroot-bun/bin/bun}
[ -x "$BUN" ] && [ -f "$S/g/checkd.js" ] || { echo "no $BUN or $S/g/checkd.js"; exit 1; }
echo "$PORT" > "$S/port"
while kill -0 "$OWNER" 2>/dev/null; do
  "$BUN" "$S/g/checkd.js" "$PORT" "$ROOT" >> "$S/log" 2>&1 &
  d=$!; echo "$d" > "$S/pid"
  while kill -0 "$d" 2>/dev/null; do
    kill -0 "$OWNER" 2>/dev/null || { kill "$d" 2>/dev/null; break; }
    sleep 3
  done
  sleep 1
done
