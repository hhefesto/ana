#!/usr/bin/env bash
# render.sh: `bend-corpus-v2 pool`'s units as format 2 transcripts (bend-transcript, TRANSCRIPT_FORMAT=2),
# COPIES presentations a unit (Bend 4, the rest 2: the presentations replace run 1's four
# identical Bend copies), each language's train and holdout cut into shards rendered in
# parallel, then joined in order:
#   run/v2/transcripts/LANG/transcripts.{train,holdout}.nul   (the layout bend-plan-windows reads)
# Run from the repository root; the binary is run/v2/gcroot-bend-transcript (nix build .#bend-transcript).
set -euo pipefail
T=run/v2/gcroot-bend-transcript/bin/bend-transcript
CV2=${CV2:-nix run .#deploy -- corpus-v2}
W=run/v2/render; O=run/v2/transcripts; mkdir -p "$W"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] render: $*"; }
copies() { [ "$1" = bend ] && echo 4 || echo 2; }
shards() { case "$1" in bend) echo 8;; haskell|lean|agda) echo 3;; *) echo 1;; esac; }
pids=()
for l in bend haskell lean agda nix; do
  for part in train holdout; do
    n=$(shards $l); [ $part = holdout ] && n=1
    $CV2 split-nul "run/v2/results/$l.$part.nul" "$W/$l.$part" "$n" > /dev/null
    for s in $(seq 0 $((n - 1))); do
      TRANSCRIPT_FORMAT=2 COPIES=$(copies $l) "$T" weights/code32k.bpe "$W/$l.$part.$s.in.nul" "$W/$l.$part.$s.out.nul" > "$W/$l.$part.$s.log" 2>&1 &
      pids+=($!)
    done
  done
done
log "${#pids[@]} renders started"
for p in "${pids[@]}"; do wait "$p" || { log "a render failed"; exit 1; }; done
for l in bend haskell lean agda nix; do
  mkdir -p "$O/$l"
  for part in train holdout; do
    cat $(ls "$W/$l.$part".*.out.nul | sort -t. -k3,3n) > "$O/$l/transcripts.$part.nul"
    log "$l $part: $(cat "$W/$l.$part".*.log | awk '{u += $2; t += $5} END {print u " units, " t " transcripts"}')"
  done
done
log done
