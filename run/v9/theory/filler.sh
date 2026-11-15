#!/usr/bin/env bash
# R7's theory prose filler (change 7, docs/r7/PLAN.md, 2026-11-15): the documents below as NUL
# pairs (id, text), cut into filler pieces by bend-theory-cut (bend/TheoryCut.bend: the logic is
# there; this shim only lists files and decodes Proof-Pile-2's JSON lines with jq).
#   arXiv:ID          the Proof-Pile-2 arXiv papers theory-pick kept (arxiv-pick.tsv, its credits)
#   nlab:NAME         every nLab page (src/nlab-content/pages/**/content.md)
#   eb:PATH           Conal Elliott's and Tai-Danae Bradley's writing and the user's notes on it
#                     (eb/, eb-collect.sh), three times (@2, @3: the user 11-13 allowed up to 4)
#   plfa:PATH         PLFA (plfa/, plfa-collect.sh)
#   SOURCE:PATH       the HoTT book, the Stacks project, Milewski's CTFP (.tex); the 1lab (.lagda.md,
#                     .md); Mathematics in Lean (.lean); Theorem Proving in Lean 4 (.lean, .md)
# Out: prose/files-hi.nul (the pieces), prose/credits.tsv, prose/*.stats.  Resumable: a part
# with its .nul and .stats is kept.
#   bash run/v9/theory/filler.sh [JOBS]     (JOBS: 4)
set -euo pipefail
A=$HOME/src/ana
T=$A/run/v9/theory
P=$T/prose
C=${THC:-$T/gcroot-thc/bin/bend-theory-cut}
J=${1:-4}
[ -x "$C" ] || { echo "no $C" >&2; exit 1; }
mkdir -p "$P/in" "$P/out"
say() { echo "$(date '+%F %T') $*"; }
# a list of files as NUL pairs: PREFIX:PATH (relative to DIR), the file's bytes
files() { local pre=$1 dir=$2 f; shift 2
  (cd "$dir" && find . -type f \( "$@" \) -not -path './.git/*' | LC_ALL=C sort | while read -r f; do
    printf '%s:%s\0' "$pre" "${f#./}"; tr -d '\0' < "$f"; printf '\0'; done); }
part() { local n=$1
  [ -s "$P/out/$n.nul" ] && [ -s "$P/out/$n.nul.stats" ] && return 0
  "$C" "$P/in/$n.nul" "$P/out/$n.nul.tmp" > "$P/out/$n.log" 2>&1 && mv "$P/out/$n.nul.tmp.stats" "$P/out/$n.nul.stats" \
    && mv "$P/out/$n.nul.tmp" "$P/out/$n.nul" || { say "$n: FAILED ($P/out/$n.log)"; return 1; }; }
export -f part say; export C P
# the inputs
for f in "$T"/dl/pp2/arXiv_*.jsonl; do n=pp2-$(basename "$f" .jsonl | sed 's/arXiv_//')
  [ -s "$P/in/$n.nul" ] && continue
  LC_ALL=C grep -F -f "$T/arxiv-pick.tsv.pat" "$f" \
    | jq -j '"arXiv:" + .meta.arxiv_id, "\u0000", (.text | gsub("\u0000"; "")), "\u0000"' > "$P/in/$n.nul.tmp"
  mv "$P/in/$n.nul.tmp" "$P/in/$n.nul"
done
# (one gawk for the 20,794 pages: a process or two a page took 35 minutes)
[ -s "$P/in/nlab.nul" ] || { (cd "$T/src/nlab-content/pages" && find . -name content.md | LC_ALL=C sort | LC_ALL=C gawk '
    { d = $0; sub(/\/content\.md$/, "", d); RS = "^$"; n = ""; t = ""
      getline n < (d "/name"); close(d "/name"); getline t < $0; close($0); RS = "\n"
      gsub(/[\n\0]/, "", n); gsub(/\0/, "", t); printf "nlab:%s%c%s%c", n, 0, t, 0 }') > "$P/in/nlab.nul.tmp"
  mv "$P/in/nlab.nul.tmp" "$P/in/nlab.nul"; }
[ -s "$P/in/eb.nul" ] || { for c in "" @2 @3; do
    (cd "$T/eb" && LC_ALL=C sort -k3 manifest.tsv | cut -f3 | while read -r f; do
      printf 'eb:%s%s\0' "$f" "$c"; tr -d '\0' < "$f"; printf '\0'; done); done > "$P/in/eb.nul.tmp"
  mv "$P/in/eb.nul.tmp" "$P/in/eb.nul"; }
[ -s "$P/in/plfa.nul" ] || { files plfa "$T/plfa" -name '*.md' -o -name '*.lagda' > "$P/in/plfa.nul.tmp"; mv "$P/in/plfa.nul.tmp" "$P/in/plfa.nul"; }
[ -s "$P/in/books.nul" ] || {
  { files hott-book "$T/src/book" -name '*.tex'
    files stacks "$T/src/stacks-project" -name '*.tex'
    files ctfp "$T/src/milewski-ctfp-pdf" -name '*.tex'
    files 1lab "$T/src/1lab" -name '*.md'
    files mil "$T/src/mathematics_in_lean" -name '*.lean'
    files tpil4 "$T/src/theorem_proving_in_lean4" -name '*.lean' -o -name '*.md'; } > "$P/in/books.nul.tmp"
  mv "$P/in/books.nul.tmp" "$P/in/books.nul"; }
say "inputs: $(ls "$P"/in/*.nul | wc -l) parts, $(du -cb "$P"/in/*.nul | tail -1 | cut -f1) bytes"
# the cuts, JOBS at a time
ls "$P"/in/*.nul | xargs -n1 basename | sed 's/\.nul$//' | xargs -P "$J" -I{} bash -c 'part {}'
# every part in name order, the stats summed
for f in $(ls "$P"/in/*.nul | LC_ALL=C sort); do n=$(basename "$f" .nul)
  [ -s "$P/out/$n.nul.stats" ] || { say "$n: no cut"; exit 1; }; done
LC_ALL=C ls "$P"/out/*.nul | LC_ALL=C sort | xargs cat > "$P/files-hi.nul.tmp" && mv "$P/files-hi.nul.tmp" "$P/files-hi.nul"
awk '{s[$1] += $2} END {for (k in s) print k, s[k]}' "$P"/out/*.nul.stats | sort > "$P/files-hi.nul.stats"
# the credits: arXiv's from theory-pick (id, class, phrase, license, title, authors) for the papers in, then the rest's sources
LC_ALL=C gawk -v RS='\0' 'NR % 2 == 1 && /^arXiv:/ {sub(/^arXiv:/, ""); print}' "$P"/in/pp2-*.nul | LC_ALL=C sort -u > "$P/arxiv.ids"
{ printf 'arXiv (via Proof-Pile-2, EleutherAI)\tid\tclass\tphrase\tlicense\ttitle\tauthors\n'
  LC_ALL=C awk -F'\t' 'NR == FNR {k[$1]; next} $1 in k' "$P/arxiv.ids" "$T/arxiv-pick.tsv" | sed 's/^/arXiv\t/'
  printf 'nLab\thttps://ncatlab.org\t%s pages\n' "$(tr -cd '\0' < "$P/in/nlab.nul" | wc -c | awk '{print $1/2}')"
  printf 'eb\tConal Elliott; Tai-Danae Bradley; the user'"'"'s notes\t%s\n' "$T/eb/manifest.tsv"
  for d in plfa book stacks-project milewski-ctfp-pdf 1lab mathematics_in_lean theorem_proving_in_lean4; do
    [ -d "$T/src/$d" ] && printf 'source\t%s\t%s\n' "$d" "$(git -C "$T/src/$d" remote get-url origin 2>/dev/null || echo -)"; done; } > "$P/credits.tsv"
say "prose: $(tr '\n' ' ' < "$P/files-hi.nul.stats")"
