#!/usr/bin/env bash
# windows3.sh (2026-10-07): run 3's transcript windows (bend-plan-windows):
# run 2's format-2 train transcripts without verify (run/v2/transcripts-nv,
# windows.sh's, at run 2's PER: bend 113, haskell 45, lean 25, agda 26, nix 5),
# and the synthetic chains (run/v3/chains/LANG, Transcript.bend `chain.`:
# ana's rejected Terms, the checker's answers, the fix) as a language each,
# LANG-chain, at PER = its count / 2,500 (run 2's unit), so every language
# runs dry together and every shard holds chains. A chain language's filler
# is empty (the format-2 languages' filler fills every window's gap, once);
# its holdout links are its language's, so the held-out units' files stay
# out. CHAIN_EVERY=k keeps every k-th chain (1: all).
#   run/v3/tx/{LANG,LANG-chain}, run/v3/T/shard-K-fp100m.corpus, run/v3/T/plan-fp100m-b16-windows.tsv
set -euo pipefail
cd /home/hhefesto/src/formalTransformer
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] windows3: $*"; }
nv=run/v2/transcripts-nv tx=run/v3/tx ch=run/v3/chains every=${CHAIN_EVERY:-1}
specs="bend:113 haskell:45 lean:25 agda:26 nix:5"
for l in bend haskell lean agda nix; do
  mkdir -p "$tx/$l-chain"
  ln -sfn "$PWD/$nv/$l" "$tx/$l"
  [ -s "$ch/$l/transcripts.train.nul" ] || { log "no chains for $l ($ch/$l/transcripts.train.nul)"; exit 1; }
  awk -v RS='\0' -v ORS='\0' -v k="$every" 'NR % 2 == 1 { keep = (int((NR - 1) / 2) % k == 0) } keep' \
    "$ch/$l/transcripts.train.nul" > "$tx/$l-chain/transcripts.train.nul"
  : > "$tx/$l-chain/files-hi.nul"; : > "$tx/$l-chain/files-lo.nul"
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
