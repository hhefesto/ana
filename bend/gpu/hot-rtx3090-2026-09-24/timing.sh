#!/usr/bin/env bash
# after evalwatch is done: 20 cold steps of bpe100m-v3 (the G3 setting) with
# the run binary, then with the timestamped one
cd /root/hot
until grep -q finished eval-bend.txt; do sleep 20; done
export LD_LIBRARY_PATH=/usr/local/cuda/lib64
for b in traind traind-ts; do
  BEND_GEMM_NUMERICS=tf32 CORPUS=corpus.txt TOKENIZER_FILE=tok.bpe PRESET=bpe100m-v3 TRAIN_STEPS=20 TRAIN_BATCH=64 TRAIN_MICRO=32 \
    TRAIN_OPT=muon TRAIN_LR=3e-4 TRAIN_WARMUP=100 EVAL_WINDOWS=0 OUT= ./$b --gpu 48GB > g3-$b.log 2>&1
done
{ echo "== traind (the run binary)"; awk "/^step [0-9]+ loss/ && \$2 > 2 { n++; ms += \$NF } END { if (n) printf \"%.0f ms/step over %d steps\n\", ms/n, n }" g3-traind.log
  echo "== traind-ts"; awk "/ step=[0-9]+\/20 / { for (i=1;i<=NF;i++) if (\$i ~ /^ms=/) { split(\$i,a,\"=\"); s=a[2] } ; split(\$4,st,\"[=/]\"); if (st[2]+0 > 2) { n++; ms += s } } END { if (n) printf \"%.0f ms/step over %d steps\n\", ms/n, n }" g3-traind-ts.log
  tail -2 g3-traind-ts.log | cut -c1-200; } > timing.txt 2>&1
