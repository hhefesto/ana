#!/usr/bin/env bash
# Keep olimpo usable (2026-11-03).  Freezing does not give memory back and nix-daemon's builders are not in
# any of my cgroups, so under pressure this STOPS ana-work.slice (every job here restarts from what it kept;
# nix clients run inside the slice, and a stopped client cancels its daemon build).  It never restarts anything.
LOW=${LOW:-8}; SWAP=${SWAP:-6}; LOG=${LOG:-$HOME/src/ana/run/v6/safe/guard.log}
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
say "guard up: stop ana-work.slice under ${LOW}G available or over ${SWAP}G swap used"
while :; do
  read -r a s <<<"$(awk '/^MemAvailable/ {a=$2} /^SwapTotal/ {t=$2} /^SwapFree/ {f=$2} END {print int(a/1048576), int((t-f)/1048576)}' /proc/meminfo)"
  if [ "$a" -lt "$LOW" ] || [ "$s" -ge "$SWAP" ]; then
    # a nix build first: its clang is the biggest single thing and costs least to redo
    if systemctl --user list-units --type=service --state=active --no-legend --plain 'ana-nix-*' | grep -q .; then
      say "available ${a}G, swap used ${s}G: stopping the nix client"
      systemctl --user stop 'ana-nix-*'
      sleep 15
    # then one group at a time, what costs least to lose first (11-05): the exports and a build; a GitHub shard (short, and what it reached stays); the units; the emits;
    # last R5b's fallback mix (a stopped mix starts over: hours, and it is the plan that can be rented first)
    elif systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-exp-*' 'a2b-b[0-9]*' | grep -q .; then
      say "available ${a}G, swap used ${s}G: stopping the exports, a build"
      systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-exp-*' 'a2b-b[0-9]*' | awk '{print $1}' >> "$LOG"
      systemctl --user stop 'a2b-exp-*' 'a2b-b[0-9]*'
      sleep 15
    elif systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-gh[0-9]*' | grep -q .; then
      # (11-05 22:55: the biggest one, not all: a stopped shard's other modules are lost)
      b=$(for u in $(systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-gh[0-9]*' | awk '{print $1}'); do echo "$(systemctl --user show -p MemoryCurrent --value $u) $u"; done | sort -rn | head -1 | cut -d' ' -f2)
      say "available ${a}G, swap used ${s}G: stopping the GitHub shard $b"
      systemctl --user stop "$b"
      sleep 30
    # what run5c.sh takes up again by itself, before the emits' hours
    elif systemctl --user list-units --type=service --state=active --no-legend --plain 'ana-mugen6q*' 'ana-src-*' 'ana-ghsrc*' 'ana-a2bseq*' | grep -q .; then
      say "available ${a}G, swap used ${s}G: stopping the units and the mugen shape"
      systemctl --user list-units --type=service --state=active --no-legend --plain 'ana-mugen6q*' 'ana-src-*' 'ana-ghsrc*' 'ana-a2bseq*' | awk '{print $1}' >> "$LOG"
      systemctl --user stop 'ana-mugen6q*' 'ana-src-*' 'ana-ghsrc*' 'ana-a2bseq*'
      sleep 15
    # (11-05, "refl always takes priority": the emits one at a time, by what they add to what we already have: a stopped emit's modules stay)
    elif systemctl --user is-active -q a2b-um21; then
      say "available ${a}G, swap used ${s}G: stopping a2b-um21"; systemctl --user stop a2b-um21; sleep 15
    elif systemctl --user is-active -q a2b-std21; then
      say "available ${a}G, swap used ${s}G: stopping a2b-std21"; systemctl --user stop a2b-std21; sleep 15
    elif systemctl --user is-active -q a2b-fl1; then
      say "available ${a}G, swap used ${s}G: stopping a2b-fl1"; systemctl --user stop a2b-fl1; sleep 15
    elif systemctl --user is-active -q a2b-tt1; then
      say "available ${a}G, swap used ${s}G: stopping a2b-tt1"; systemctl --user stop a2b-tt1; sleep 15
    elif systemctl --user list-units --type=service --state=active --no-legend --plain 'ana-mix2*' | grep -q .; then
      say "available ${a}G, swap used ${s}G: stopping the fallback mix"
      systemctl --user stop 'ana-mix2*'
      sleep 15
    # (11-05 22:21: check+render at the same time as R5b's shards took the slice with it; R5b is the fallback, and its plan keeps the shards it finished)
    elif systemctl --user is-active -q ana-run5b; then
      say "available ${a}G, swap used ${s}G: stopping the fallback plan"; systemctl --user stop ana-run5b; pkill -f 'bend-(prepare|windows).* run/v6/R5b/' ; sleep 15
    elif systemctl --user is-active -q ana-work.slice; then
      say "available ${a}G, swap used ${s}G: stopping ana-work.slice"
      systemctl --user list-units --type=service --state=active --no-legend --plain 'ana-*' | awk '{print $1}' >> "$LOG"
      systemctl --user stop ana-work.slice
      notify-send -u critical 'ana' "memory low (${a}G free, ${s}G swap): stopped ana-work.slice" 2>/dev/null
    fi
    sleep 10
  fi
  sleep 2
done
