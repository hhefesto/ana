#!/usr/bin/env bash
# speed.sh: the dense trainer's step time on a GPU box, before and after the
# speed work of 2026-11-18 (the user: "Work on speed without renting, fix
# the slowest parts in bend ... After fixing, you can rent for 30 minutes
# and confirm your fix really works"). A thin shim: the trainers are Bend
# (TrainDense.bend, as C), the census of what a step runs is bend-perf.
#
# Expects, in the working directory:
#   traind-old.c traind-new.c dense-new.c   bend X.bend -o X.c (old: the trainer before)
#   weights/code32k.bpe
#   run/v9/R9/plan-fp100m-b16-windows.tsv run/v9/R9/shard-0-fp100m.corpus
#
#   speed.sh build [NAME ...]   the binaries (traind-old traind-new dense-new), in parallel
#   speed.sh gate               tests/dense.bend on the GPU: the dense program's
#                               gradients (GPU) against the tree trainer's (CPU), 1e-5
#   speed.sh time NAME BIN N [VAR=VALUE ...]
#                               N steps of run 9's setting from fresh parameters
#                               (the plan's first windows), log NAME.log, dmon NAME.dmon;
#                               the steady state skips the first two steps
#   speed.sh prof BIN N [VAR=VALUE ...]
#                               N steps with BEND_PROFILE=2 (each op timed alone):
#                               prof.log, and the ops by total time in prof.top
set -u
CU=/usr/local/cuda
CLANG=$(for c in clang-19 clang-20 clang-18 clang; do command -v $c && break; done | head -1)
CC="$CLANG -DBEND_CUDA=1 -I$CU/include -L$CU/lib64 -std=c11 -O2"
export LD_LIBRARY_PATH=$CU/lib64:${LD_LIBRARY_PATH:-}
MEM=${MEM:-48GB}
run9="PLAN=run/v9/R9/plan-fp100m-b16-windows.tsv RUN_DIR=run/v9/R9 SHARD_SIZE=fp100m TOKENIZER_FILE=weights/code32k.bpe
  PRESET=fp100m TRAIN_BATCH=16 TRAIN_MICRO=4 TRAIN_CHUNK=16 BEND_GEMM_NUMERICS=tf32 TRAIN_MASK=kinds
  TRAIN_OPT=muon TRAIN_LR=3e-4 TRAIN_WARMUP=300 TRAIN_WD=0.01 GRAD_CLIP=1.0 EVAL_WINDOWS=0 SAVE_EVERY=0 OUT=out/timing"

steady() {
  awk '/ step=[0-9]+\/.* ms=/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { split($i, a, "="); s = a[2] + 0 }
         n++; if (n > 2) { k++; ms += s } }
       END { if (k) printf "%s: steady state %.0f ms/step over %d steps = %.0f tok/s\n", FILENAME, ms/k, k, 32736 / (ms/k/1000) }' "$1"
}

case "${1:-}" in
  build)
    shift
    mkdir -p out
    for p in ${@:-traind-old traind-new dense-new}; do
      ( $CC $p.c -lpthread -lm -o $p -lcuda -lnvrtc > $p.build 2>&1; echo "rc=$?" >> $p.build ) &
    done
    wait
    tail -n 1 *.build
    nvidia-smi --query-gpu=name,driver_version,power.limit,memory.total --format=csv,noheader ;;
  gate)
    BEND_PROFILE=1 ./dense-new +RTS --gpu $MEM -RTS 2>&1 | tee gate.log | tail -14
    awk '/gradient max/ { r = $(NF); gsub(/[()]/, "", r); k++; if (r + 0 > 1e-5) { print "gradient differs: " $0; bad = 1 } }
         END { if (k != 4) { print "expected 4 gradient checks (3 plain, 1 masked), got " k; bad = 1 } exit bad }' gate.log \
      && echo "gate: PASS" || echo "gate: FAIL" ;;
  time)
    name=$2 bin=$3 n=$4; shift 4
    nvidia-smi dmon -s pucm -d 2 > $name.dmon 2>&1 &
    dm=$!
    env $run9 "$@" TRAIN_STEPS=$n stdbuf -oL ./$bin +RTS --gpu $MEM -RTS > $name.log 2>&1
    kill $dm
    steady $name.log
    grep -v "^#" $name.dmon | awk '$5 > 0 { n++; sm += $5; mem += $6; w += $2 } END { if (n) printf "%s: SM %.0f%%, memory %.0f%%, %.0f W over %d samples\n", FILENAME, sm/n, mem/n, w/n, n }' FILENAME=$name.dmon ;;
  prof)
    bin=$2 n=$3; shift 3
    env $run9 "$@" TRAIN_STEPS=$n BEND_PROFILE=2 stdbuf -oL ./$bin +RTS --gpu $MEM -RTS > prof.log 2>&1
    # one line an op: "bend profile: gemm cublas MxNxK xB T ms ..." or "bend profile: einsum kernel|loop|seq T ms SPEC"
    awk '/^bend profile: gemm (cublas|loop) / { k = "gemm " $4 " " $5 " " $6; t[k] += $7; c[k]++ }
         /^bend profile: einsum (kernel|loop|seq|seq-declined) / { k = "einsum " $4 " " substr($0, index($0, " ms ") + 4, 60); t[k] += $5; c[k]++ }
         END { for (k in t) { printf "%10.1f ms %6d  %s\n", t[k], c[k], k; s += t[k] } printf "%10.1f ms total\n", s }' prof.log | sort -rn > prof.top
    head -45 prof.top ;;
  *) sed -n 2,26p "$0"; exit 2 ;;
esac
