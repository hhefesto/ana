#!/usr/bin/env bash
# UNWIRED 2026-10-15: replaced by `bend-corpus-v2 s2 S1_DIR BOUNDARY OUT ACT_DIR...` (bend/CorpusV2/S2.bend, the plan's Phase 4), which checks NLR against S1_LOG before any work; kept for reference
exit 2
# s2.sh S1_DIR BOUNDARY OUT ACT_DIR... (2026-10-07): run 3's second stage, built on the
# box at the step S1 stops at (docs/AGENT.md):
# - the steady plan's segments from BOUNDARY on;
# - interleaved with the act rounds' episodes: ana's own solved ones
#   (ACT_DIR/accepted/LANG-act) and ana's rejected Terms with the unit's fix (LANG-fix).
#   They become transcript windows of SHARD (250) episodes a shard, so combine, which
#   interleaves by shard, spreads them over the whole stage.
# The episode windows' gaps take filler from run/v3/s2fill: a slice of format 2's
# filler, held-out files left out, shipped by act-box.sh, its files shuffled (below).
# The episodes all fit a window: bend-episode accept and fixed leave out the longer.
#
# OUT gets the plan, its shards (hard links) and stage.env, which `fp.sh again` reads:
# - NLR is the lr S1's schedule reaches at BOUNDARY, 0.5 LR (1 + cos(pi (B - W) / (T - W))),
#   from fp.sh's LR (3e-4) and WARM (300) and the plan's total T;
# - NWARM is 10.
# BOUNDARY must start a segment (S1 runs with STEPS=BOUNDARY, and the trainer saves at its
# last step). Run from the act workspace (the repository); S1_LOG (~/ana/
# train.log) is checked against NLR. Then append to the chain's STAGES:
#   s2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m
# (paths relative to the trainer's directory, TRAINER_DIR, ~/ana: the chain
# looks for a stage's plan there)
set -euo pipefail
s1=${1:?usage: s2.sh S1_DIR BOUNDARY OUT ACT_DIR...} b=${2:?} out=${3:?}; shift 3
[ $# -ge 1 ] || { echo "s2.sh: no ACT_DIR" >&2; exit 2; }
D=${DEPLOY:-run/v2/gcroot-deploy-agent/bin/deploy}
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] s2: $*"; }
p=$s1/plan-fp100m-b16-windows.tsv
[ -s "$p" ] || { log "no plan $p"; exit 1; }
awk -v b="$b" '$1 == "segment" && $9 == b { f = 1 } END { exit !f }' "$p" || { log "step $b starts no segment of $p"; exit 1; }
rest=$out.rest ep=$out.ep
rm -rf "$rest" "$ep" "$out"; mkdir -p "$rest" "$ep/tx"
# the rest of the steady plan: combine reads a plan's segment lines (K, DOCS, TW) and
# shard-K-fp100m.corpus beside it
awk -v b="$b" '$1 == "segment" && $9 >= b' "$p" > "$rest/plan-fp100m-b16-windows.tsv"
awk '{ print $2 }' "$rest/plan-fp100m-b16-windows.tsv" | while read -r k; do
  ln -sfn "$(readlink -f "$s1/shard-$k-fp100m.corpus")" "$rest/shard-$k-fp100m.corpus"; done
rw=$(awk '{ s += $6 } END { print s + 0 }' "$rest/plan-fp100m-b16-windows.tsv")
log "rest of S1 from step $b: $(wc -l < "$rest/plan-fp100m-b16-windows.tsv") segments, $rw training windows"
# the episodes: a language each, every round's together, PER their count / 100
specs=""
for kind in act fix; do for l in haskell agda lean nix bend; do
  d=$ep/tx/$l-$kind; mkdir -p "$d"
  fs=(); for a in "$@"; do f=$a/accepted/$l-$kind/transcripts.train.nul; [ -f "$f" ] && fs+=("$f"); done
  cat "${fs[@]}" /dev/null > "$d/transcripts.train.nul"
  : > "$d/files-hi.nul"; : > "$d/files-lo.nul"
  for f in results.holdout.nul transcripts.holdout.nul; do ln -sfn "$PWD/run/v2/transcripts/$l/$f" "$d/$f"; done
  n=$(( $(tr -cd '\0' < "$d/transcripts.train.nul" | wc -c) / 2 ))
  per=$(( (n + 50) / 100 )); [ "$per" -lt 1 ] && per=1
  [ "$n" -gt 0 ] && specs="$specs $l-$kind:$per"
  log "$l-$kind: $n episodes"
done; done
[ -n "$specs" ] || { log "no episodes in $*"; exit 1; }
# The filler's files in a fixed shuffle: plan-windows gives each shard the next FILL files
# in order, and s2fill is in repository order, so a shard whose slice is all short files
# (Lean problem statements, own:bend2) found none long enough for a window's gap
# (2026-10-13, shards 24, 25, 28 of 37). Pairs move whole: an id has no \001.
mkdir -p "$ep/tx/filler"
for f in files-lo.nul results.holdout.nul transcripts.holdout.nul transcripts.train.nul; do
  ln -sfn "$PWD/run/v3/s2fill/$f" "$ep/tx/filler/$f"; done
paste -z -d $'\001' - - < run/v3/s2fill/files-hi.nul | shuf -z --random-source=<(yes 2026) \
  | sed -z 's/\x01/\x00/' > "$ep/tx/filler/files-hi.nul"
[ "$(tr -cd '\0' < "$ep/tx/filler/files-hi.nul" | wc -c)" = "$(tr -cd '\0' < run/v3/s2fill/files-hi.nul | wc -c)" ] \
  || { log "the shuffled filler lost pairs"; exit 1; }
log "plan-windows $ep/w fp100m 16$specs filler:1"
OUT=$ep/tx SHARD=${SHARD:-250} JOBS=${JOBS:-8} TOKENIZER=weights/code32k.bpe \
  $D plan-windows "$ep/w" fp100m 16 $specs filler:1
ew=$(awk '$1 == "segment" { s += $6 } END { print s + 0 }' "$ep/w/plan-fp100m-b16-windows.tsv")
share=$(awk -v r="$ew" -v t="$rw" 'BEGIN { s = r / (t + r); printf "%.4f", int(s * 10000 + 0.9999) / 10000 }')
log "episode windows $ew of $(( ew + rw )): share $share"
$D corpus-v2 combine "$share" "$out" "$rest" "$ep/w"
# the lr S1's schedule reaches at the boundary
total=$(head -1 "$p" | awk '{ print $3 }')
nlr=$(awk -v lr="${LR:-3e-4}" -v w="${WARM:-300}" -v t="$total" -v b="$b" \
  'BEGIN { printf "%.6e", 0.5 * lr * (1 + cos(3.141592653589793 * (b - w) / (t - w))) }')
printf 'NLR=%s\nNWARM=10\n' "$nlr" > "$out/stage.env"
seen=$(grep -o 'lr=[0-9.e-]*' "${S1_LOG:-$HOME/ana/train.log}" 2>/dev/null | tail -1 | cut -d= -f2 || true)
log "stage.env: NLR $nlr (S1's log last shows lr ${seen:-none}), NWARM 10"
log "S2: $(head -1 "$out/plan-fp100m-b16-windows.tsv" | awk '{ print $3 }') steps in $out; append to STAGES:"
# relative to the trainer's directory: fp-chain.sh looks for a stage's plan under ~/ana/
rel=${out#${TRAINER_DIR:-$HOME/ana}/}
echo "s2 traind-next ${EVERY:-5000} $rel/plan-fp100m-b16-windows.tsv $rel fp100m"
