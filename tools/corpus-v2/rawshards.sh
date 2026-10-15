#!/usr/bin/env bash
# UNWIRED 2026-10-15: `build K` is replaced by `bend-corpus-v2 raw-build K` (bend/CorpusV2/Recipes.bend, the plan's Phase 4); `mix` was unwired 2026-10-14 for steady-mix; kept for reference
exit 2
# rawshards.sh: `bend-corpus-v2 raw`'s pool as raw-code shards for corpus v2's one mix (docs/CORPUS-V2.md, C5).
#   tools/corpus-v2/rawshards.sh mix        (UNWIRED 2026-10-14: exits 2; steady-mix.sh) the languages interleaved by tokens (Haskell 35 :
#                                            Lean 25 : Agda 15; the few raw Bend and Nix files
#                                            spread through it): run/v2/R/mix.jsonl
#   tools/corpus-v2/rawshards.sh build K    slice K (SLICE bytes, 300 MB) as packed shards and
#                                            a plan: run/v2/R/K/ (plan-corpus, 2,000 documents a
#                                            shard, packed to 128 KB, as run 1's raw stages)
# `bend-corpus-v2 combine` then interleaves these shards with the transcript windows' (run/v2/T).
set -euo pipefail
R=${R:-run/v2/R}; SLICE=${SLICE:-300000000}
CV2=${CV2:-nix run .#deploy -- corpus-v2}
case "${1:-}" in
  # UNWIRED 2026-10-14: `mix` (run 2's per-round mix) is superseded by steady-mix.sh (run 3's steady
  # mix; `bend-corpus-v2 steady-mix` in the plan's Phase 4), so `rawshards.sh mix` now exits 2 with
  # the usage; the branch is kept below, commented out, for reference.
  # mix)
  #   mkdir -p "$R"
  #   # documents a round ∝ token share / mean document size (Haskell 4.2 KB, Lean 7.2, Agda 6.9);
  #   # the raw added since (2026-10-05, `bend-corpus-v2 raw`'s output dirs run/v2/raw-*: the Lean
  #   # proof sets STP and NuminaMath-LEAN, The Stack v1) ∝ each file's document count against
  #   # run/v2/raw's Haskell, so every one runs through the whole mix
  #   hs=$(wc -l < run/v2/raw/haskell.jsonl); extra=()
  #   for f in run/v2/raw-*/*.jsonl; do [ -s "$f" ] || continue
  #     w=$(( 84 * $(wc -l < "$f") / hs )); extra+=("$f:$(( w > 0 ? w : 1 ))"); done
  #   echo "mix: added ${extra[*]:-none}"
  #   nix run .#deploy -- mix "$R/mix.jsonl" run/v2/raw/haskell.jsonl:84 run/v2/raw/lean.jsonl:35 run/v2/raw/agda.jsonl:22 \
  #     run/v2/raw/bend.jsonl:1 run/v2/raw/nix.jsonl:1 "${extra[@]}"
  #   ls -la "$R/mix.jsonl" ;;
  build)
    k="${2:?usage: rawshards.sh build K}"; d="$R/$k"; mkdir -p "$d"
    $CV2 slice "$R/mix.jsonl" "$d/slice.jsonl" "$k" "$SLICE"
    [ -s "$d/slice.jsonl" ] || { echo "slice $k is empty"; exit 1; }
    TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 JOBS=${JOBS:-3} nix run .#deploy -- plan-corpus "$d/slice.jsonl" "$d" fp100m 16 2000
    rm -f "$d/slice.jsonl"
    head -1 "$d/plan-fp100m-b16-s2000.tsv" | cut -c1-160 ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
