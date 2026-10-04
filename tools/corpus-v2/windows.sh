#!/usr/bin/env bash
# windows.sh: format 2's train transcripts as transcript windows (bend-plan-windows):
# every language's transcripts interleaved by count (each round PER of each, so they
# run dry together), packed whole into 2,046-token windows, each window's gap the
# end of a filler file (filler.py's), shards of SHARD (8,000) transcripts.
#   run/v2/T/shard-K-fp100m.corpus, run/v2/T/plan-fp100m-b16-windows.tsv
set -euo pipefail
OUT=run/v2/transcripts SHARD=${SHARD:-8000} JOBS=${JOBS:-6} TOKENIZER=weights/code32k.bpe \
  nix run .#deploy -- plan-windows run/v2/T fp100m 16 bend:120 haskell:46 lean:26 agda:27 nix:10
