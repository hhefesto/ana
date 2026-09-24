#!/usr/bin/env bash
# Hot start on a GPU box: the dense Bend trainer continues master's
# bpe100m-v3 run from its step-8000 checkpoint, on master's plan and
# shards, with master's schedule (lr, warmup, total from the manifest).
# Expects in the working directory: traind.c (bend TrainDense.bend -o
# traind.c), ckpt (the FTC2 checkpoint), tok.bpe, plan.tsv and shards/
# (shard-<k>-bpe100m.corpus). Needs clang (any version) and /usr/local/cuda.
#   STEPS  steps to run from the checkpoint (default 20000)
#   SAVE   save every n steps (default 2000); out/v3-bend-step<N>.checkpoint
set -u
CU=/usr/local/cuda
CLANG=$(for c in clang-19 clang-18 clang-17 clang-16 clang-15 clang-14 clang; do command -v $c && break; done | head -1)
export LD_LIBRARY_PATH=$CU/lib64:${LD_LIBRARY_PATH:-}
[ -x traind ] || $CLANG -DBEND_CUDA=1 -DBEND_NO_SRC -I$CU/include -L$CU/lib64 -std=c11 -O2 traind.c \
  -lpthread -lm -o traind -lcuda -lnvrtc || exit 1
mkdir -p out
nvidia-smi --query-gpu=name,driver_version,power.limit,memory.total --format=csv,noheader
free -g | head -2
nohup nvidia-smi dmon -s pucm -d 10 > dmon.txt 2>&1 &
# the first validation (before any step) is master's step-8000 figure on the
# same 256 windows: 3.6271493 in master's log
BEND_GEMM_NUMERICS=tf32 TRAIN_INIT=ckpt TOKENIZER_FILE=tok.bpe PLAN=plan.tsv RUN_DIR=shards SHARD_SIZE=bpe100m \
  TRAIN_STEPS=${STEPS:-20000} TRAIN_BATCH=64 TRAIN_MICRO=32 TRAIN_CHUNK=16 EVAL_EVERY=2000 EVAL_WINDOWS=256 \
  SAVE_EVERY=${SAVE:-2000} OUT=out/v3-bend \
  nohup ./traind --gpu ${MEM:-48GB} > train.log 2>&1 &
echo "trainer pid $!"
