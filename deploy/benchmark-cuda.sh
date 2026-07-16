#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 CORPUS TOKENIZER.bpe" >&2
  exit 1
fi

corpus=$1
tokenizer=$2
batch=${TRAIN_BATCH:-8}
micro=${MICRO_BATCH:-$batch}
steps=${BENCH_STEPS:-5}
checkpoint=${BENCH_CHECKPOINT:-/tmp/formal-transformer-bpe10m-benchmark.checkpoint}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# cloud-init.sh records the LD_LIBRARY_PATH that resolves the container's
# injected libcuda.so.1 (empty when the default loader paths already work).
if [ -f run/cloud-env.sh ]; then
  # shellcheck disable=SC1091
  . run/cloud-env.sh
fi
# Prefer the already-built binary (cloud-init built it); `nix run` on a
# non-git tree would copy run/ corpora into the store and rebuild needlessly.
trainer=result/bin/formal-transformer-cuda
if [ ! -x "$trainer" ]; then
  nix --extra-experimental-features "nix-command flakes" build .#formal-transformer-cuda
fi

rm -f "$checkpoint"
start=$(date +%s)
TOKENIZER_FILE="$tokenizer" TRAIN_BATCH="$batch" MICRO_BATCH="$micro" \
  CHECKPOINT_EVERY="$steps" FUT_CACHE="${FUT_CACHE:-/tmp/formal-transformer-cuda.cache}" \
  FUT_REJECT_INTRA="${FUT_REJECT_INTRA:-1}" \
  "$trainer" train "$corpus" "$checkpoint" "$steps" bpe10m
end=$(date +%s)

elapsed=$(( end - start ))
if [ "$elapsed" -le 0 ]; then elapsed=1; fi
tokens=$(( steps * batch * 255 ))
awk -v tokens="$tokens" -v elapsed="$elapsed" \
  'BEGIN { printf "benchmark: %d target tokens in %d s = %.2f tokens/s\n", tokens, elapsed, tokens/elapsed }'
