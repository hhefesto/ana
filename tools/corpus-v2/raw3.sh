#!/usr/bin/env bash
# raw3.sh (2026-10-07): run 3's raw code, steady (steady-mix.sh: every source runs dry in
# the last round) and cut into rawshards slices, run/v3/R/1..n, for combine.
#
#   Haskell  run 2's 1.95 GB, 0.95 GB of The Stack's                            ~46%
#   Lean     openai/math OAI and FLT whole (the user's ~300 MB each), run 2's
#            GitHub Lean 0.70 GB and the new GitHub Lean 0.94 GB (human-written
#            first), The Stack's whole, STP/NuminaMath 0.15 GB                  ~38%
#   Agda     all (run 2's, The Stack's, the new; the user: reweight only)       ~10%
#   Nix      all                                                                 ~4%
#   Bend     all (run 2's and the new; the new vault and holdout stay out)      ~0.3%
#
# A source taken whole is merged with its language's other whole sources first
# (run/v3/Rsrc), so the smallest (Bend, 1,751 documents) sets the rounds and the
# others lose at most a round's grain to the floor in PER = take / rounds.
set -euo pipefail
cd /home/hhefesto/src/formalTransformer
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] raw3: $*"; }
src=run/v3/Rsrc R=run/v3/R; mkdir -p "$src" "$R"
cat run/v2/raw/nix.jsonl run/v2/raw-stack/nix.jsonl > "$src/nix.jsonl"
cat run/v2/raw/bend.jsonl run/v2/raw-new3/bend.jsonl > "$src/bend.jsonl"
cat run/v2/raw/agda.jsonl run/v2/raw-stack/agda.jsonl run/v2/raw-new3/agda.jsonl > "$src/agda.jsonl"
[ -s "$R/mix.jsonl" ] || tools/corpus-v2/steady-mix.sh "$R/mix.jsonl" \
  run/v2/raw/haskell.jsonl:all run/v2/raw-stack/haskell.jsonl:950000000 \
  run/v2/raw-new3/lean-oai.jsonl:all run/v2/raw-new3/lean-flt.jsonl:all run/v2/raw-stack/lean.jsonl:all \
  run/v2/raw/lean.jsonl:700000000 run/v2/raw-new3/lean-staged.jsonl:940000000 run/v2/raw-hf/lean.jsonl:150000000 \
  "$src/agda.jsonl:all" "$src/nix.jsonl:all" "$src/bend.jsonl:all"
n=$(( ($(stat -c %s "$R/mix.jsonl") + 299999999) / 300000000 ))
for k in $(seq 1 "$n"); do
  [ -s "$R/$k/plan-fp100m-b16-s2000.tsv" ] && { log "slice $k of $n: built"; continue; }
  log "slice $k of $n"; R=$R JOBS=${JOBS:-6} tools/corpus-v2/rawshards.sh build "$k" || { log "slice $k: failed or empty"; break; }
done
for k in $(seq 1 "$n"); do [ -f "$R/$k/plan-fp100m-b16-s2000.tsv" ] && head -1 "$R/$k/plan-fp100m-b16-s2000.tsv" | awk -v k="$k" '{ print "R/" k, $3, "steps" }'; done
log done
