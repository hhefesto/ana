#!/usr/bin/env bash
# windows.sh: format 2's train transcripts as transcript windows (bend-plan-windows):
# every language's transcripts interleaved by count (each round PER of each, so they
# run dry together), packed whole into 2,046-token windows, each window's gap the
# end of a filler file (`bend-corpus-v2 filler`'s), shards of SHARD (8,000) transcripts.
#   run/v2/T/shard-K-fp100m.corpus, run/v2/T/plan-fp100m-b16-windows.tsv
# Without the verify shape (docs/AGENT.md, 2026-10-05): its target is the checker's own
# turn, which ana is never trained to write (TRAIN_MASK=kinds weighs a tool's echo 0), so
# a verify transcript would train only its given turns. run/v2/transcripts-nv/LANG holds
# each language's train transcripts without them (ids ending /verify) and links to the rest.
set -euo pipefail
src=run/v2/transcripts nv=run/v2/transcripts-nv
for l in bend haskell lean agda nix; do
  mkdir -p "$nv/$l"
  for f in files-hi.nul files-lo.nul results.holdout.nul transcripts.holdout.nul; do ln -sfn "$PWD/$src/$l/$f" "$nv/$l/$f"; done
  [ -s "$nv/$l/transcripts.train.nul" ] || LC_ALL=C awk 'BEGIN { RS = "\0"; ORS = "\0" } NR % 2 == 1 { id = $0; next } id !~ /\/verify$/ { print id; print $0 }' \
    "$src/$l/transcripts.train.nul" > "$nv/$l/transcripts.train.nul"
done
# PER ∝ each language's count (bend 283,924, haskell 112,213, lean 63,984, agda 65,689, nix 12,444)
OUT=$nv SHARD=${SHARD:-8000} JOBS=${JOBS:-6} TOKENIZER=weights/code32k.bpe \
  nix run .#deploy -- plan-windows run/v2/T fp100m 16 bend:113 haskell:45 lean:25 agda:26 nix:5
