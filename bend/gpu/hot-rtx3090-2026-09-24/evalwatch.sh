#!/usr/bin/env bash
# score every saved checkpoint on the enwik8 test split, once, after its save completed
cd /root/hot
while true; do
  for c in $(ls out/*.checkpoint 2>/dev/null | sort -V); do
    n=$(basename $c .checkpoint | sed "s/.*step//")
    grep -q "saved $c" train.log || continue
    grep -q "^step $n " eval-bend.txt 2>/dev/null && continue
    r=$(BEND_GEMM_NUMERICS=tf32 TRAIN_INIT=$c TOKENIZER_FILE=tok.bpe EVAL_CORPUS=enwik8.corpus TRAIN_MICRO=32 ./traind-ev --gpu 32GB 2>&1 | grep bits_per_byte)
    echo "step $n $r" >> eval-bend.txt
  done
  pgrep -x traind > /dev/null || { echo finished >> eval-bend.txt; exit 0; }
  sleep 60
done
