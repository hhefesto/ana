#!/usr/bin/env bash
# Gates G1-G3 on a GPU box, for the dense Bend trainer built with the
# ft-kernels fork. Expects in the working directory: einsum.c, dense.c,
# traind.c (bend X.bend -o X.c), corpus.txt and tok.bpe. Needs clang
# (any version) and /usr/local/cuda.
#   STEPS  training steps to time (default 12)
set -u
CU=/usr/local/cuda
# any clang: a program with no bang needs no #embed (-DBEND_NO_SRC)
CLANG=$(for c in clang-19 clang-18 clang-17 clang-16 clang-15 clang-14 clang; do command -v $c && break; done | head -1)
CC="$CLANG -DBEND_CUDA=1 -DBEND_NO_SRC -I$CU/include -L$CU/lib64 -std=c11 -O2"
export LD_LIBRARY_PATH=$CU/lib64:${LD_LIBRARY_PATH:-}
for p in einsum dense traind; do
  [ -x $p ] || $CC $p.c -lpthread -lm -o $p -lcuda -lnvrtc || exit 1
done
nvidia-smi --query-gpu=name,driver_version,power.limit,memory.total --format=csv,noheader
free -g | head -2
MEM=${MEM:-48GB}

echo "== G1: einsum kernels against the loop"
BEND_GEMM=loop ./einsum --gpu $MEM > e.loop.txt
BEND_PROFILE=2 ./einsum --gpu $MEM > e.gpu.txt 2> e.prof
cmp e.loop.txt e.gpu.txt && echo "identical ($(grep -c 'einsum kernel' e.prof) calls on kernels)" || { echo MISS; cat e.loop.txt e.gpu.txt; }

echo "== G2: the dense program on the GPU against the tree trainer on the CPU"
BEND_PROFILE=1 ./dense --gpu $MEM 2>&1 | tail -12

echo "== G3: bpe100m-v3 training, batch 64 (2 micro-batches of 32), muon, tf32"
nvidia-smi dmon -s pucm -d 2 > dmon.txt 2>&1 &
DM=$!
BEND_GEMM_NUMERICS=tf32 BEND_PROFILE=1 CORPUS=corpus.txt TOKENIZER_FILE=tok.bpe PRESET=bpe100m-v3 \
  TRAIN_STEPS=${STEPS:-12} TRAIN_BATCH=64 TRAIN_MICRO=32 TRAIN_OPT=muon TRAIN_LR=0.02 TRAIN_WARMUP=100 \
  EVAL_WINDOWS=0 OUT= ./traind --gpu $MEM 2>&1 | tee train.log | grep -v "^bend profile: einsum kernel"
kill $DM
awk '/^step [0-9]+ loss/ && $2 > 2 { n++; ms += $NF } END { if (n) printf "steady state: %.0f ms/step over %d steps = %.0f tok/s (64 x 256 tokens a step)\n", ms/n, n, 16384 / (ms/n/1000) }' train.log
echo "== dmon"; head -2 dmon.txt; grep -v "^#" dmon.txt | sort -k2 -n | tail -4
