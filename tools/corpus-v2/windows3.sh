#!/usr/bin/env bash
# UNWIRED 2026-10-14: run 3's transcript windows (done, run/v3/T); `bend-corpus-v2 windows` replaces it in Phase 4; kept for reference
exit 2
# windows3.sh (2026-10-07): run 3's transcript windows (bend-plan-windows):
# run 2's format-2 train transcripts without verify (run/v2/transcripts-nv,
# windows.sh's, at run 2's PER: bend 113, haskell 45, lean 25, agda 26, nix 5),
# and the synthetic chains (run/v3/chains/LANG, Transcript.bend `chain.`:
# ana's rejected Terms, the checker's answers, the fix) as a language each,
# LANG-chain, at PER = its count / 2,500 (run 2's unit), so every language
# runs dry together and every shard holds chains. Its holdout links are its
# language's, so the held-out units' files stay out. CHAIN_EVERY=k keeps every
# k-th chain (1: all).
#
# A chain language's filler: the chains' windows need a gap file each too, and
# format 2's filler alone (205,385 files) ran 5 of 92 shards dry. So Haskell's
# and Lean's chains bring raw code the steady mix (raw3.sh, run/v3/R/mix.jsonl)
# leaves out, beyond their caps: FILL_HASKELL (60,000) files of The Stack's
# Haskell and FILL_LEAN (30,000) of run 2's GitHub Lean, fixed samples, as
# (id, text) pairs. They passed `bend-corpus-v2 raw`'s dedup, holdout and
# vault, so no file is trained twice. The other chain languages' filler is empty.
#   run/v3/tx/{LANG,LANG-chain}, run/v3/T/shard-K-fp100m.corpus, run/v3/T/plan-fp100m-b16-windows.tsv
set -euo pipefail
cd /home/hhefesto/src/formalTransformer
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] windows3: $*"; }
nv=run/v2/transcripts-nv tx=run/v3/tx ch=run/v3/chains every=${CHAIN_EVERY:-1}
[ -s run/v3/R/mix.jsonl ] || { log "no run/v3/R/mix.jsonl: run raw3.sh first"; exit 1; }
# left SRC N DST: N of SRC's lines that run/v3/R/mix.jsonl has no id of, as (id, text)
# pairs (less the few whose text holds a NUL)
left() {
  awk 'function id(s) { return substr(s, 9, index(s, "\", \"text\": \"") - 9) }
       NR == FNR { seen[id($0)]; next } !(id($0) in seen)' run/v3/R/mix.jsonl "$1" |
    shuf -n "$2" --random-source=<(yes "windows3 filler $1" 2>/dev/null) |
    jq -j 'select(.text | contains("\u0000") | not) | .id, "\u0000", .text, "\u0000"' > "$3"
  log "$3: $(( $(tr -cd '\0' < "$3" | wc -c) / 2 )) filler files of $1 the steady mix leaves out"
}
specs="bend:113 haskell:45 lean:25 agda:26 nix:5"
for l in bend haskell lean agda nix; do
  mkdir -p "$tx/$l-chain"
  ln -sfn "$PWD/$nv/$l" "$tx/$l"
  [ -s "$ch/$l/transcripts.train.nul" ] || { log "no chains for $l ($ch/$l/transcripts.train.nul)"; exit 1; }
  awk -v RS='\0' -v ORS='\0' -v k="$every" 'NR % 2 == 1 { keep = (int((NR - 1) / 2) % k == 0) } keep' \
    "$ch/$l/transcripts.train.nul" > "$tx/$l-chain/transcripts.train.nul"
  case $l in
    haskell) left run/v2/raw-stack/haskell.jsonl "${FILL_HASKELL:-60000}" "$tx/$l-chain/files-hi.nul" ;;
    lean) left run/v2/raw/lean.jsonl "${FILL_LEAN:-30000}" "$tx/$l-chain/files-hi.nul" ;;
    *) : > "$tx/$l-chain/files-hi.nul" ;;
  esac
  : > "$tx/$l-chain/files-lo.nul"
  for f in results.holdout.nul transcripts.holdout.nul; do ln -sfn "$PWD/$nv/$l/$f" "$tx/$l-chain/$f"; done
  n=$(( $(tr -cd '\0' < "$tx/$l-chain/transcripts.train.nul" | wc -c) / 2 ))
  per=$(( (n + 1250) / 2500 )); [ "$per" -lt 1 ] && per=1
  specs="$specs $l-chain:$per"
  log "$l-chain: $n chains (every ${every}th), PER $per"
done
log "plan-windows run/v3/T fp100m 16 $specs"
OUT=$tx SHARD=${SHARD:-8000} JOBS=${JOBS:-6} TOKENIZER=weights/code32k.bpe \
  ${DEPLOY:-nix run .#deploy --} plan-windows run/v3/T fp100m 16 $specs
log done
