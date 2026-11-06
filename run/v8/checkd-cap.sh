#!/usr/bin/env bash
# A check daemon over CAP GB is killed: units.sh restarts it, bendu sees the connection end.  11-05 22:21 and 22:33: one unit of a2bpm21 took a daemon to 24 G in 2.5 minutes, and the guard stopped the night.
CAP=${CAP:-5}; L=/tmp/bx/ck/cap.log
while :; do
  for p in $(pgrep -f 'g/checkd\.js [0-9]'); do
    [ "$p" = "$$" ] && continue
    r=$(awk '/^VmRSS/ {print $2}' /proc/$p/status 2>/dev/null)
    if [ "${r:-0}" -gt $((CAP * 1048576)) ]; then
      echo "$(date '+%F %T') kill $p rss=$((r / 1048576))G $(tr '\0' ' ' < /proc/$p/cmdline | cut -c60-)" >> $L
      kill -9 $p
    fi
  done
  sleep 2
done
