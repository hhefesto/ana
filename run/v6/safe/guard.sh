#!/usr/bin/env bash
# Keep olimpo usable (2026-11-03).  Freezing does not give memory back and nix-daemon's builders are not in
# any of my cgroups, so under pressure this STOPS ana-work.slice (every job here restarts from what it kept;
# nix clients run inside the slice, and a stopped client cancels its daemon build).  It never restarts anything.
LOW=${LOW:-4}; SWAP=${SWAP:-6}; LOG=${LOG:-$HOME/src/ana/run/v6/safe/guard.log}
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
    # the exports and R5b's fallback mix next: they cost least against the emits' hours (11-05)
    elif systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-exp-*' 'a2b-b[0-9]*' 'ana-mix2*' 'a2b-gh[0-9]*' | grep -q .; then
      say "available ${a}G, swap used ${s}G: stopping the exports, a build, the fallback mix"
      systemctl --user list-units --type=service --state=active --no-legend --plain 'a2b-exp-*' 'a2b-b[0-9]*' 'ana-mix2*' 'a2b-gh[0-9]*' | awk '{print $1}' >> "$LOG"
      systemctl --user stop 'a2b-exp-*' 'a2b-b[0-9]*' 'ana-mix2*' 'a2b-gh[0-9]*'
      sleep 15
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
