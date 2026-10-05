#!/usr/bin/env bash
# Raw code for the chain when no new transcripts are ready (the user,
# 2026-10-02: "Feed it raw code when nothing new is available"). From the
# repository root:
#   bend/gpu/raw-stage.sh mix                  split run/code-train-v3.jsonl by language and interleave it
#   bend/gpu/raw-stage.sh build K              slice K (~SLICE bytes of the mix) as shards and a plan in run/rawK
#   bend/gpu/raw-stage.sh push K HOST PORT     to the box as run/rawK (plan last, after every shard's sha)
# then append to the chain's stages:  rawK traind-next 0 run/rawK/plan-rawK-b16-windows.tsv run/rawK rawK
#
# New raw code (code ana has not been fed, run/raw-new/LANG*.jsonl from the
# 2026-10-03 agents, deduplicated against code-train-v3) goes through the same
# steps under another mix and prefix (R the mix's directory, P the stages' prefix):
#   R=run/rawnew1 bend/gpu/raw-stage.sh mixnew FILE.jsonl...   the files interleaved by language
#   R=run/rawnew1 P=nr bend/gpu/raw-stage.sh build K           slice K as run/nrK
#   P=nr bend/gpu/raw-stage.sh push K HOST PORT                stage nrK
#
# The mix: ana's five languages from the extracted code (Haskell .hs/.lhs,
# Lean, Agda .agda/.lagda, Nix, Bend; Idris and Markdown left out), PER
# documents a round in proportion to their counts, so they run dry together;
# and fp100m's transcripts (run/transcripts-final/LANG/transcripts.train.nul,
# as JSONL in run/raw/src/tr-LANG.jsonl) cycling at about 20% of the bytes, so hours of raw
# code keep the turn format in view. Documents are packed to 128 KB before
# tokenizing (PACK_TARGET), since the trainer makes no window from a shorter
# document. SIZE fp100m (ctx 2048), batch 16.
set -euo pipefail
R=${R:-run/raw}
P=${P:-raw}
SLICE=${SLICE:-300000000}
CV2=${CV2:-nix run .#deploy -- corpus-v2}

mix() {
  mkdir -p "$R/src"
  $CV2 split-lang run/code-train-v3.jsonl "$R/src"
  # fp100m's transcripts as JSONL, for the replay
  for l in haskell lean agda nix bend; do
    $CV2 nul-jsonl "run/transcripts-final/$l/transcripts.train.nul" "$R/src/tr-$l.jsonl"
  done
  hs=$(wc -l < "$R/src/haskell.jsonl"); le=$(wc -l < "$R/src/lean.jsonl"); ag=$(wc -l < "$R/src/agda.jsonl"); nx=$(wc -l < "$R/src/nix.jsonl"); be=$(wc -l < "$R/src/bend.jsonl")
  per() { $CV2 per "$1" "$hs"; }
  # transcripts: about 20% of the bytes; code documents average ~7 KB, transcripts ~1.2 KB
  nix run .#deploy -- mix "$R/mix.jsonl" \
    "$R/src/haskell.jsonl:100" "$R/src/lean.jsonl:$(per $le)" "$R/src/agda.jsonl:$(per $ag)" "$R/src/nix.jsonl:$(per $nx)" "$R/src/bend.jsonl:$(per $be)" \
    "$R/src/tr-haskell.jsonl:41:cycle" "$R/src/tr-lean.jsonl:26:cycle" "$R/src/tr-agda.jsonl:28:cycle" \
    "$R/src/tr-nix.jsonl:13:cycle" "$R/src/tr-bend.jsonl:67:cycle"
  ls -la "$R/mix.jsonl"
}

# mixnew FILE...: each file's language from its name (haskell*, lean*, agda*,
# bend*), per round documents in proportion to each language's count so they run
# dry together, and fp100m's transcripts cycling at ~20% of the bytes as in mix
mixnew() {
  mkdir -p "$R/src"
  # fp100m's transcripts as JSONL, for the replay (as in mix)
  for l in haskell lean agda nix bend; do
    $CV2 nul-jsonl "run/transcripts-final/$l/transcripts.train.nul" "$R/src/tr-$l.jsonl"
  done
  specs=$($CV2 specs-mixnew "$R/src" "$@")
  echo "per round: $specs"
  nix run .#deploy -- mix "$R/mix.jsonl" $specs
  ls -la "$R/mix.jsonl"
}

build() {
  k="${1:?usage: raw-stage.sh build K}"
  d="run/$P$k"; mkdir -p "$d"
  # slice k: the k-th SLICE bytes of the mix, cut at line ends; the mix's
  # final short part can be too small for one window (plan-segment refuses
  # it), so the last slice keeps whole 2000-document parts only
  $CV2 slice "$R/mix.jsonl" "$d/slice.jsonl" "$k" "$SLICE"
  [ -s "$d/slice.jsonl" ] || { echo "slice $k is empty"; exit 1; }
  TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 JOBS=${JOBS:-3} nix run .#deploy -- plan-corpus "$d/slice.jsonl" "$d" fp100m 16 2000
  cp "$d"/plan-fp100m-b16-s2000.tsv "$d/plan-fp100m-b16-windows.tsv"
  head -1 "$d/plan-fp100m-b16-windows.tsv" | cut -c1-160
  rm -f "$d/slice.jsonl"
}

push() {
  k="${1:?usage: raw-stage.sh push K HOST PORT}"
  NAME="$P$k" RUN="run/$P$k" EVALC=run/eval/transcript-next.corpus bend/gpu/next-stage.sh push "$2" "$3"
}

case "${1:-}" in
  mix) mix ;;
  mixnew) shift; mixnew "$@" ;;
  build) shift; build "$@" ;;
  push) shift; push "$@" ;;
  *) sed -n 2,20p "$0"; exit 2 ;;
esac
