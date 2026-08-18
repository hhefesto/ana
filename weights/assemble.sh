#!/usr/bin/env bash
# Reassemble the vendored checkpoint parts into run/, where ana
# discovers checkpoints, and verify the whole-file SHA-256 from SHA256SUMS.
# GitHub rejects files over 100 MB, hence the split.
#
# Never destructive: the parts are joined into a temporary file and verified
# *before* anything is published to run/.  A destination that already holds
# these exact bytes is reported and left alone; one holding different bytes is
# refused unless FORCE=1, because the only copy of a multi-day training run can
# be sitting at that path.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../run
dest=../run/wiki-bpe10m-global.checkpoint
expected="$(awk '$2 == "wiki-bpe10m-global.checkpoint" {print $1}' SHA256SUMS)"

tmp="$(mktemp ../run/.assemble-XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cat wiki-bpe10m-global.checkpoint.part-* > "$tmp"
actual="$(sha256sum "$tmp" | awk '{print $1}')"
if [ "$expected" != "$actual" ]; then
  echo "checksum mismatch: expected $expected got $actual" >&2
  exit 1
fi

if [ -e "$dest" ]; then
  current="$(sha256sum "$dest" | awk '{print $1}')"
  if [ "$current" = "$expected" ]; then
    echo "run/wiki-bpe10m-global.checkpoint already holds these weights ($expected)"
    exit 0
  fi
  if [ "${FORCE:-0}" != 1 ]; then
    echo "refusing to overwrite $dest" >&2
    echo "  it currently holds $current" >&2
    echo "  the vendored weights are $expected" >&2
    echo "  move the existing file aside, or re-run with FORCE=1" >&2
    exit 1
  fi
  chmod u+w "$dest"
fi

mv "$tmp" "$dest"
trap - EXIT
echo "assembled run/wiki-bpe10m-global.checkpoint ($actual)"
echo "generate with: nix run .#ana"
