#!/usr/bin/env bash
# box-baseline.sh HOST PORT DEST CAP_EPOCH: run 1's baseline on corpus v2's clean eval corpora
# (docs/CORPUS-V2.md, E3), on the chain's box before it is destroyed. It holds the chain's
# destroy (DEST/HOLD, fp-chain.sh) at CAP_EPOCH at the latest; once the chain has scored and
# pulled (`pulled:` in DEST/chain.log), it scores fp100m-step8803 (the transcripts-only end),
# w1-step19080, w3-step40731 and the chain's last checkpoint on run/eval/v2-tr-LANG.corpus and
# run/eval/v2-vault-LANG.corpus, pulls the logs to DEST/v2eval/, and lets the destroy go
# (HOLD = 0). If anything fails the destroy still comes at CAP_EPOCH.
set -u
host="${1:?usage: box-baseline.sh HOST PORT DEST CAP_EPOCH}"; port="${2:?}"; dest="${3:?}"; cap="${4:?}"
SSH="ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port $host"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] box-baseline: $*" | tee -a "$dest/chain.log"; }
release() { echo 0 > "$dest/HOLD"; log "destroy released"; }
echo "$cap" > "$dest/HOLD"
log "holding the destroy until $(TZ=Etc/GMT+6 date -d @"$cap" '+%H:%M') at the latest"
C="run/eval/v2-tr-haskell.corpus run/eval/v2-tr-agda.corpus run/eval/v2-tr-lean.corpus run/eval/v2-tr-nix.corpus run/eval/v2-tr-bend.corpus run/eval/v2-vault-haskell.corpus run/eval/v2-vault-agda.corpus run/eval/v2-vault-lean.corpus"
for t in 1 2 3 4 5 6; do
  rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port" $C "$host:formalTransformer/run/eval/" && break
  sleep 60
done || true
until grep -q 'pulled: ' "$dest/chain.log" 2>/dev/null; do
  grep -q 'is NOT destroyed\|DESTROYED' "$dest/chain.log" 2>/dev/null && { log "the chain did not reach its pulls; nothing to do"; exit 0; }
  [ -f "$dest/DESTROYED" ] && exit 0
  sleep 60
done
log "the chain pulled; scoring run 1 on corpus v2's eval corpora"
# on the box, under nohup (the link drops): every corpus over the four checkpoints, then DONE
$SSH "cd formalTransformer && rm -f v2eval.DONE && nohup bash -c 'last=\$(ls -t out/*.checkpoint | head -1); for c in $C; do n=\$(basename \$c .corpus); ECORPUS=\$c ./fp.sh eval out/fp100m-step8803.checkpoint out/w1-step19080.checkpoint out/w3-step40731.checkpoint \$last > v2eval-\$n.log 2>&1; done; touch v2eval.DONE' > /dev/null 2>&1 &" || true
while [ "$(date +%s)" -lt "$cap" ]; do
  $SSH 'test -f formalTransformer/v2eval.DONE' 2>/dev/null && break
  sleep 60
done
mkdir -p "$dest/v2eval"
for t in 1 2 3 4 5; do
  rsync -a -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port" "$host:formalTransformer/v2eval-*.log" "$dest/v2eval/" && break
  sleep 30
done
for f in "$dest"/v2eval/v2eval-*.log; do
  [ -f "$f" ] && log "$(basename "$f" .log): $(grep -E '^==|bits_per_byte' "$f" | sed -E 's/.*out\/([^ ]*)\.checkpoint.*/\1/; s/.*bits_per_byte=([0-9.]*).*/\1/' | paste -sd' ')"
done
release
