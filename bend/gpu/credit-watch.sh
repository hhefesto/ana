#!/usr/bin/env bash
# UNWIRED 2026-10-15: replaced by `bend-ops watch HOST PORT DEST [MIN]` (bend/Box/Watch.bend, the plan's Phase 1a; the sandbox scenarios run a copy of this script without these two lines); kept for reference
exit 2
# The last line of defence under an unattended chain (fp-chain.sh), for the
# credit and for the box. Every WATCH_POLL seconds (600):
# - Under MIN ($1.00) it stops the trainer on the box, once, so the chain sees
#   the stage die (20 quiet minutes) and goes on to its scores, pulls and
#   destroy while there is still credit to pay for them: vast stops a box when
#   the balance passes -$0.01, and a stopped box can lose its GPU to another
#   renter (2026-10-03). DEST/CREDIT_LOW says it happened; remove it after a
#   top-up to arm the stop again.
# - Once the chain has refused the destroy (DEST/REFUSED) GRACE seconds (3600)
#   ago, or the trainer was stopped for the credit LOW_WAIT seconds (5400) ago
#   and the box is still up, it checks the box itself, both sides read afresh:
#   no trainer running, and every checkpoint on the box here with the box's
#   sha256. Then it destroys the box (DEST/INSTANCE, written by the chain),
#   unless DEST/CONTINUED exists or DEST/HOLD's deadline is ahead; otherwise it
#   alerts, once an hour. On 2026-10-07 a wrong check in the chain kept run 2's
#   box billing 4.7 h after training ended, with nothing left on it to fetch.
# - When the chain has written nothing to chain.log for SILENT seconds (10800:
#   its longest quiet wait is 2 h) and the box is not destroyed, it alerts.
# An alert is a chain.log line, a desktop notification that stays up until
# dismissed, and ALERT_CMD if set (run by bash with the message as $1).
#   credit-watch.sh HOST PORT DEST [MIN]
set -u
host="${1:?usage: credit-watch.sh HOST PORT DEST [MIN]}"; port="${2:?}"; dest="${3:?}"; min=${4:-1.00}
V=${V:-$HOME/.local/share/vastai-venv/bin/vastai}
CV2=${CV2:-nix run .#deploy -- corpus-v2}
SSH="ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port $host"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] credit-watch: $*" | tee -a "$dest/chain.log"; }
alert() {
  log "ALERT: $*"
  notify-send -u critical "ana box $(cat "$dest/INSTANCE" 2>/dev/null)" "$*" >/dev/null 2>&1
  [ -n "${ALERT_CMD:-}" ] && bash -c "$ALERT_CMD" _ "$*" >/dev/null 2>&1
  return 0
}
# the box can go: no trainer on it, and every checkpoint on it here with its sha256 (else $why)
box_safe() {
  local remote h f bad=""
  [ "$($SSH 'pgrep -x traind; pgrep -x traind-next; echo end' 2>/dev/null)" = end ] || { why="a trainer runs on the box, or it did not answer"; return 1; }
  remote=$($SSH 'cd ana/out && sha256sum *.checkpoint' 2>/dev/null)
  [ -n "$remote" ] || { why="the box gave no sha256"; return 1; }
  while read -r h f; do
    [ "$(sha256sum < "$dest/out/$f" 2>/dev/null | cut -d' ' -f1)" = "$h" ] || bad="$bad $f"
  done <<< "$remote"
  [ -z "$bad" ] || { why="not here with the box's sha256:$bad"; return 1; }
  why="every checkpoint on the box ($(echo "$remote" | wc -l)) is here with its sha256"
}
destroy() {
  local inst; inst=$(cat "$dest/INSTANCE" 2>/dev/null)
  [ -n "$inst" ] || { why="no DEST/INSTANCE"; return 1; }
  [ -f "$dest/CONTINUED" ] && { why="DEST/CONTINUED: someone took the box over"; return 1; }
  if [ -f "$dest/HOLD" ] && [ "$(date +%s)" -lt "$(cat "$dest/HOLD" 2>/dev/null || echo 0)" ]; then why="DEST/HOLD's deadline is ahead"; return 1; fi
  box_safe || return 1
  rsync -a -e "ssh -o StrictHostKeyChecking=no -p $port" --include='*.log*' --include='*.txt' --exclude='*' "$host:ana/" "$dest/" >/dev/null 2>&1
  log "$why: destroy instance $inst"
  $V destroy instance "$inst" -y 2>&1 | tee -a "$dest/chain.log"
  sleep 10
  if $V show instances --raw 2>/dev/null | grep -q "\"id\": $inst\b"; then why="instance $inst still listed after destroy"; return 1; fi
  date > "$dest/DESTROYED"; log "finished"
}
alerted=0
while [ ! -f "$dest/DESTROYED" ]; do
  # the credit, and 0 when it is under $min
  if [ ! -f "$dest/CREDIT_LOW" ]; then
    c=$($V show user --raw 2>/dev/null | $CV2 credit "$min" 2>/dev/null); low=$?
    if [ -n "$c" ] && [ "$low" = 0 ]; then
      log "credit \$$c is under \$$min: stopping the trainer so the chain scores, pulls and destroys"
      $SSH 'pkill -x traind-next; pkill -x traind' 2>/dev/null
      date > "$dest/CREDIT_LOW"
    fi
  fi
  now=$(date +%s); due=""
  [ -f "$dest/REFUSED" ] && [ $((now - $(stat -c %Y "$dest/REFUSED"))) -ge "${GRACE:-3600}" ] && due="the chain refused the destroy ($(cat "$dest/REFUSED") )"
  [ -z "$due" ] && [ -f "$dest/CREDIT_LOW" ] && [ $((now - $(stat -c %Y "$dest/CREDIT_LOW"))) -ge "${LOW_WAIT:-5400}" ] && due="the box is up $(( ${LOW_WAIT:-5400} / 60 )) min after the trainer was stopped for the credit"
  [ -z "$due" ] && [ -f "$dest/chain.log" ] && [ $((now - $(stat -c %Y "$dest/chain.log"))) -ge "${SILENT:-10800}" ] && [ $((now - alerted)) -ge 3600 ] && { alert "the chain has written nothing for $(( ${SILENT:-10800} / 3600 )) h and the box is not destroyed"; alerted=$now; }
  if [ -n "$due" ] && ! destroy && [ $((now - alerted)) -ge 3600 ]; then alert "$due; not destroyed: $why"; alerted=$now; fi
  [ -f "$dest/DESTROYED" ] || sleep ${WATCH_POLL:-600}
done
