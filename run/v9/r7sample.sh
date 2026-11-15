#!/usr/bin/env bash
# A sample of R7 for the user (docs/r7/PLAN.md, pipeline step 4: "A sample for the user, then the user's call on
# renting").  A thin shim: it only picks and prints; the sessions are the mix's.
#   run/v9/r7sample.sh [MIX] [OUT]     MIX: the Bend mix (run/v9/mix7/bend); OUT: run/v9/R7sample.md
# Per kind, the K (2) sessions whose ids hash lowest (the same picks each time), each cut at CUT (6000) bytes; then
# a prose piece and a validation session.  Kinds by id and text: the authors'-law asks, the prove units, the sorts,
# mugen's own chats, run 10's new code, fixes, chains, helpers, the rest.
cd /home/hhefesto/src/ana || exit 1
M=${1:-run/v9/mix7/bend}; O=${2:-run/v9/R7sample.md}; K=${K:-2}; CUT=${CUT:-6000}
PROSE=run/v9/theory/prose/files-hi.nul; VAL=run/v9/R7vsrc/bend/transcripts.train.nul
[ -s "$M" ] || { echo "no $M" >&2; exit 1; }
pick() { LC_ALL=C gawk -v K="$K" -v CUT="$CUT" -v only="$1" '
  BEGIN {RS = "\0"; for (i = 1; i < 256; i++) o[sprintf("%c", i)] = i}
  function kind(id, x) {
    if (x ~ /which their proofs check/) return "authors-law ask"
    if (id ~ /authlaw|prove/) return "prove unit"
    if (id ~ /sorts\//) return "sorts with fuel"
    if (id ~ /^mugenlog:/) return "mugen chat"
    if (id ~ /col10/) return "run 10 code"
    if (id ~ /mugen-fix-/) return "fix"
    if (id ~ /mugen-chain-/) return "chain"
    if (id ~ /helper|scratch/) return "helper"
    return "other" }
  function h(s, j, v) {v = 7; for (j = 1; j <= length(s); j++) v = (v * 31 + o[substr(s, j, 1)]) % 1000000007; return v}
  NR % 2 == 1 {id = $0; next}
  {k = (only != "") ? only : kind(id, $0); n[k]++; v = h(id)
   for (j = 1; j <= K; j++) if (!((k, j) in H) || v < H[k, j]) {
     for (m = K; m > j; m--) if ((k, m - 1) in H) {H[k, m] = H[k, m - 1]; I[k, m] = I[k, m - 1]; X[k, m] = X[k, m - 1]}
     H[k, j] = v; I[k, j] = id; X[k, j] = substr($0, 1, CUT) (length($0) > CUT ? "\n[... " length($0) - CUT " more bytes]" : ""); break } }
  END {for (k in n) {printf "## %s (%d in this stream)\n\n", k, n[k]
         for (j = 1; j <= K; j++) if ((k, j) in H) printf "### %s\n\n````\n%s\n````\n\n", I[k, j], X[k, j]}}' "$2"; }
{ echo "# R7: a sample ($(date '+%F %T'))"; echo
  echo "From $M ($(tr -cd '\0' < "$M" | wc -c | awk '{print int($1/2)}') sessions); each kind's $K sessions whose ids hash lowest, cut at $CUT bytes."; echo
  pick "" "$M"
  [ -s $PROSE ] && K=1 pick "theory prose (filler)" $PROSE
  [ -s $VAL ] && K=1 pick "validation (R7valid)" $VAL; } > "$O"
echo "$O: $(grep -c '^### ' "$O") sessions, $(wc -c < "$O") bytes"
