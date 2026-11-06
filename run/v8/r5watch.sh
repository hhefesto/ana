#!/usr/bin/env bash
# The night's watch (11-05 22:55, "Work on ana and the bend corpus"): the guard never restarts what it stops, and on 11-05 it stopped the
# slice three times in 20 minutes.  A plan's unit that is gone, whose log does not end in `is ready` or a FAILED, comes back when memory has:
# steps keep what they finished.  A FAILED is left for a person: it would only fail again.  Unit ana-r5watch, outside the slice.  It ends when R5n is ready.
cd /home/hhefesto/src/ana || exit 1
L=run/v8/r5watch.log
say() { echo "$(date '+%F %T') $*" >> $L; }
avail() { awk '/^MemAvailable/ {print int($2/1048576)}' /proc/meminfo; }
ready() { tail -n 1 "$1" | grep -q 'is ready'; }
failed() { tail -n 1 "$1" | grep -q 'FAILED'; }
start() {  # unit script log [env]
  local u=$1 s=$2 l=$3 e=${4:-}
  systemctl --user reset-failed $u 2>/dev/null
  systemd-run --user --unit=$u --slice=ana-work.slice --same-dir ${e:+-E $e} -p StandardOutput=append:$PWD/$l -p StandardError=append:$PWD/$l /run/current-system/sw/bin/bash $s >> $L 2>&1
}
say "up"
told=
while :; do
  for x in "ana-run5c run/v8/run5c.sh run/v8/run5c.log" "ana-run5n run/v8/run5n.sh run/v8/run5n.log" "ana-run5b run/v6/run5b.sh run/v6/run5b.log PWJOBS=3"; do
    set -- $x
    systemctl --user is-active -q $1 && continue
    ready $3 && continue
    if failed $3; then
      # (11-06: a plan that ran out of filler gets more, and only those shards are made again; three rounds, then it is left for a person)
      case $1 in ana-run5c) d=run/v8/R5c ;; ana-run5n) d=run/v8/R5n ;; *) d=run/v6/R5b ;; esac
      if tail -n 1 $3 | grep -q "FAILED: plan-windows" && grep -q "no unused document" $d.log && [ "$(cat $d.morerounds 2>/dev/null || echo 0)" -lt 3 ] && [ "$(avail)" -ge 12 ]; then
        c=$(bash run/v8/fillmore.sh $d $d.log 1500); echo $(( $(cat $d.morerounds 2>/dev/null || echo 0) + 1 )) > $d.morerounds
        say "$1: $c shards out of filler, given more; restarting"; start $1 $2 $3 $4; sleep 30; continue
      fi
      case " $told " in *" $1 "*) ;; *) say "$1: $(tail -n 1 $3 | cut -c1-200)"; told="$told $1"; notify-send -u critical ana "$1: $(tail -n 1 $3 | cut -c1-160)" 2>/dev/null ;; esac
      continue
    fi
    # the plan first, the fallback when there is room for it too
    need=12; [ $1 = ana-run5b ] && need=14
    [ "$(avail)" -ge $need ] || continue
    say "restarting $1 ($(avail) G available)"
    start $1 $2 $3 $4
    sleep 30
  done
  ready run/v8/run5n.log && { say "R5n is ready: end"; exit 0; }
  sleep 60
done
