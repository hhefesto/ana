#!/usr/bin/env bash
# build-code-evals.sh — per-language evaluation corpora from held-out repositories.
#
# The sources here were held out WHOLE by extract-code.sh, chosen by a hash of
# the package or repository name. That matters: the trainer's own
# train/validation split is a hash of document position, and code vendors
# heavily, so a position-based split puts the same file on both sides. Nothing
# in these corpora comes from a package the model trained on.
#
# Corpora are packed exactly as the training corpus is, because bpb has to be
# measured on the distribution the model actually sees. Unpacked, short files
# yield no window at all and the population silently becomes "long files only".
#
# Usage: deploy/build-code-evals.sh TOKENIZER.bpe OUT_DIR [EVAL.jsonl]
set -euo pipefail

TOKENIZER="${1:?usage: build-code-evals.sh TOKENIZER.bpe OUT_DIR [EVAL.jsonl]}"
OUT_DIR="${2:?missing OUT_DIR}"
EVAL="${3:-run/code-eval.jsonl}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
CLI="${CLI:-$(nix build --no-link --print-out-paths .#formal-transformer)/bin/formal-transformer}"
PACK_TARGET="${PACK_TARGET:-131072}"

test -f "$TOKENIZER" || { echo "build-code-evals: no such tokenizer: $TOKENIZER" >&2; exit 1; }
test -f "$EVAL" || { echo "build-code-evals: no such holdout: $EVAL" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Extension groups, not individual extensions: literate variants are the same
# language and would otherwise make populations too small to measure with.
languages="haskell:\\.(hs|lhs)$ nix:\\.nix$ agda:\\.(agda|lagda)$ lean:\\.lean$ idris:\\.(idr|ipkg)$"

for entry in $languages; do
  name="${entry%%:*}"
  pattern="${entry#*:}"
  corpus="$OUT_DIR/code-$name.corpus"
  documents=$(jq -c --arg p "$pattern" 'select(.id | test($p))' < "$EVAL" | tee "$OUT_DIR/.$name.jsonl" | wc -l)
  if [ "$documents" -eq 0 ]; then
    echo "build-code-evals: $name -- no held-out documents, skipped" >&2
    rm -f "$OUT_DIR/.$name.jsonl"
    continue
  fi
  # --group keeps a packed document inside one repository, so a window never
  # spans two unrelated projects.
  prepared="$(jq --raw-output0 '.id, (.text | explode | map(select(. != 0)) | implode)' \
      < "$OUT_DIR/.$name.jsonl" \
    | "$CLI" pack-stdin --target "$PACK_TARGET" --prefix "eval-$name" --group \
    | "$CLI" prepare-bpe-stdin "$TOKENIZER" "$corpus")"
  rm -f "$OUT_DIR/.$name.jsonl"
  if [ ! -f "$corpus" ]; then
    echo "build-code-evals: $name failed to prepare" >&2
    echo "  $prepared" >&2
    exit 1
  fi
  tokens=$("$CLI" inspect-corpus "$corpus" | sed -n 's/^ordinary tokens: //p')
  printf 'build-code-evals: %-8s %6d held-out files -> %9s tokens  %s\n' \
    "$name" "$documents" "$tokens" "$corpus" >&2
done

echo "build-code-evals: wrote $(ls "$OUT_DIR"/code-*.corpus 2>/dev/null | wc -l) corpora to $OUT_DIR" >&2
