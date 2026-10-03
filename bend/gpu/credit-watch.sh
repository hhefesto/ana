#!/usr/bin/env bash
# The credit's last line of defence under an unattended chain: vast stops a box
# when the balance passes -$0.01, and a stopped box can lose its GPU to another
# renter (2026-10-03). Every 10 minutes it reads the vast credit; below MIN
# ($1.00) it stops the trainer on the box, so the chain sees the stage die (20
# quiet minutes) and goes on to its scores, pulls and destroy while there is
# still credit to pay for them. DEST/CREDIT_LOW says it happened.
#   credit-watch.sh HOST PORT DEST [MIN]
set -u
host="${1:?usage: credit-watch.sh HOST PORT DEST [MIN]}"; port="${2:?}"; dest="${3:?}"; min=${4:-1.00}
V=$HOME/.local/share/vastai-venv/bin/vastai
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] credit-watch: $*" | tee -a "$dest/chain.log"; }
while [ ! -f "$dest/DESTROYED" ]; do
  c=$($V show user --raw 2>/dev/null | python3 -c "import json,sys; print(json.loads(sys.stdin.read(), strict=False)['credit'])" 2>/dev/null)
  if [ -n "$c" ] && python3 -c "import sys; sys.exit(0 if float('$c') < float('$min') else 1)"; then
    log "credit \$$c is under \$$min: stopping the trainer so the chain scores, pulls and destroys"
    ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p "$port" "$host" 'pkill -x traind-next; pkill -x traind' 2>/dev/null
    date > "$dest/CREDIT_LOW"; exit 0
  fi
  sleep 600
done
