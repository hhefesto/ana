#!/usr/bin/env bash
# UNWIRED 2026-10-15: replaced by `bend-corpus-v2 actset [OUT_DIR]` (bend/CorpusV2/ActSet.bend, the plan's Phase 4); kept for reference
exit 2
# actset.sh [OUT_DIR] (2026-10-07): the prompts ana's own episodes are drawn
# from (agent-act.sh): train units only, each with its direct and its repair
# prompt as E5 asks them (corpus-v2 evalset's cut), the languages shuffled
# together so a run stopped early still covers them all.
#
#   units a language  Lean 2400, Haskell 1800, Nix 1200 (repair only),
#                     Agda 600, Bend 600 (UNITS_LANG overrides): about 12,000
#                     prompts, Lean (46 of E5's 99 prompts, its weakest) the
#                     most
#
# A unit is every k-th of its language's train transcripts (k = units / the
# count wanted), its presentations kept together; OUT/src/LANG holds them
# under the name evalset reads (transcripts.holdout.nul), EVALSET_SRC points
# evalset there. The prompts must hold no held-out unit: the run dies if any
# unit of OUT/prompts.nul is in a LANG.holdout.nul or an E5 prompt set.
set -euo pipefail
cd /home/hhefesto/src/formalTransformer
out=${1:-run/v2/act}
D=${DEPLOY:-nix run .#deploy --}
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] actset: $*"; }
mkdir -p "$out/src"
want() { case $1 in lean) echo ${UNITS_LEAN:-2400};; haskell) echo ${UNITS_HASKELL:-1800};; nix) echo ${UNITS_NIX:-1200};;
  agda) echo ${UNITS_AGDA:-600};; bend) echo ${UNITS_BEND:-600};; esac; }
# a transcript id's unit: UNIT/SHAPE less a `+N` after its last `#`
unit_awk='function unit(id,   u) { u = id; sub(/\/[^\/]*$/, "", u); if (match(u, /#[^#]*$/)) { t = substr(u, RSTART); sub(/\+[0-9]+$/, "", t); u = substr(u, 1, RSTART - 1) t }; return u }'
for l in haskell agda lean nix bend; do
  f=run/v2/transcripts/$l/transcripts.train.nul
  n=$(awk -v RS='\0' "$unit_awk"' NR % 2 == 1 { u = unit($0); if (u != last) { k++; last = u } } END { print k }' "$f")
  k=$(( n / $(want $l) )); [ "$k" -lt 1 ] && k=1
  mkdir -p "$out/src/$l"
  awk -v RS='\0' -v ORS='\0' -v k="$k" "$unit_awk"' NR % 2 == 1 { id = $0; u = unit(id); if (u != last) { i++; last = u }; next }
    (i - 1) % k == 0 { print id; print $0 }' "$f" > "$out/src/$l/transcripts.holdout.nul"
  log "$l: $n train units, every ${k}th: $(awk -v RS='\0' "$unit_awk"' NR % 2 == 1 { u = unit($0); if (u != last) { c++; last = u } } END { print c }' "$out/src/$l/transcripts.holdout.nul") units"
done
# evalset gives a unit one prompt (direct first, repair from the units not
# asked yet): once direct only, once repair only, so a unit gives both
EVALSET_SRC=$out/src $D corpus-v2 evalset --out "$out/prompts.direct.nul" 100000 0
EVALSET_SRC=$out/src $D corpus-v2 evalset --out "$out/prompts.repair.nul" 0 100000
cat "$out/prompts.direct.nul" "$out/prompts.repair.nul" > "$out/prompts.sorted.nul"
# no held-out unit among them
awk -v RS='\0' 'NR % 2 == 1 { sub(/\/[^\/]*$/, ""); print }' "$out/prompts.sorted.nul" | sort -u > "$out/units.txt"
{ cat run/v2/evalset/prompts*.nul | awk -v RS='\0' 'NR % 2 == 1 { sub(/\/[^\/]*$/, ""); print }'
  cat run/v2/results/*.holdout.nul | awk -v RS='\0' 'NR % 2 == 1'; } | sort -u > "$out/heldout.txt"
bad=$(comm -12 "$out/units.txt" "$out/heldout.txt" | wc -l)
[ "$bad" = 0 ] || { log "$bad units of the act set are held out: refusing"; exit 1; }
# the languages shuffled together: each prompt's two fields joined, shuffled, split again
awk -v RS='\0' -v ORS='' 'NR % 2 == 1 { id = $0; next } { gsub(/\x01/, "", $0); printf "%s\x01%s\0", id, $0 }' "$out/prompts.sorted.nul" \
  | shuf -z --random-source=<(yes "corpus-v2 actset") | tr '\001' '\000' > "$out/prompts.shuf.nul"
# only units with a train record (agent-eval checks against it): 20 Bend
# units (own:py2bend/...) have transcripts but neither a record nor sources
awk -v RS='\0' 'NR % 2 == 1' run/v2/results/*.train.nul | sort -u > "$out/recorded.txt"
awk -v RS='\0' -v ORS='\0' 'FNR == NR { u[$0] = 1; next } FNR % 2 == 1 { id = $0; sub(/\/[^\/]*$/, "", id); keep = (id in u) } keep' \
  RS='\n' "$out/recorded.txt" RS='\0' "$out/prompts.shuf.nul" > "$out/prompts.nul"
log "$(( $(tr -cd '\0' < "$out/prompts.shuf.nul" | wc -c) / 2 - $(tr -cd '\0' < "$out/prompts.nul" | wc -c) / 2 )) prompts dropped: their unit has no train record"
log "$(tr -cd '\0' < "$out/prompts.nul" | wc -c | awk '{print $1 / 2}') prompts of $(awk -v RS='\0' 'NR % 2 == 1 { sub(/\/[^\/]*$/, ""); print }' "$out/prompts.nul" | sort -u | wc -l) units in $out/prompts.nul, none held out"
