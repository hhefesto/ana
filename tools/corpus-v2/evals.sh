#!/usr/bin/env bash
# evals.sh: corpus v2's bits-per-byte eval corpora (docs/CORPUS-V2.md, E3), packed to 128 KB and
# tokenized as the waves' were (deploy pack, deploy prepare), for `fp.sh eval` (ECORPUS):
#   run/eval/v2-tr-LANG.corpus, run/eval/v2-tr.corpus   format 2's held-out transcripts (`bend-corpus-v2 pool`'s
#                                                        repository holdout, render.sh's)
#   run/eval/v2-vault-LANG.corpus                       the vault's raw files (no run-1 stream holds
#                                                        them): up to 5 a repository, ~2 MB a language
set -euo pipefail
W=run/v2/evals; mkdir -p "$W"
CV2=${CV2:-nix run .#deploy -- corpus-v2}
corpus() {   # NAME NUL
  nix run .#deploy -- pack "$2" "$W/$1.packed.nul" --target 131072 --prefix "$1" --stats
  nix run .#deploy -- prepare weights/code32k.bpe "$W/$1.packed.nul" "run/eval/$1.corpus"
}
: > "$W/v2-tr.nul"
for l in haskell agda lean nix bend; do
  corpus "v2-tr-$l" "run/v2/transcripts/$l/transcripts.holdout.nul"
  cat "run/v2/transcripts/$l/transcripts.holdout.nul" >> "$W/v2-tr.nul"
done
corpus v2-tr "$W/v2-tr.nul"
for l in haskell agda lean; do
  # the vault's files in sha256("corpus-v2 vault eval\0" + id) order, up to 5 a
  # repository and none past 100,000 characters, until 2,000,000 characters
  $CV2 vault-sample "run/v2/vault/$l.jsonl" "$W/vault-$l.nul"
  corpus "v2-vault-$l" "$W/vault-$l.nul"
done
ls -la run/eval/v2-*.corpus
