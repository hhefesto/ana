#!/usr/bin/env bash
# rawshards.sh: raw.py's pool as raw-code shards for corpus v2's one mix (docs/CORPUS-V2.md, C5).
#   tools/corpus-v2/rawshards.sh mix        the languages interleaved by tokens (Haskell 35 :
#                                            Lean 25 : Agda 15; the few raw Bend and Nix files
#                                            spread through it): run/v2/R/mix.jsonl
#   tools/corpus-v2/rawshards.sh build K    slice K (SLICE bytes, 300 MB) as packed shards and
#                                            a plan: run/v2/R/K/ (plan-corpus, 2,000 documents a
#                                            shard, packed to 128 KB, as run 1's raw stages)
# combine.py then interleaves these shards with the transcript windows' (run/v2/T).
set -euo pipefail
R=run/v2/R; SLICE=${SLICE:-300000000}
case "${1:-}" in
  mix)
    mkdir -p "$R"
    # documents a round ∝ token share / mean document size (Haskell 4.2 KB, Lean 7.2, Agda 6.9)
    nix run .#deploy -- mix "$R/mix.jsonl" run/v2/raw/haskell.jsonl:84 run/v2/raw/lean.jsonl:35 run/v2/raw/agda.jsonl:22 \
      run/v2/raw/bend.jsonl:1 run/v2/raw/nix.jsonl:1
    ls -la "$R/mix.jsonl" ;;
  build)
    k="${2:?usage: rawshards.sh build K}"; d="$R/$k"; mkdir -p "$d"
    python3 - "$R/mix.jsonl" "$d/slice.jsonl" "$k" "$SLICE" <<'PY'
import sys
src, dst, k, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
lo, hi = (k - 1) * size, k * size
pos = 0; lines = []
with open(src, "rb") as f:
    for line in f:
        if pos >= lo and pos < hi: lines.append(line)
        pos += len(line)
        if pos >= hi: break
    last = pos < hi
# whole 2,000-document parts only at the mix's end (plan-segment refuses a part too short for a window)
if last and len(lines) % 2000: lines = lines[:len(lines) - len(lines) % 2000]
with open(dst, "wb") as o: o.writelines(lines)
print("slice", k, len(lines), "documents", "(the last)" if last else "")
PY
    [ -s "$d/slice.jsonl" ] || { echo "slice $k is empty"; exit 1; }
    TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 JOBS=${JOBS:-3} nix run .#deploy -- plan-corpus "$d/slice.jsonl" "$d" fp100m 16 2000
    rm -f "$d/slice.jsonl"
    head -1 "$d/plan-fp100m-b16-s2000.tsv" | cut -c1-160 ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
