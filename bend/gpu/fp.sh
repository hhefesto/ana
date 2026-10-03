#!/usr/bin/env bash
# The fp100m run on a GPU box: ana's coding-agent model from fresh
# parameters on the plan bend-plan-windows wrote (run/fp100m: 156,067
# windows of 2,046 code32k tokens, 8,803 steps at batch 16), with the dense
# Bend trainer's plan start (TrainDense.bend, PLAN set and TRAIN_INIT
# empty). stdout is line-buffered (stdbuf) so the log shows every step.
#
# Expects, in the working directory (the repository's layout, as
# bend/gpu/fp-stage.sh and bend-push leave it):
#   traind.c dense.c                     bend X.bend -o X.c, from this repo's bend/
#   weights/code32k.bpe                  the tokenizer
#   run/fp100m/plan-fp100m-b16-windows.tsv, run/fp100m/shard-K-fp100m.corpus
#   run/eval/transcript-fp.corpus        the held-out transcripts (eval)
# Needs clang (any version) and /usr/local/cuda; 64 GB of RAM (the managed
# heap holds the host data too).
#
#   fp.sh build            compile traind and dense (once; the kernels JIT on first use)
#   fp.sh gate             G2: the dense program on the GPU against the tree trainer on the CPU
#   fp.sh time [STEPS]     STEPS (20) steps of the real run: ms/step, tok/s, memory
#   fp.sh run              the whole plan (STEPS, 8803), in the background: out/fp100m-step<N>.checkpoint, train.log
#   fp.sh eval [CKPT...]   bits per byte of each checkpoint (out/*.checkpoint) on the held-out transcripts
#                          (ECORPUS: another eval corpus)
#   fp.sh again CKPT PLAN RUN_DIR SHARD_SIZE NAME   continue CKPT's run on PLAN (TRAIN_NEXT), saves
#                          out/NAME-step<N>.checkpoint, log NAME.log (as `next` below)
#   fp.sh next CKPT        continue CKPT's run on the next plan (TRAIN_NEXT; traind-next.c built from
#                          the trainer that has it): run/next/plan-next-b16-windows.tsv and its shards
#                          run/next/shard-K-next.corpus, saves out/next-step<N>.checkpoint, log next.log;
#                          lr NLR (1e-4) after NWARM (5% of the plan's steps) of warmup, cosine to 0
#
# The run's setting (override in the environment): Muon at TRAIN_LR 3e-4
# (master's v3 manifest: lr 3e-4, Muon 0.95, weight decay 0.01, clip 1.0,
# tf32), warmup WARM (300 of the 8,803 steps), micro-batch 4 (the store at
# ctx 2048 is 1.77e9 floats at 4; 8 does not fit one array), a save every
# SAVE (500) steps and a validation every EVAL (250) on EVALW (128) of the
# shard's validation windows.
set -u
CU=/usr/local/cuda
CLANG=$(for c in clang-19 clang-18 clang-17 clang-16 clang-15 clang-14 clang; do command -v $c && break; done | head -1)
CC="$CLANG -DBEND_CUDA=1 -DBEND_NO_SRC -I$CU/include -L$CU/lib64 -std=c11 -O2"
export LD_LIBRARY_PATH=$CU/lib64:${LD_LIBRARY_PATH:-}
MEM=${MEM:-48GB}
PLAN=run/fp100m/plan-fp100m-b16-windows.tsv
TOK=weights/code32k.bpe
common="PLAN=$PLAN RUN_DIR=run/fp100m SHARD_SIZE=fp100m TOKENIZER_FILE=$TOK PRESET=fp100m TRAIN_BATCH=16 TRAIN_MICRO=${MICRO:-4} TRAIN_CHUNK=16 BEND_GEMM_NUMERICS=tf32"
setting="TRAIN_OPT=muon TRAIN_LR=${LR:-3e-4} TRAIN_WARMUP=${WARM:-300} TRAIN_WD=0.01 GRAD_CLIP=1.0"

build() {
  mkdir -p out
  for p in traind dense; do
    [ -x $p ] || $CC $p.c -lpthread -lm -o $p -lcuda -lnvrtc || exit 1
  done
  nvidia-smi --query-gpu=name,driver_version,power.limit,memory.total --format=csv,noheader
  nvidia-smi -q -d PERFORMANCE | grep -i -A3 "clocks event reasons\|slowdown" | head -20
  free -g | head -2
}

case "${1:-}" in
  build) build ;;
  gate)
    build
    echo "== G2: the dense program on the GPU against the tree trainer on the CPU (every gradient within 1e-5 relative)"
    BEND_PROFILE=1 ./dense --gpu $MEM 2>&1 | tee gate.log | tail -12
    awk '/gradient max/ { r = $(NF); gsub(/[()]/, "", r); k++; if (r + 0 > 1e-5) { print "gradient differs: " $0; bad = 1 } }
         END { if (k != 3) { print "expected 3 gradient checks, got " k; bad = 1 } exit bad }' gate.log && echo "G2: PASS" || echo "G2: MISS" ;;
  time)
    build
    STEPS=${2:-20}
    echo "== timing: $STEPS steps of fp100m at micro ${MICRO:-4}"
    nvidia-smi dmon -s pucm -d 2 > dmon.txt 2>&1 &
    DM=$!
    env $common $setting TRAIN_STEPS=$STEPS EVAL_WINDOWS=0 SAVE_EVERY=0 OUT=out/timing \
      stdbuf -oL ./traind --gpu $MEM 2>&1 | tee time.log | grep -v "^bend profile"
    kill $DM
    awk '/ step=[0-9]+\/.* ms=/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { split($i, a, "="); s = a[2] + 0 }
           n++; if (n > 2) { k++; ms += s } }
         END { if (k) printf "steady state: %.0f ms/step over %d steps = %.0f tok/s (16 x 2046 tokens a step); whole plan ~%.1f h\n", ms/k, k, 32736 / (ms/k/1000), 8803 * ms/k / 3.6e6 }' time.log
    echo "== dmon (power W, sm %, mem %)"; head -2 dmon.txt; grep -v "^#" dmon.txt | sort -k2 -n | tail -3
    rm -f out/timing-step*.checkpoint ;;
  run)
    build
    mkdir -p out
    nohup nvidia-smi dmon -s pucm -d 30 > dmon.txt 2>&1 &
    env $common $setting TRAIN_STEPS=${STEPS:-8803} EVAL_EVERY=${EVAL:-250} EVAL_WINDOWS=${EVALW:-128} SAVE_EVERY=${SAVE:-500} OUT=out/fp100m \
      nohup stdbuf -oL ./traind --gpu $MEM > train.log 2>&1 &
    echo "trainer pid $!; tail -f train.log" ;;
  next|again)
    # again CKPT PLAN RUN_DIR SHARD_SIZE NAME: continue CKPT's run on PLAN (TRAIN_NEXT),
    # saves out/NAME-step<N>.checkpoint, log NAME.log; next CKPT is the next plan
    [ -x traind-next ] || $CC traind-next.c -lpthread -lm -o traind-next -lcuda -lnvrtc || exit 1
    ckpt="${2:?usage: fp.sh next CKPT | fp.sh again CKPT PLAN RUN_DIR SHARD_SIZE NAME}"
    if [ "$1" = next ]; then plan=run/next/plan-next-b16-windows.tsv; rdir=run/next; ssz=next; name=next
    else plan="${3:?}"; rdir="${4:?}"; ssz="${5:?}"; name="${6:?}"; fi
    mkdir -p out
    # warmup: 5% of the plan's steps (at least 10) unless NWARM says otherwise
    nsteps=$(head -1 "$plan" | awk '{ print $3 }')
    NWARM=${NWARM:-$(( nsteps / 20 > 10 ? nsteps / 20 : 10 ))}
    env TRAIN_INIT=$ckpt TRAIN_NEXT=1 PLAN=$plan RUN_DIR=$rdir SHARD_SIZE=$ssz \
      TOKENIZER_FILE=$TOK TRAIN_BATCH=16 TRAIN_MICRO=${MICRO:-4} TRAIN_CHUNK=16 BEND_GEMM_NUMERICS=tf32 \
      TRAIN_LR=${NLR:-1e-4} TRAIN_WARMUP=$NWARM EVAL_EVERY=${EVAL:-250} EVAL_WINDOWS=${EVALW:-128} \
      SAVE_EVERY=${SAVE:-500} OUT=out/$name \
      nohup stdbuf -oL ./traind-next --gpu $MEM > $name.log 2>&1 &
    echo "trainer pid $!; tail -f $name.log" ;;
  eval)
    build
    shift
    for c in ${@:-out/*.checkpoint}; do
      echo "== $c"
      TRAIN_INIT=$c EVAL_CORPUS=${ECORPUS:-run/eval/transcript-fp.corpus} TOKENIZER_FILE=$TOK TRAIN_MICRO=${MICRO:-4} TRAIN_CHUNK=16 \
        BEND_GEMM_NUMERICS=tf32 ./traind --gpu $MEM 2>&1 | grep -v "^bend profile" | tail -3
    done ;;
  *) sed -n 2,30p "$0"; exit 2 ;;
esac
