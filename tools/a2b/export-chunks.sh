#!/bin/sh
# Export the agda-categories modules chunk by chunk (run/a2b/everything/Chunk[A-Z].agda) into
# run/a2b/export2 (ops): one agda-export process per chunk, each capped, skipping modules
# already written.  usage: tools/a2b/export-chunks.sh
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R/run/a2b/everything" || exit 1
for f in Chunk[A-Z].agda; do
  echo "== $f $(date)"
  systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=2G "$R/run/a2b/gcroot-agda-export/bin/agda-export" --export-dir=../export2 --export-skip-existing $f +RTS -M14g -RTS 2>&1 | tail -2
done
echo "== done $(date)"
