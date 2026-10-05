#!/usr/bin/env bash
# Keep the chain fed with raw code: once raw-stage.sh's mix and slice 1 are
# built, push each slice and append its stage to STAGES, building the next
# while the box trains on the last. Transcript waves are inserted by hand
# right after the stage that is training, so they go ahead of raw slices not
# yet started.
#   raw-driver.sh HOST PORT STAGES [FIRST] [LAST]
# R and P as for raw-stage.sh (the mix's directory, the stages' prefix: raw
# by default). With CREDIT_GUARD=1 a slice is appended only while the vast
# credit covers everything queued after it: the steps left on the box (the
# newest log's step against its plan's end, then every stage line after it)
# plus this slice's, at SECS_PER_STEP (2.16) and DPH ($/h, 0.494), plus the
# end (scores, pulls: END_COST, $0.60) and MARGIN ($1.00). The credit ran out
# under a running chain once (2026-10-03 05:03) and the box was lost.
set -u
host="${1:?usage: raw-driver.sh HOST PORT STAGES [FIRST] [LAST]}"; port="${2:?}"; stages="${3:?}"
first=${4:-1}; last=${5:-9}
P=${P:-raw}
V=$HOME/.local/share/vastai-venv/bin/vastai
CV2=${CV2:-nix run .#deploy -- corpus-v2}
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] raw-driver: $*"; }

# 0 when the credit covers the queue plus slice $1's steps
credit_ok() {
  local credit cur
  credit=$($V show user --raw 2>/dev/null | $CV2 credit) || return 1
  cur=$(ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p "$port" "$host" 'cd formalTransformer && l=$(ls -t *.log | grep -v "^eval" | head -1) && echo "${l%.log} $(grep -o "step=[0-9]*/[0-9]*" $l | tail -1)"' 2>/dev/null) || return 1
  # the message on stderr; 0 when the credit covers it
  $CV2 credit-ok "$stages" "$credit" "$cur" "$1"
}

# slice 1 is built by the mix unit
while systemctl --user is-active -q ft-raw-mix; do sleep 30; done
for k in $(seq "$first" "$last"); do
  if [ ! -f "run/$P$k/plan-fp100m-b16-windows.tsv" ]; then
    log "building slice $k"
    bend/gpu/raw-stage.sh build "$k" > "run/$P-build$k.log" 2>&1 || { log "slice $k did not build (the mix may be used up); stopping"; exit 0; }
  fi
  n=$(head -1 "run/$P$k/plan-fp100m-b16-windows.tsv" | awk '{ print $3 }')
  if [ "${CREDIT_GUARD:-0}" = 1 ]; then
    until credit_ok "$n" 2> >(while read -r l; do log "$l"; done); do
      log "slice $k ($n steps) waits: the credit does not cover it (top up, or it stays out)"; sleep 600
    done
  fi
  log "pushing slice $k"
  # the box's link drops now and then: a push resumes (rsync --partial) up to 6 times
  ok=0; for t in 1 2 3 4 5 6; do
    bend/gpu/raw-stage.sh push "$k" "$host" "$port" >> "run/$P-push$k.log" 2>&1 && { ok=1; break; }
    log "slice $k push try $t failed; again in a minute"; sleep 60
  done
  [ $ok = 1 ] || { log "slice $k did not push after 6 tries; stopping"; exit 1; }
  echo "$P$k traind-next 0 run/$P$k/plan-$P$k-b16-windows.tsv run/$P$k $P$k" >> "$stages"
  log "slice $k staged and appended ($n steps)"
done
