#!/usr/bin/env bash
# mix 2 less the Agda vault, rebuilt as ns1..ns4 and re-pushed (the chain reaches ns1 after nr6)
set -u
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] restage-ns: $*"; }
H=root@137.175.22.196; PT=50891
python3 - <<'PY'
import sys, json
sys.path.insert(0, "tools/corpus-v2")
from names import repo_of
vault = {l.split("\t")[1] for l in open("run/v2/holdout/vault.tsv").read().splitlines()[1:]}
n = drop = 0
with open("run/rawnew2/mix.jsonl", "rb") as f, open("run/rawnew2/mix.jsonl.tmp", "wb") as o:
    for line in f:
        i = line.find(b'"id":'); i = line.find(b'"', i + 5) + 1; j = line.find(b'"', i)
        if repo_of(line[i:j].decode("utf-8", "replace")) in vault: drop += 1; continue
        o.write(line); n += 1
print(f"mix 2: kept {n} documents, dropped {drop} from the vault")
PY
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
