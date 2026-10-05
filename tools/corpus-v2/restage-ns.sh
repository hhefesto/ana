#!/usr/bin/env bash
# mix 2 less the Agda vault, rebuilt as ns1..ns4 and re-pushed (the chain reaches ns1 after nr6)
set -u
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] restage-ns: $*"; }
H=root@137.175.22.196; PT=50891
CV2=${CV2:-nix run .#deploy -- corpus-v2}
echo "mix 2: $($CV2 drop-repos run/v2/holdout/vault.tsv run/rawnew2/mix.jsonl run/rawnew2/mix.jsonl.tmp)"
mv run/rawnew2/mix.jsonl run/rawnew2/mix.with-vault.jsonl && mv run/rawnew2/mix.jsonl.tmp run/rawnew2/mix.jsonl
built=0
for k in 1 2 3 4 5; do
  rm -rf run/ns$k
  if R=run/rawnew2 P=ns JOBS=6 bend/gpu/raw-stage.sh build $k > run/ns-rebuild$k.log 2>&1; then built=$k; log "built ns$k ($(head -1 run/ns$k/plan-fp100m-b16-windows.tsv | awk '{print $3}') steps)"; else log "ns$k: nothing left to build"; rm -rf run/ns$k; break; fi
done
for k in $(seq 1 $built); do
  for t in 1 2 3 4 5 6; do
    ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $PT $H "rm -rf formalTransformer/run/ns$k" && P=ns bend/gpu/raw-stage.sh push $k $H $PT > run/ns-repush$k.log 2>&1 && { log "ns$k re-pushed"; break; }
    log "ns$k push try $t failed"; sleep 60
  done
done
log "done: $built slices"
