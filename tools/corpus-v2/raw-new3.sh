#!/usr/bin/env bash
# raw-new3.sh (2026-10-07, plan item 7, approved by the user): new raw code for run 3, through the
# corpus's raw gates (docs/CORPUS-V2.md C3, C6) into run/v2/raw-new3/. Shell and bend-corpus-v2 only.
#
#   tools/corpus-v2/raw-new3.sh STEP...   in order: fetch sample nul corpus keys pre gate split check (all: each)
#
# Sources (run/v2/raw-new3/src; every repository's commit in src/PINS.tsv, and a later run checks
# out those commits):
#   oai     openai/math lean/OAI (Apache-2.0; not lean/ComparatorChallenges, kept out of training
#           for a possible eval): SAMPLE_BYTES (300 MB) across its 23 areas, each area's share
#           proportional to its bytes, its files in sha256 order; files over 1 MB (generated
#           certificates) skipped
#   flt     anthropics/fermats-last-theorem (Apache-2.0), Lean files only: the same, by directory,
#           less the paths the corpus already has and verification/ (the comparator's challenge)
#   staged  run/raw-new/.rawla/stage/lean/*.jsonl.gz (GitHub Lean staged 10-03, never delivered;
#           the vault's 150 repositories in it go at the gate)
#   bend    the Bend 2 repositories in BEND_REPOS (new since 10-03 20:40Z, and the growth of
#           collected ones), and upstream bendlang/bend's .bend files added or changed since
#           a3f1782a (from ~/src/bend2's origin, fetched; nothing else there changes)
#   agda    GitHub Agda repositories pushed since 10-03 (src/agda-repos.txt, the search's list)
# Gates, in order (each one's counts in stage/*.counts, summary.txt):
#   nul    vendored directories, files over 1 MB (Bend: two repositories' over 100 KB), `*_generated*`,
#          NUL bytes, invalid UTF-8; Bend: files the Bend 2 loader rejects (`bend --check-only` fails
#          before a def: parse, import, name clash, a bare operator; a def's type error is kept)
#   pre    a path the corpus has (folded repository + path: run/v2/raw*, vault, filler), a content
#          key it has (L.v2.key), the C3 holdout rule on the new sources' units (2% by
#          sha256("corpus-v2 holdout\0" + unit); out to holdout/), a quarter of the new Bend
#          repositories (>= 3 files, no stream holds the name; first by sha256(name)) to vault/,
#          and a train file whose key a held-out or vault file has
#   gate   bend-corpus-v2 raw: the holdout lists (units, paths, keys; the 10-03 vault), filler,
#          copies, long lines, generated markers, Lean 3, repository caps (RAW_CAP_REPOS gives
#          openai/math and anthropics/fermats-last-theorem 300 M code points: the user, 10-07)
# Outputs: run/v2/raw-new3/{lean-oai,lean-flt,lean-staged,bend,agda}.jsonl (training raw, like
# run/v2/raw-*/), vault/bend.jsonl and holdout/*.jsonl (never training: they sit one directory
# down, where rawshards.sh's run/v2/raw-*/*.jsonl does not look), summary.txt, README.txt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export LC_ALL=C
D=run/v2/raw-new3; S=$D/src; W=$D/stage; PINS=$S/PINS.tsv
JOBS=${JOBS:-14}; SAMPLE_BYTES=${SAMPLE_BYTES:-300000000}; BIG=1000000
CAPS=${CAPS:-openai__math=300000000,anthropics__fermats-last-theorem=300000000}
BEND2=${BEND2:-$HOME/src/bend2}; UPSTREAM_BASE=a3f1782a
BEND=${BEND:-$(command -v bend)}; export BEND   # the Bend 2 loader the Bend gate runs (2.0.35)
mkdir -p "$S" "$W"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] raw-new3: $*"; }
CV2BIN=$D/gcroot-corpus-v2/bin/bend-corpus-v2   # built from this tree (RAW_CAP_REPOS needs it)
[ -x "$CV2BIN" ] || nix build .#bend-corpus-v2 -o "$D/gcroot-corpus-v2"
cv2() { "$CV2BIN" "$@"; }

# Bend 2 repositories (owner/name and a rule: all, lt100k: only files under 100 KB, novendor:
# not vendor/). Not taken: Giulio2002/bend-ssz (generated *_generated.bend), vendored bend2 copies.
BEND_REPOS="
amage-si/ankra all
amage-si/auvia all
amage-si/chromi all
amage-si/dithra all
amage-si/eco-bench all
amage-si/eco-build all
amage-si/kairo all
amage-si/mokko all
amage-si/ocula all
amage-si/runika all
amage-si/splina all
amage-si/syllo all
amage-si/tessra all
amage-si/voltra all
RevCBH/bender-http all
RevCBH/bender-dns all
kbrianps/bend-smtp all
kbrianps/bend-stream all
nuxyel/bend-ml all
albertc71/MailBend all
fabric-runtime/jev-fabric all
PedroAVJ/f-platform all
PedroAVJ/open-dot all
ckluis/shellOS all
ckluis/bocht all
nallux-dozryl/bendcraft all
kianhub/bui all
MavenRain/attest all
wavect/semaprax all
gildrb/elpis all
gildrb/elpis-fast lt100k
DKormann/bend-flow novendor
jobstijl/gax-bend lt100k
mofumail/compress all
jpbezerra/kirchhoff-ising all
akitaonrails/bend-tests all
rimoliga/Bending all
LVTD-LLC/games all
Carolinewk/dugeonbend-temporary all
paymog/bend-kit all
Lulzx/bendc all
MatheusBBarni/bendJVM all
Emerging-Patterns/bolt all
"
AGDA_GLOBS=('*.agda' '*.lagda' '*.lagda.md' '*.lagda.tex')
# the corpus's two synthetic Agda repositories (C6; filter-agda dropped them from agda-f) and a
# copy of one: never taken
AGDA_SKIP="chboishabba/dashi_agda chboishabba/dashi_lean4 ivardb/AgdaModuleImprovement"
export VENDORED='(^|/)(vendor|vendored|third_party|third-party|node_modules|\.lake|lake-packages|_build|dist-newstyle|\.stack-work|_opam)/'

# fetch ---------------------------------------------------------------------------------------

pin_of() { [ -f "$PINS" ] && awk -F'\t' -v r="$1" '$1 == r { c = $2 } END { print c }' "$PINS" || true; }

# clone OWNER/NAME DIR PATTERN...: shallow, blobless, sparse (non-cone patterns), at its pin if any
clone() {
  local r=$1 d=$2 p; shift 2; p=$(pin_of "$r")
  if [ ! -d "$d/.git" ]; then
    git clone -q --depth 1 --filter=blob:none --no-checkout "https://github.com/$r" "$d" 2>/dev/null \
      || { log "clone failed: $r"; rm -rf "$d"; return 0; }
  fi
  git -C "$d" sparse-checkout set --no-cone "$@"
  if [ -n "$p" ] && [ "$(git -C "$d" rev-parse HEAD)" != "$p" ]; then
    git -C "$d" fetch -q --depth 1 --filter=blob:none origin "$p" && git -C "$d" checkout -q --detach "$p"
  else
    git -C "$d" checkout -q 2>/dev/null || true
  fi
  if [ -z "$p" ]; then
    local lic; lic=$(gh api "repos/$r" --jq '.license.spdx_id // "-"' 2>/dev/null || echo "?")
    printf '%s\t%s\t%s\t%s\n' "$r" "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d" log -1 --format=%cI)" "$lic" >> "$PINS"
  fi
}

fetch() {
  log "fetch: openai/math lean/OAI, anthropics/fermats-last-theorem *.lean"
  clone openai/math "$S/openai__math" '/lean/OAI/'
  clone anthropics/fermats-last-theorem "$S/anthropics__fermats-last-theorem" '*.lean'
  log "fetch: Bend repositories"
  mkdir -p "$S/bend"
  echo "$BEND_REPOS" | while read -r r rule; do
    if [ -n "$r" ]; then clone "$r" "$S/bend/${r/\//__}" '*.bend'; fi
  done
  # the sibling layout the repositories import from (amage-si's `../Runika/font.bend`, bender-http's
  # `../dns/main.bend`): links, for the loader gate only (the files are read once, by their repository)
  for x in ankra auvia chromi dithra eco-bench eco-build kairo mokko ocula runika splina syllo tessra voltra; do
    ln -sfn "amage-si__$x" "$S/bend/${x^}"; done
  ln -sfn RevCBH__bender-dns "$S/bend/dns"
  log "fetch: upstream bendlang/bend (.bend files added or changed since $UPSTREAM_BASE)"
  local up; up=$(pin_of bendlang/bend)
  if [ -z "$up" ]; then
    git -C "$BEND2" fetch -q origin
    up=$(git -C "$BEND2" rev-parse origin/main)
    printf '%s\t%s\t%s\t%s\n' bendlang/bend "$up" "$(git -C "$BEND2" log -1 --format=%cI "$up")" Apache-2.0 >> "$PINS"
  fi
  rm -rf "$S/bend/bendlang__bend"
  git -C "$BEND2" diff --name-only --diff-filter=AM "$UPSTREAM_BASE" "$up" -- '*.bend' | while read -r p; do
    mkdir -p "$S/bend/bendlang__bend/$(dirname "$p")"; git -C "$BEND2" show "$up:$p" > "$S/bend/bendlang__bend/$p"
  done
  log "fetch: Agda repositories pushed since 2026-10-03"
  [ -s "$S/agda-repos.txt" ] || gh search repos 'pushed:>2026-10-03' --language=Agda --include-forks=true --limit 200 \
    --json fullName --jq '.[].fullName' | sort | grep -vxF -f <(tr ' ' '\n' <<< "$AGDA_SKIP") > "$S/agda-repos.txt"
  mkdir -p "$S/agda"
  while read -r r; do clone "$r" "$S/agda/${r/\//__}" "${AGDA_GLOBS[@]}"; done < "$S/agda-repos.txt"
  log "fetch: done ($(wc -l < "$PINS") pinned)"
}

# sample --------------------------------------------------------------------------------------

# stdin `id` lines -> `sha256(SALT \0 id) TAB id`, JOBS at once
hashes() {
  local salt=$1 t; t=$(mktemp -d "$W/h.XXXX"); split -n "r/$JOBS" - "$t/p."
  for f in "$t"/p.*; do
    ( while IFS= read -r x; do printf '%s\t%s\n' "$(printf '%s\0%s' "$salt" "$x" | sha256sum | cut -c1-64)" "$x"; done < "$f" > "$f.h" ) &
  done; wait; cat "$t"/p.*.h; rm -rf "$t"
}

# sample ELIGIBLE OUT: ELIGIBLE lines `area TAB id TAB bytes`; OUT the ids taken: each area's
# files in sha256 order while the area holds less than SAMPLE_BYTES * its share of the bytes
sample1() {
  cut -f2 "$1" | hashes "corpus-v2 raw-new3 sample" | sort -t$'\t' -k2,2 > "$1.h"
  sort -t$'\t' -k2,2 "$1" | join -t$'\t' -1 2 -2 2 -o 1.1,2.1,1.2,1.3 - "$1.h" | sort -t$'\t' -k1,1 -k2,2 \
    | awk -F'\t' -v B="$SAMPLE_BYTES" 'NR == FNR { s[$1] += $3; t += $3; next }
        FNR == 1 { for (a in s) want[a] = B * s[a] / t }
        got[$1] < want[$1] { got[$1] += $4; n[$1]++; print $3 }
        END { for (a in s) printf "%s\t%d files\t%.1f MB of %.1f MB\n", a, n[a], got[a] / 1e6, s[a] / 1e6 > "/dev/stderr" }' "$1" - \
    2> "$2.areas" | sort > "$2"
  rm -f "$1.h"; sort "$2.areas" -o "$2.areas"
}

# maxline DIR: `path TAB its longest line in code points` for each .lean file under DIR (C6's long
# line: the gate drops a file with a line over 2,000, so the sample is drawn from the files it keeps)
maxline() {
  ( cd "$1" && find . -path ./.git -prune -o -type f -name '*.lean' -exec awk 'FNR == 1 { if (NR > 1) print f "\t" m; f = FILENAME; m = 0 }
      { t = $0; gsub(/[\200-\277]/, "", t); if (length(t) > m) m = length(t) } END { if (NR > 0) print f "\t" m }' {} + ) | sed 's#^\./##'
}

sample() {
  local o=$S/openai__math f=$S/anthropics__fermats-last-theorem
  log "sample: openai/math"
  maxline "$o" > "$W/oai.maxline"
  ( cd "$o" && find lean/OAI -type f -name '*.lean' -printf '%P\t%s\n' ) | awk -F'\t' -v big=$BIG '
    NR == FNR { ml[$1] = $2; next }
    { n++; b += $2 } $2 > big { nb++; bb += $2; next }
    ml["lean/OAI/" $1] > 2000 { nl++; lb += $2; next }
    { split($1, p, "/"); print p[1] "\trepo:openai__math/lean/OAI/" $1 "\t" $2 }
    END { printf "oai: %d files %.1f MB; over 1 MB %d files %.1f MB; a line over 2,000 code points %d files %.1f MB\n", n, b / 1e6, nb, bb / 1e6, nl, lb / 1e6 > "/dev/stderr" }' \
    "$W/oai.maxline" - > "$W/oai.eligible" 2> "$W/oai.sample.counts"
  sample1 "$W/oai.eligible" "$W/oai.sample"
  log "sample: anthropics/fermats-last-theorem"
  grep -ho '^{"id": "repo:anthropics__fermats-last-theorem/[^"]*"' run/v2/raw/lean.jsonl run/v2/raw-*/lean.jsonl run/v2/vault/lean.jsonl \
    | sed 's/^{"id": "//; s/"$//' | sort -u > "$W/flt.corpus"
  maxline "$f" > "$W/flt.maxline"
  ( cd "$f" && find . -path ./.git -prune -o -type f -name '*.lean' -printf '%P\t%s\n' ) | awk -F'\t' -v big=$BIG '
    NR == FNR { have[$0] = 1; next } FILENAME ~ /maxline$/ { ml[$1] = $2; next }
    { n++; b += $2; id = "repo:anthropics__fermats-last-theorem/" $1 }
    $1 ~ /^verification\// { nv++; next }
    id in have { nc++; cb += $2; next }
    $2 > big { nb++; bb += $2; next }
    ml[$1] > 2000 { nl++; lb += $2; next }
    { a = $1; if (!sub(/\/[^\/]*$/, "", a)) a = "."; print a "\t" id "\t" $2 }
    END { printf "flt: %d files %.1f MB; verification/ %d; in the corpus %d files %.1f MB; over 1 MB %d files %.1f MB; a line over 2,000 code points %d files %.1f MB\n", n, b / 1e6, nv, nc, cb / 1e6, nb, bb / 1e6, nl, lb / 1e6 > "/dev/stderr" }' \
    "$W/flt.corpus" "$W/flt.maxline" - > "$W/flt.eligible" 2> "$W/flt.sample.counts"
  sample1 "$W/flt.eligible" "$W/flt.sample"
  cat "$W/oai.sample.counts" "$W/flt.sample.counts"
  for s in oai flt; do log "sample: $s $(wc -l < "$W/$s.sample") files, $(awk -F'\t' 'NR == FNR { t[$1] = 1; next } $2 in t { b += $3 } END { printf "%.1f MB", b / 1e6 }' "$W/$s.sample" "$W/$s.eligible")"; done
}

# nul -----------------------------------------------------------------------------------------

# a source's files `file TAB id` (stdin), through the collection gates, as OUT.jsonl (and
# OUT.counts): NUL bytes, invalid UTF-8; JOBS NUL pieces converted by `nul-jsonl` at once
tojsonl() {
  local out=$1 t; t=$(mktemp -d "$W/n.XXXX"); cat > "$t/all"
  cut -f1 "$t/all" | tr '\n' '\0' | xargs -0 -r grep -lPa '\x00' > "$t/nul" || true
  cut -f1 "$t/all" | tr '\n' '\0' | xargs -0 -r -P "$JOBS" -n 64 sh -c 'for f; do iconv -f UTF-8 -t UTF-8 "$f" > /dev/null 2>&1 || printf "%s\n" "$f"; done' sh > "$t/utf8" || true
  awk -F'\t' 'FILENAME ~ /\/nul$/ { bad[$0] = "NUL bytes"; next } FILENAME ~ /\/utf8$/ { if (!($0 in bad)) bad[$0] = "invalid UTF-8"; next }
    $1 in bad { c[bad[$1]]++; next } { print; k++ }
    END { for (r in c) printf "%s\t%d\n", r, c[r] > "/dev/stderr"; printf "kept\t%d\n", k > "/dev/stderr" }' "$t/nul" "$t/utf8" "$t/all" \
    > "$t/ok" 2>> "$out.counts"
  split -n "l/$JOBS" "$t/ok" "$t/part."
  for p in "$t"/part.*; do
    ( while IFS=$'\t' read -r f id; do printf '%s\0' "$id"; cat "$f"; printf '\0'; done < "$p" > "$p.nul" && cv2 nul-jsonl "$p.nul" "$p.jsonl" ) &
  done; wait
  cat "$t"/part.*.jsonl > "$out.jsonl"; rm -rf "$t"
  [ "$(wc -l < "$out.jsonl")" = "$(awk -F'\t' '$1 == "kept" { print $2 }' "$out.counts")" ] || { log "$out: record count mismatch"; exit 1; }
}

# Bend files that the Bend 2 loader takes (stdin and stdout `file TAB id`): `bend --check-only`
# in the file's directory, 60 s; a FAIL that names no def (and is not a TODO or an unsafe/foreign
# def, found after the check) is the loader's (parse, import,
# name clash, bare operator) and drops the file; a def's type error, a timeout, a pass keep it
bendok() {
  local t; t=$(mktemp -d "$W/b.XXXX"); cat > "$t/all"
  cut -f1 "$t/all" | tr '\n' '\0' | xargs -0 -r -P "$JOBS" -n 1 sh -c '
    f=$1; o=$(cd "$(dirname "$f")" && timeout 60 "$BEND" "$(basename "$f")" --check-only 2>&1); s=$?
    if [ $s -eq 0 ]; then v=pass; elif [ $s -eq 124 ]; then v=timeout
    elif printf "%s\n" "$o" | grep -q -E "^Location: [^ ]|rel(y|ies) on unsafe or foreign code|TODOs? found"; then v=checked
    else v=load; fi
    printf "%s\t%s\t%s\n" "$f" "$v" "$(printf "%s\n" "$o" | grep -m1 -E "^(Error: .|- (message|expected|observed) )" | cut -c1-160)"' sh > "$t/v"
  sort -t$'\t' -k1,1 "$t/v" > "$W/bend.check.tsv"
  awk -F'\t' 'NR == FNR { v[$1] = $2; next } { c[v[$1]]++ } v[$1] != "load" { print }
    END { for (r in c) printf "bend check %s\t%d\n", r, c[r] > "/dev/stderr" }' "$t/v" "$t/all" 2>> "$W/bend.counts"
  rm -rf "$t"
}

# copies of Bend's Base (a base.bend whose first 4 lines are upstream bend2/base.bend's) out of the
# Bend list (stdin, stdout `file TAB id`), but upstream's own
notbase() {
  local h; h=$(git -C "$BEND2" show "$(pin_of bendlang/bend):bend2/base.bend" | sed -n 1,4p)
  while IFS=$'\t' read -r f id; do
    if [ "${f##*/}" = base.bend ] && [ "${id#repo:bendlang__bend/}" = "$id" ] && [ "$(head -4 "$f")" = "$h" ]; then
      printf 'bend vendored Base copy\t%s\n' "$id" >> "$W/bend.counts"
    else printf '%s\t%s\n' "$f" "$id"; fi
  done
}

# NUL_SOURCES: the sources to (re)build (default all)
want() { case " ${NUL_SOURCES:-oai flt staged bend agda} " in *" $1 "*) return 0 ;; esac; return 1; }

nul() {
  mkdir -p "$W/in"
  if want oai; then log "nul: oai"; : > "$W/in/oai.counts"
  sed 's#^repo:openai__math/##' "$W/oai.sample" | awk -v d="$S/openai__math" '{ print d "/" $0 "\trepo:openai__math/" $0 }' | tojsonl "$W/in/oai"
  fi
  if want flt; then log "nul: flt"; : > "$W/in/flt.counts"
  sed 's#^repo:anthropics__fermats-last-theorem/##' "$W/flt.sample" \
    | awk -v d="$S/anthropics__fermats-last-theorem" '{ print d "/" $0 "\trepo:anthropics__fermats-last-theorem/" $0 }' | tojsonl "$W/in/flt"
  fi
  if want staged; then log "nul: staged GitHub Lean"
  ls run/raw-new/.rawla/stage/lean/*.jsonl.gz | sort | xargs zcat > "$W/in/staged.jsonl"
  printf 'kept\t%d\n' "$(wc -l < "$W/in/staged.jsonl")" > "$W/in/staged.counts"
  fi
  if want bend; then log "nul: bend"; : > "$W/bend.counts"; : > "$W/in/bend.counts"
  { echo "$BEND_REPOS" | while read -r r rule; do if [ -n "$r" ]; then printf '%s\t%s\n' "${r/\//__}" "$rule"; fi; done; printf 'bendlang__bend\tall\n'; } \
    | while IFS=$'\t' read -r n rule; do
        [ -d "$S/bend/$n" ] || { echo "missing $n" >> "$W/bend.counts"; continue; }
        ( cd "$S/bend/$n" && find . -path ./.git -prune -o -type f -name '*.bend' -printf '%P\t%s\n' ) \
          | awk -F'\t' -v n="$n" -v rule="$rule" -v d="$S/bend/$n" -v big=$BIG 'BEGIN { vend = ENVIRON["VENDORED"] }
              $1 ~ vend || (rule == "novendor" && $1 ~ /^vendor\//) { c["vendored"]++; next }
              $1 ~ /_generated/ { c["generated name"]++; next }
              (rule == "lt100k" && $2 >= 100000) || $2 > big { c["size"]++; next }
              { print d "/" $1 "\trepo:" n "/" $1 }
              END { for (r in c) printf "bend %s\t%s\t%d\n", n, r, c[r] > "/dev/stderr" }' 2>> "$W/bend.counts"
      done | notbase | bendok | tojsonl "$W/in/bend"
  fi
  if want agda; then log "nul: agda"; : > "$W/agda.counts"; : > "$W/in/agda.counts"
  while read -r r; do
    n=${r/\//__}; [ -d "$S/agda/$n" ] || { echo "missing $n" >> "$W/agda.counts"; continue; }
    ( cd "$S/agda/$n" && find . -path ./.git -prune -o -type f \( -name '*.agda' -o -name '*.lagda' -o -name '*.lagda.md' -o -name '*.lagda.tex' \) -printf '%P\t%s\n' ) \
      | awk -F'\t' -v n="$n" -v d="$S/agda/$n" -v big=$BIG 'BEGIN { vend = ENVIRON["VENDORED"] }
          $1 ~ vend { c["vendored"]++; next } $2 > big { c["size"]++; next }
          { print d "/" $1 "\trepo:" n "/" $1 }
          END { for (r in c) printf "agda %s\t%s\t%d\n", n, r, c[r] > "/dev/stderr" }' 2>> "$W/agda.counts"
  done < <(grep -vxF -f <(tr ' ' '\n' <<< "$AGDA_SKIP") "$S/agda-repos.txt") | tojsonl "$W/in/agda"
  fi
  for s in oai flt staged bend agda; do log "nul: $s $(wc -l < "$W/in/$s.jsonl") records, $(( $(wc -c < "$W/in/$s.jsonl") / 1000000 )) MB of JSONL"; done
}

# keys ----------------------------------------------------------------------------------------

# keys IN OUT: `id TAB repository TAB path TAB key` a record, in IN's order (a JSONL in JOBS pieces)
keys1() {
  local t; t=$(mktemp -d "$W/k.XXXX")
  case "$1" in
    *.jsonl) for k in $(seq 1 "$JOBS"); do ( split -n "l/$k/$JOBS" "$1" > "$t/$k.jsonl" && cv2 keys "$t/$k.jsonl" > "$t/$k.keys" && rm "$t/$k.jsonl" ) & done; wait
             for k in $(seq 1 "$JOBS"); do cat "$t/$k.keys"; done > "$2" ;;
    *) cv2 keys "$1" > "$2" ;;
  esac
  rm -rf "$t"
}

CORPUS_FILES="run/v2/raw/lean.jsonl run/v2/raw/agda.jsonl run/v2/raw/bend.jsonl run/v2/raw-hf/lean.jsonl
  run/v2/raw-stack/lean.jsonl run/v2/raw-stack/agda.jsonl run/v2/vault/lean.jsonl run/v2/vault/agda.jsonl
  run/v2/transcripts/lean/files-hi.nul run/v2/transcripts/lean/files-lo.nul run/v2/transcripts/agda/files-hi.nul
  run/v2/transcripts/agda/files-lo.nul run/v2/transcripts/bend/files-hi.nul run/v2/transcripts/bend/files-lo.nul
  run/raw-new/bend.jsonl"

corpus() {
  mkdir -p "$W/keys"
  if [ ! -s "$W/keys/corpus.keys" ]; then
    log "keys: the corpus's Lean, Agda and Bend"
    # the NUL files one process each, meanwhile; the JSONL files JOBS pieces at once
    for f in $CORPUS_FILES; do case "$f" in *.jsonl) ;; *) keys1 "$f" "$W/keys/c.$(echo "$f" | tr '/' '_').keys" & ;; esac; done
    for f in $CORPUS_FILES; do case "$f" in *.jsonl) log "keys: $f"; keys1 "$f" "$W/keys/c.$(echo "$f" | tr '/' '_').keys" ;; esac; done
    wait
    cat "$W"/keys/c.*.keys > "$W/keys/corpus.keys.tmp" && mv "$W/keys/corpus.keys.tmp" "$W/keys/corpus.keys"; rm -f "$W"/keys/c.*.keys
  fi
  awk -F'\t' 'NF == 4 { print $2 "\t" $3 > "'"$W/keys/corpus.paths.u"'"; print $4 > "'"$W/keys/corpus.sha.u"'"; print $2 > "'"$W/keys/corpus.repos.u"'" }' "$W/keys/corpus.keys"
  for x in paths sha repos; do sort -u "$W/keys/corpus.$x.u" > "$W/keys/corpus.$x"; rm "$W/keys/corpus.$x.u"; done
  grep -o '"[^"]*"' run/v2/holdout/stream-index.json | tr -d '"' | sort -u | sort -m - "$W/keys/corpus.repos" | uniq > "$W/keys/streams.repos"
  log "keys: corpus $(wc -l < "$W/keys/corpus.paths") paths, $(wc -l < "$W/keys/corpus.sha") keys; $(wc -l < "$W/keys/streams.repos") repository names"
}

keys() {
  [ -s "$W/keys/corpus.sha" ] || corpus
  for s in ${KEYS_SOURCES:-oai flt staged bend agda}; do log "keys: $s"; keys1 "$W/in/$s.jsonl" "$W/keys/$s.keys"
    [ "$(wc -l < "$W/keys/$s.keys")" = "$(wc -l < "$W/in/$s.jsonl")" ] || { log "keys: $s misaligned"; exit 1; }; done
}

# pre -----------------------------------------------------------------------------------------

# the units that hold out by C3's rule: stdin units, stdout the held ones
held_units() { while IFS= read -r u; do h=$(printf 'corpus-v2 holdout\0%s' "$u" | sha256sum | cut -c1-8); [ $(( 16#$h % 1000 )) -lt 20 ] && printf '%s\n' "$u"; done; true; }

pre() {
  local K=$W/keys P=$W/pre; mkdir -p "$P" "$W/cand/train" "$W/cand/holdout" "$W/cand/vault"
  log "pre: units and bigness of the new sources (not staged: its units were split on 10-03)"
  # a repository's distinct paths (the corpus's and the new ones): more than 300 splits it by directory
  cat "$K"/{oai,flt,bend,agda}.keys | awk -F'\t' 'NF == 4 { print $2 "\t" $3 }' | sort -u > "$P/new.paths"
  awk -F'\t' 'NR == FNR { r[$1] = 1; next } $1 in r' "$P/new.paths" "$K/corpus.paths" | sort -mu - "$P/new.paths" \
    | cut -f1 | uniq -c | awk '$1 > 300 { print $2 }' > "$P/big.repos"
  awk -F'\t' 'NR == FNR { big[$1] = 1; next } { p = $2; if (!sub(/\/[^\/]*$/, "", p)) p = ""; print (($1 in big) ? $1 "/" p : $1) }' \
    "$P/big.repos" "$P/new.paths" | sort -u > "$P/units"
  split -n "r/$JOBS" "$P/units" "$P/u."; for f in "$P"/u.??; do held_units < "$f" > "$f.h" & done; wait
  cat "$P"/u.??.h | sort > "$P/held.units"; rm -f "$P"/u.??*
  log "pre: $(wc -l < "$P/units") units, $(wc -l < "$P/held.units") held out by C3's rule"
  # the Bend vault: new repositories (no stream holds the name), >= 3 files after the corpus's paths and
  # keys, ordered by sha256(name); the first quarter
  awk -F'\t' 'NR == FNR { p[$1 "\t" $2] = 1; next } FILENAME ~ /corpus.sha$/ { s[$1] = 1; next }
      NF == 4 && !(($2 "\t" $3) in p) && !($4 in s) { n[$2]++ } END { for (r in n) print r "\t" n[r] }' \
    "$K/corpus.paths" "$K/corpus.sha" "$K/bend.keys" | sort > "$P/bend.repos"
  awk -F'\t' 'NR == FNR { s[$1] = 1; next } !($1 in s) && $2 >= 3 && $1 != "bend" { print $1 }' "$K/streams.repos" "$P/bend.repos" \
    | while IFS= read -r r; do printf '%s\t%s\n' "$(printf '%s' "$r" | sha256sum | cut -c1-64)" "$r"; done | sort > "$P/vault.cands"
  local nv; nv=$(( ($(wc -l < "$P/vault.cands") + 3) / 4 ))
  head -n "$nv" "$P/vault.cands" | cut -f2 | sort > "$P/vault.repos"
  log "pre: Bend vault $nv of $(wc -l < "$P/vault.cands") eligible new repositories: $(tr '\n' ' ' < "$P/vault.repos")"
  # route every record; first the keys a held-out or vault record has (train must not hold them)
  : > "$P/routed.sha"
  for s in oai flt bend agda; do
    awk -F'\t' -v s=$s 'NR == FNR { big[$1] = 1; next } FILENAME ~ /held.units$/ { h[$1] = 1; next } FILENAME ~ /vault.repos$/ { v[$1] = 1; next }
        NF == 4 { p = $3; if (!sub(/\/[^\/]*$/, "", p)) p = ""; u = ($2 in big) ? $2 "/" p : $2; if ((u in h) || (s == "bend" && ($2 in v))) print $4 }' \
      "$P/big.repos" "$P/held.units" "$P/vault.repos" "$K/$s.keys" >> "$P/routed.sha"
  done
  sort -u "$P/routed.sha" -o "$P/routed.sha"
  : > "$W/pre.counts"
  for s in oai flt staged bend agda; do
    log "pre: $s"
    awk -F'\t' -v s=$s -v K="$K/$s.keys" -v T="$W/cand/train/$s.jsonl" -v H="$W/cand/holdout/$s.jsonl" -v V="$W/cand/vault/$s.jsonl" '
      FILENAME ~ /corpus.paths$/ { cp[$1 "\t" $2] = 1; next } FILENAME ~ /corpus.sha$/ { cs[$1] = 1; next }
      FILENAME ~ /big.repos$/ { big[$1] = 1; next } FILENAME ~ /held.units$/ { h[$1] = 1; next }
      FILENAME ~ /vault.repos$/ { v[$1] = 1; next } FILENAME ~ /routed.sha$/ { rs[$1] = 1; next }
      { if ((getline k < K) <= 0) { print "keys ended early" > "/dev/stderr"; exit 1 }
        n = split(k, f, "\t")
        if (n != 4) { c["not a record"]++; next }
        if ((f[2] "\t" f[3]) in cp) { c["path in the corpus"]++; next }
        if (f[4] in cs) { c["copy of the corpus"]++; next }
        if (s != "staged") { p = f[3]; if (!sub(/\/[^\/]*$/, "", p)) p = ""; u = (f[2] in big) ? f[2] "/" p : f[2]
          if (u in h) { c["held out (C3 rule, new unit)"]++; print > H; next }
          if (s == "bend" && (f[2] in v)) { c["vault"]++; print > V; next } }
        if (f[4] in rs) { c["copy of a held-out or vault file"]++; next }
        c["train"]++; print > T }
      END { for (r in c) printf "%s\t%s\t%d\n", s, r, c[r] }' \
      "$K/corpus.paths" "$K/corpus.sha" "$P/big.repos" "$P/held.units" "$P/vault.repos" "$P/routed.sha" "$W/in/$s.jsonl" >> "$W/pre.counts"
    touch "$W/cand/train/$s.jsonl"
  done
  sort "$W/pre.counts" -o "$W/pre.counts"; cat "$W/pre.counts"
}

# gate ----------------------------------------------------------------------------------------

# The repository caps held corpus-wide: a repository the training raw already holds (run/v2/raw,
# raw-hf, raw-stack; its folded name, the bytes of its JSONL text fields) keeps its language cap
# (Lean 15 M, Agda 10 M) less those bytes, at least 1 (0 would be no cap): RAW_CAP_REPOS entries
# for the Lean and Agda train candidates (W/gate/corpus.caps). openai/math and the FLT keep 300 M.
FOLD='function fold(id,   i, rest, name, k) {
  i = id; k = index(i, "#"); if (k) i = substr(i, 1, k - 1)
  rest = i; k = index(rest, ":"); if (k) rest = substr(rest, k + 1)
  k = index(rest, "/"); name = k ? substr(rest, 1, k - 1) : rest
  k = index(name, "__"); if (k) name = substr(name, k + 2)
  name = tolower(name); sub(/\.git$/, "", name); return name }'
corpus_caps() {
  local G=$W/gate l cap
  for l in lean agda; do
    cap=$( [ $l = lean ] && echo 15000000 || echo 10000000 )
    awk "$FOLD"' { match($0, /^\{"id": "[^"]*"/); s[fold(substr($0, 9, RLENGTH - 9))] += length($0) - RLENGTH - 12 }
      END { for (r in s) print r "\t" s[r] }' $(for x in raw raw-hf raw-stack; do if [ -f run/v2/$x/$l.jsonl ]; then echo run/v2/$x/$l.jsonl; fi; done) | sort > "$G/corpus.$l.bytes"
    cat "$W/keys"/{staged,agda}.keys | awk -F'\t' -v l=$l 'NF == 4 && ((l == "lean" && $3 ~ /\.lean$/) || (l == "agda" && $3 !~ /\.lean$/)) { print $2 }' | sort -u \
      | join -t$'\t' - "$G/corpus.$l.bytes" | awk -F'\t' -v cap=$cap '$1 != "math" && $1 != "fermats-last-theorem" { r = cap - $2; print $1 "\t" (r > 0 ? r : 1) "\t" $2 }'
  done | sort -t$'\t' -k1,1 -k2,2n | sort -s -t$'\t' -u -k1,1 > "$G/corpus.caps"
  log "gate: $(wc -l < "$G/corpus.caps") repositories the corpus holds get their cap less its bytes"
}

gate() {
  local G=$W/gate; mkdir -p "$G"; corpus_caps
  local caps; caps="$CAPS$(awk -F'\t' '{ printf ",%s=%d", $1, $2 }' "$G/corpus.caps")"
  for k in train holdout vault; do
    local srcs=(); for s in oai flt staged bend agda; do if [ -s "$W/cand/$k/$s.jsonl" ]; then srcs+=("$W/cand/$k/$s.jsonl"); fi; done
    [ ${#srcs[@]} -gt 0 ] || continue
    log "gate: $k (${srcs[*]})"
    env JOBS="$JOBS" RAW_CHUNK=100000000 RAW_CAP_REPOS="$caps" "$CV2BIN" raw "$G/$k" "${srcs[@]}" > "$G/$k.log" 2>&1 || { tail "$G/$k.log"; exit 1; }
    cat "$G/$k/summary.txt"
  done
}

# split ---------------------------------------------------------------------------------------

split_out() {
  local G=$W/gate
  log "split: $G/train into run/v2/raw-new3"
  grep '^{"id": "repo:openai__math/' "$G/train/lean.jsonl" > "$D/lean-oai.jsonl" || true
  grep '^{"id": "repo:anthropics__fermats-last-theorem/' "$G/train/lean.jsonl" > "$D/lean-flt.jsonl" || true
  grep -v -e '^{"id": "repo:openai__math/' -e '^{"id": "repo:anthropics__fermats-last-theorem/' "$G/train/lean.jsonl" > "$D/lean-staged.jsonl" || true
  [ $(( $(wc -l < "$D/lean-oai.jsonl") + $(wc -l < "$D/lean-flt.jsonl") + $(wc -l < "$D/lean-staged.jsonl") )) = "$(wc -l < "$G/train/lean.jsonl")" ] || { log "split: lean lines lost"; exit 1; }
  for l in bend agda; do if [ -f "$G/train/$l.jsonl" ]; then cp "$G/train/$l.jsonl" "$D/$l.jsonl"; fi; done
  for l in haskell nix; do if [ -f "$G/train/$l.jsonl" ]; then log "split: unexpected $l in train ($(wc -l < "$G/train/$l.jsonl") files), left in $G/train"; fi; done
  mkdir -p "$D/vault" "$D/holdout"
  if [ -f "$G/vault/bend.jsonl" ]; then cp "$G/vault/bend.jsonl" "$D/vault/bend.jsonl"; fi
  for l in lean bend agda; do if [ -f "$G/holdout/$l.jsonl" ]; then cp "$G/holdout/$l.jsonl" "$D/holdout/$l.jsonl"; fi; done
  cp "$W/pre/held.units" "$D/holdout/units.txt"; cp "$W/pre/vault.repos" "$D/vault/repos.txt"
  { for f in "$D"/*.jsonl "$D"/vault/*.jsonl "$D"/holdout/*.jsonl; do
      printf '%-24s %8d files %9.1f MB JSONL\n' "${f#$D/}" "$(wc -l < "$f")" "$(awk -v b="$(wc -c < "$f")" 'BEGIN { print b / 1e6 }')"; done
    echo; echo "gate (bend-corpus-v2 raw), kept and dropped by reason:"; for k in train holdout vault; do if [ -f "$G/$k/summary.txt" ]; then sed "s/^/  $k: /" "$G/$k/summary.txt"; fi; done; } > "$D/summary.txt"
  cat "$D/summary.txt"
}

# check ---------------------------------------------------------------------------------------

check() {
  log "check: ids unique across every raw source"
  local ids; ids=$(mktemp)
  for f in run/v2/raw/*.jsonl run/v2/raw-*/*.jsonl "$D"/vault/*.jsonl "$D"/holdout/*.jsonl; do grep -o '^{"id": "[^"]*"' "$f"; done | sort | uniq -d > "$ids"
  echo "duplicate ids: $(wc -l < "$ids")"; head -5 "$ids"; rm -f "$ids"
  log "check: no output holds a corpus path or key; train holds no held-out or vault key"
  mkdir -p "$W/check"
  # every output's keys again; lean-staged (1.9 GB) by its ids' keys from the stage (raw writes the texts it
  # read), a twentieth of it recomputed to show they agree
  for f in "$D"/*.jsonl "$D"/vault/*.jsonl "$D"/holdout/*.jsonl; do
    local n; n=$(echo "${f#$D/}" | tr '/' '_')
    if [ "$f" = "$D/lean-staged.jsonl" ]; then
      grep -o '^{"id": "[^"]*"' "$f" | sed 's/^{"id": "//; s/"$//' | awk -F'\t' 'NR == FNR { k[$1] = $0; next } { if ($1 in k) print k[$1]; else { print "id not in the stage: " $1 > "/dev/stderr"; print $1 } }' "$W/keys/staged.keys" - > "$W/check/$n.keys"
      awk 'NR % 20 == 1' "$f" > "$W/check/staged-sample.jsonl"; keys1 "$W/check/staged-sample.jsonl" "$W/check/staged-sample.k"; rm "$W/check/staged-sample.jsonl"
      echo "lean-staged: $(awk 'NR % 20 == 1' "$W/check/$n.keys" | cmp -s - "$W/check/staged-sample.k" && echo "the stage's keys agree with a twentieth recomputed" || echo "the stage's keys DIFFER from the recomputed twentieth")"
    else keys1 "$f" "$W/check/$n.keys"; fi
  done
  awk -F'\t' 'FILENAME ~ /corpus.paths$/ { cp[$1 "\t" $2] = 1; next } FILENAME ~ /corpus.sha$/ { cs[$1] = 1; next }
    { n = split(FILENAME, q, "/"); f = q[n]; if (($2 "\t" $3) in cp) bp[f]++; if ($4 in cs) bk[f]++
      if (f ~ /^(vault|holdout)_/) held[$4] = 1; else tk[f, $4] = 1; all[f]++ }
    END { for (f in all) printf "%-28s %8d records; corpus paths %d, corpus keys %d\n", f, all[f], bp[f], bk[f]
          for (x in tk) { split(x, y, SUBSEP); if (y[2] in held) leak++ } printf "train records whose key a vault/holdout file has: %d\n", leak }' \
    "$W/keys/corpus.paths" "$W/keys/corpus.sha" "$W"/check/*.keys
}

for step in "$@"; do
  case "$step" in
    fetch|sample|nul|corpus|keys|pre|gate|check) "$step" ;;
    split) split_out ;;
    all) fetch; sample; nul; corpus; keys; pre; gate; split_out; check ;;
    *) sed -n 2,40p "$0"; exit 2 ;;
  esac
done
