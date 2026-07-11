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

rm -f "$checkpoint"
start=$(date +%s)
TOKENIZER_FILE="$tokenizer" TRAIN_BATCH="$batch" MICRO_BATCH="$micro" \
  CHECKPOINT_EVERY="$steps" FUT_CACHE="${FUT_CACHE:-/tmp/formal-transformer-cuda.cache}" \
  nix run .#formal-transformer-cuda -- \
    train "$corpus" "$checkpoint" "$steps" bpe10m
end=$(date +%s)

elapsed=$(( end - start ))
if [ "$elapsed" -le 0 ]; then elapsed=1; fi
tokens=$(( steps * batch * 255 ))
awk -v tokens="$tokens" -v elapsed="$elapsed" \
  'BEGIN { printf "benchmark: %d target tokens in %d s = %.2f tokens/s\n", tokens, elapsed, tokens/elapsed }'
