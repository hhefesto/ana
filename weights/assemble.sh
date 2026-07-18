#!/usr/bin/env bash
# Reassemble the vendored checkpoint parts into run/, where wiki-generate
# discovers checkpoints, and verify the whole-file SHA-256 from SHA256SUMS.
# GitHub rejects files over 100 MB, hence the split.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../run
cat wiki-bpe10m-global.checkpoint.part-* > ../run/wiki-bpe10m-global.checkpoint
expected="$(awk '$2 == "wiki-bpe10m-global.checkpoint" {print $1}' SHA256SUMS)"
actual="$(sha256sum ../run/wiki-bpe10m-global.checkpoint | awk '{print $1}')"
if [ "$expected" != "$actual" ]; then
  echo "checksum mismatch: expected $expected got $actual" >&2
  exit 1
fi
echo "assembled run/wiki-bpe10m-global.checkpoint ($actual)"
echo "generate with: TOKENIZER_FILE=weights/enwiki-8k.bpe nix run .#wiki-generate"
