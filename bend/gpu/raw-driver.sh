#!/usr/bin/env bash
# Keep the chain fed with raw code: once raw-stage.sh's mix and slice 1 are
# built, push each slice and append its stage to STAGES, building the next
# while the box trains on the last. Transcript waves are inserted by hand
# right after the stage that is training, so they go ahead of raw slices not
# yet started.
#   raw-driver.sh HOST PORT STAGES [FIRST] [LAST]
set -u
host="${1:?usage: raw-driver.sh HOST PORT STAGES [FIRST] [LAST]}"; port="${2:?}"; stages="${3:?}"
first=${4:-1}; last=${5:-9}
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] raw-driver: $*"; }
# slice 1 is built by the mix unit
while systemctl --user is-active -q ft-raw-mix; do sleep 30; done
for k in $(seq "$first" "$last"); do
  if [ ! -f "run/raw$k/plan-fp100m-b16-windows.tsv" ]; then
    log "building slice $k"
    bend/gpu/raw-stage.sh build "$k" > "run/raw-build$k.log" 2>&1 || { log "slice $k did not build (the mix may be used up); stopping"; exit 0; }
  fi
  log "pushing slice $k"
  bend/gpu/raw-stage.sh push "$k" "$host" "$port" > "run/raw-push$k.log" 2>&1 || { log "slice $k did not push; stopping"; exit 1; }
  echo "raw$k traind-next 0 run/raw$k/plan-raw$k-b16-windows.tsv run/raw$k raw$k" >> "$stages"
  log "slice $k staged and appended ($(head -1 run/raw$k/plan-fp100m-b16-windows.tsv | awk '{ print $3 }') steps)"
done
