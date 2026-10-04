#!/usr/bin/env bash
# render.sh: pool.py's units as format 2 transcripts (bend-transcript, TRANSCRIPT_FORMAT=2),
# COPIES presentations a unit (Bend 4, the rest 2: the presentations replace run 1's four
# identical Bend copies), each language's train and holdout cut into shards rendered in
# parallel, then joined in order:
#   run/v2/transcripts/LANG/transcripts.{train,holdout}.nul   (the layout bend-plan-windows reads)
# Run from the repository root; the binary is run/v2/gcroot-bend-transcript (nix build .#bend-transcript).
set -euo pipefail
T=run/v2/gcroot-bend-transcript/bin/bend-transcript
W=run/v2/render; O=run/v2/transcripts; mkdir -p "$W"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] render: $*"; }
copies() { [ "$1" = bend ] && echo 4 || echo 2; }
shards() { case "$1" in bend) echo 8;; haskell|lean|agda) echo 3;; *) echo 1;; esac; }
pids=()
for l in bend haskell lean agda nix; do
  for part in train holdout; do
    n=$(shards $l); [ $part = holdout ] && n=1
    python3 - "run/v2/results/$l.$part.nul" "$W/$l.$part" "$n" <<'PY'
import sys
src, pre, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = open(src, "rb").read().split(b"\0"); k = (len(d) - 1) // 2
os = [open(f"{pre}.{s}.in.nul", "wb") for s in range(n)]
for j in range(k): os[j * n // k].write(d[2 * j] + b"\0" + d[2 * j + 1] + b"\0")
PY
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
