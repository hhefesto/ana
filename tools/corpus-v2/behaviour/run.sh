#!/usr/bin/env bash
# run.sh CKPT TAG [LANG...]: greedy answers of CKPT to every task of each LANG
# (haskell, lean, agda; all three by default), each then checked against its
# tests.  CKPT REF is the control: the reference answers in refs/ go through
# the same checks.  Verdicts in results/TAG/LANG/verdicts.tsv, one
# `NAME<TAB>VERDICT` line per task:
#   pass      the answer compiles (type-checks) and every test holds
#   wrong     the answer compiles but a test fails
#   compile   the answer does not compile / elaborate / type-check (for a
#             proposition task, whose only test is the kernel: the proof fails)
#   crash     the test program (haskell) or the checker while running the
#             tests (lean) dies other than by a failed test
#   refused   lean/agda only: the answer gives up or escapes the checker
#             (lean: sorry, admit, axiom, or an axiom beyond propext,
#             Classical.choice, Quot.sound, Lean.ofReduceBool; agda: postulate,
#             a hole, TERMINATING and the other unsafe pragmas, trustMe)
#   timeout   the check ran out of time
#   unclosed  no closing fence within the token budget
#   noprompt  the output does not start with the prompt
# Environment: TOKENS (160), ANA (run/gcroot-ana/bin/ana), ANA_THREADS (4),
# GEN_JOBS (1, generations at once), JOBS (3, checks at once), CHECK_ONLY=1
# (check the outputs already in results/TAG/LANG), REUSE=1 (keep outputs that
# exist), KEEP_BUILD=1, MATHLIB (run/harness/mathlib4), AGDA (the agda behind
# the nix wrapper on PATH), AGDA_LIBS (run/check-cache/agda/libraries), GHC.
set -u
Q=$(cd "$(dirname "$0")" && pwd)
FT=$(cd "$Q/../../.." && pwd)
if [ $# -lt 2 ]; then echo "usage: run.sh CKPT|REF TAG [haskell|lean|agda ...]" >&2; exit 2; fi
ckpt="$1"; tag="$2"; shift 2
langs=("$@"); [ ${#langs[@]} = 0 ] && langs=(haskell lean agda)
if [ "$ckpt" != REF ] && [ -z "${CHECK_ONLY:-}" ]; then
  [ -f "$ckpt" ] || { echo "run.sh: no checkpoint $ckpt" >&2; exit 2; }
  ckpt=$(realpath "$ckpt")
fi
export Q FT ckpt
export TOKENS=${TOKENS:-160} ANA=${ANA:-$FT/run/gcroot-ana/bin/ana} ANA_THREADS=${ANA_THREADS:-4}
JOBS=${JOBS:-3}; GEN_JOBS=${GEN_JOBS:-1}
stamp() { TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S UTC-6'; }
log() { echo "[$(stamp)] run.sh $tag: $*" >&2; }

# gen LANG NAME R: the output of the prompt (prompt ++ answer), in R/NAME.out
gen() {
  local lang="$1" n="$2" R="$3" d="$Q/tasks/$1/$2"
  if [ "$ckpt" = REF ]; then cat "$d/prompt" "$Q/refs/$lang/$n" > "$R/$n.out"; return; fi
  if [ -n "${REUSE:-}" ] && [ -s "$R/$n.out" ]; then return; fi
  if ( cd "$FT" && TEMPERATURE=0 "$ANA" --checkpoint "$ckpt" --tokens "$TOKENS" --threads "$ANA_THREADS" \
         --prompt-file "$d/prompt" > "$R/$n.out.tmp" 2> "$R/$n.err" ); then
    mv "$R/$n.out.tmp" "$R/$n.out"
  else
    echo "run.sh: ana failed on $lang/$n (see $R/$n.err)" >&2; rm -f "$R/$n.out.tmp"
  fi
}

# extract LANG NAME R: the answer, R/NAME.term (the generated text up to the
# first closing fence line); prints the verdict and fails when there is none
extract() {
  local d="$Q/tasks/$1/$2" n="$2" R="$3" pb
  [ -f "$R/$n.out" ] || { printf '%s\tnoprompt\n' "$n"; return 1; }
  pb=$(wc -c < "$d/prompt")
  # ana --checkpoint heads its stdout with "=== ana: step ... ===": drop it
  sed "1{/^=== ana: .* ===$/d}" "$R/$n.out" > "$R/$n.body"
  if ! cmp -s -n "$pb" "$d/prompt" "$R/$n.body"; then printf '%s\tnoprompt\n' "$n"; return 1; fi
  tail -c +$((pb + 1)) "$R/$n.body" > "$R/$n.gen"
  awk 'BEGIN{c=0} /^```/{c=1; exit} {print} END{exit c?0:3}' "$R/$n.gen" > "$R/$n.term"
  if [ $? = 3 ]; then printf '%s\tunclosed\n' "$n"; return 1; fi
}

# the line of the first error in an Agda log (Agda stops at the first)
agda_error_line() {
  grep -E "Task\\.agda:[0-9]+[.,][-0-9.,]*: error" "$1" | head -1 | grep -oE "Task\\.agda:[0-9]+" | head -1 | cut -d: -f2
}

check_haskell() {
  local n="$1" d="$Q/tasks/haskell/$1" R="$2"
  extract haskell "$n" "$R" || return 0
  local sig; sig=$(cat "$d/sig")
  {
    echo 'module Main where'
    echo 'import Data.List (sort, sortBy, sortOn, group, groupBy, nub, transpose, foldl'"'"', intercalate, isPrefixOf, maximumBy, minimumBy, tails, inits, elemIndex, partition, unfoldr)'
    echo 'import Data.Char (toUpper, toLower, isDigit, isSpace, isLower, isUpper, isAlpha, ord, chr, digitToInt)'
    echo 'import Data.Maybe (mapMaybe, fromMaybe, catMaybes, listToMaybe)'
    echo 'import Data.Ord (comparing)'
    echo 'import qualified Data.Map as M'
    echo 'import System.Exit'
    cat "$d/pre"; echo
    echo "$sig"
    grep -vxF "$sig" "$R/$n.term"
    echo
    echo 'tests :: [Bool]'
    echo "tests = $(cat "$d/tests")"
    echo 'main :: IO ()'
    echo 'main = if and tests then putStrLn "PASS" else putStrLn ("FAIL " ++ show [i | (i, False) <- zip [1 :: Int ..] tests]) >> exitWith (ExitFailure 1)'
  } > "$R/$n.hs"
  local B="$R/build/$n"; mkdir -p "$B"
  if ! timeout 120 "$GHC" -O0 -outputdir "$B" -o "$B/t" "$R/$n.hs" > "$R/$n.ghc" 2>&1; then
    printf '%s\tcompile\n' "$n"
  else
    timeout 10 "$B/t" > "$R/$n.run" 2>&1; local e=$?
    if [ $e = 0 ]; then printf '%s\tpass\n' "$n"
    elif grep -q '^FAIL' "$R/$n.run"; then printf '%s\twrong\n' "$n"
    else printf '%s\tcrash\n' "$n"; fi
  fi
  [ -n "${KEEP_BUILD:-}" ] || rm -rf "$B"
}

# Lean: NAME.lean is `import Mathlib`, the pre, the Type joined to the answer
# by ` :=` (unless the answer opens with `:=`; bend/Agent/Tools.bend at.file),
# then `section` (so a declaration the answer leaves unfinished fails on a line
# of the answer, not on a test), the tests, and `#print axioms NAME`.
# Check.lean elaborates the lines up to that `section` first: an error there
# is the answer's (compile), and only an answer without one meets the tests
# (an error then is a failed test: wrong).  Lean compiles a definition whose
# termination proof failed, so a #guard on it would loop.
check_lean() {
  local n="$1" d="$Q/tasks/lean/$1" R="$2"
  extract lean "$n" "$R" || return 0
  if grep -qEw 'sorry|admit|axiom|implemented_by|extern|unsafe' "$R/$n.term"; then printf '%s\trefused\n' "$n"; return; fi
  if ! grep -q '[^[:space:]]' "$R/$n.term"; then printf '%s\tcompile\n' "$n"; return; fi
  local f="$R/$n.lean"
  {
    echo 'import Mathlib'
    echo
    if [ -s "$d/pre" ]; then cat "$d/pre"; echo; echo; fi
    printf '%s' "$(cat "$d/sig")"
    if [ "$(head -c 2 "$R/$n.term")" = ":=" ]; then echo; else printf ' :=\n'; fi
    cat "$R/$n.term"
    echo
    echo 'section BehaviourChecks'
  } > "$f"
  local L; L=$(wc -l < "$f")
  { cat "$d/tests"; echo "#print axioms $n"; echo 'end BehaviourChecks'; } >> "$f"
  # Check.lean: the first L lines, then the tests only when they had no error
  ( cd "$R" && timeout "${LEAN_TIMEOUT:-300}" env LEAN_PATH="$LEAN_PATH_" PATH="$LEAN_BIN:$PATH" \
      "$LEAN_BIN/lean" --run "$Q/Check.lean" "$n.lean" "$L" ) > "$R/$n.log" 2>&1
  local e=$?
  if [ $e = 124 ]; then printf '%s\ttimeout\n' "$n"; return; fi
  if grep -q 'declaration uses .sorry' "$R/$n.log"; then printf '%s\trefused\n' "$n"; return; fi
  case $e in
    0) ;;
    1) printf '%s\tcompile\n' "$n"; return ;;
    2) printf '%s\twrong\n' "$n"; return ;;
    *) # died: in the tests (the evaluator) is a crash, before them the answer's
       if grep -qx -- '-- behaviour: tests' "$R/$n.log"; then printf '%s\tcrash\n' "$n"; else printf '%s\tcompile\n' "$n"; fi
       return ;;
  esac
  local ax; ax=$(grep -E "'$n' depends on axioms: " "$R/$n.log" | sed 's/.*axioms: \[//; s/\]$//' | tr ',' '\n' | tr -d ' ' \
    | grep -vxE 'propext|Classical\.choice|Quot\.sound|Lean\.ofReduceBool|Lean\.trustCompiler' | head -1)
  if [ -n "$ax" ]; then printf '%s\trefused\n' "$n"; return; fi
  printf '%s\tpass\n' "$n"
}

# Agda: build/NAME/Task.agda is --safe, the module header, the imports, the
# pre, the Type, the answer less any line equal to the Type, a separating
# import (as Lean's `section`), then the tests.
check_agda() {
  local n="$1" d="$Q/tasks/agda/$1" R="$2"
  extract agda "$n" "$R" || return 0
  if grep -qE 'postulate|\{!|TERMINATING|NON_TERMINATING|NO_POSITIVITY_CHECK|NO_UNIVERSE_CHECK|NO_TERMINATION_CHECK|INJECTIVE|BUILTIN|REWRITE|OPTIONS|trustMe|primEraseEquality' "$R/$n.term" \
     || awk '{ gsub(/[(){};]/, " "); for (i = 1; i <= NF; i++) if ($i == "?") f = 1 } END { exit !f }' "$R/$n.term"; then
    printf '%s\trefused\n' "$n"; return
  fi
  local sig; sig=$(cat "$d/sig")
  local B="$R/build/$n"; rm -rf "$B"; mkdir -p "$B"
  local f="$R/$n.agda"
  {
    echo '{-# OPTIONS --safe #-}'
    echo 'module Task where'
    echo
    echo 'open import Data.Nat'
    echo 'open import Data.List'
    echo 'open import Data.Bool using (Bool; true; false; not; _∧_; _∨_; if_then_else_; T)'
    echo 'open import Data.Maybe using (Maybe; just; nothing)'
    echo 'open import Data.Product using (_×_; _,_; proj₁; proj₂)'
    echo 'open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong; cong₂; sym; trans; subst)'
    echo
    if [ -s "$d/pre" ]; then cat "$d/pre"; echo; echo; fi
    echo "$sig"
    grep -vxF "$sig" "$R/$n.term"
    echo
    echo 'open import Agda.Builtin.Unit using ()'
  } > "$f"
  local L; L=$(wc -l < "$f")
  { echo; cat "$d/tests"; } >> "$f"
  cp "$f" "$B/Task.agda"
  ( cd "$B" && timeout "${AGDA_TIMEOUT:-300}" "$AGDA" --library-file="$AGDA_LIBS" -l standard-library-2.3 -i . Task.agda ) > "$R/$n.log" 2>&1
  local e=$?
  [ -n "${KEEP_BUILD:-}" ] || rm -rf "$B"
  if [ $e = 0 ]; then printf '%s\tpass\n' "$n"; return; fi
  if [ $e = 124 ]; then printf '%s\ttimeout\n' "$n"; return; fi
  local el; el=$(agda_error_line "$R/$n.log")
  if [ -n "$el" ] && [ "$el" -gt "$L" ]; then printf '%s\twrong\n' "$n"; else printf '%s\tcompile\n' "$n"; fi
}
export -f gen extract agda_error_line check_haskell check_lean check_agda

for lang in "${langs[@]}"; do
  case "$lang" in
    haskell)
      export GHC=${GHC:-$FT/run/check-cache/ghc-harness/bin/ghc} ;;
    lean)
      MATHLIB=${MATHLIB:-$FT/run/harness/mathlib4}
      export LEAN_BIN=${LEAN_BIN:-$HOME/.elan/toolchains/$(sed 's|/|--|; s|:|---|' "$MATHLIB/lean-toolchain" | tr -d '\n')/bin}
      LEAN_PATH_=$(env -C "$MATHLIB" PATH="$LEAN_BIN:$PATH" "$LEAN_BIN/lake" env printenv LEAN_PATH) \
        || { echo "run.sh: lake env failed in $MATHLIB" >&2; exit 1; }
      export LEAN_PATH_ ;;
    agda)
      if [ -z "${AGDA:-}" ]; then
        w=$(command -v agda) || { echo "run.sh: no agda on PATH (set AGDA)" >&2; exit 1; }
        # the real agda behind nixpkgs' wrapper (the wrapper passes its own --library-file)
        AGDA=$(grep -ao '"/nix/store/[^"]*/bin/agda"' "$w" | head -1 | tr -d '"'); [ -n "$AGDA" ] || AGDA=$w
      fi
      export AGDA AGDA_LIBS=${AGDA_LIBS:-$FT/run/check-cache/agda/libraries} ;;
    *) echo "run.sh: no language $lang (haskell, lean, agda)" >&2; exit 2 ;;
  esac
  [ -d "$Q/tasks/$lang" ] || { echo "run.sh: no tasks/$lang (run tasks.sh)" >&2; exit 2; }
  R="$Q/results/$tag/$lang"; mkdir -p "$R"
  names=$(ls "$Q/tasks/$lang")
  if [ -z "${CHECK_ONLY:-}" ]; then
    log "$lang: generating $(echo "$names" | wc -l) answers from $ckpt"
    echo "$names" | xargs -P "$GEN_JOBS" -I{} bash -c 'gen "$@"' _ "$lang" {} "$R"
  fi
  log "$lang: checking"
  echo "$names" | xargs -P "$JOBS" -I{} bash -c 'check_'"$lang"' "$@"' _ {} "$R" | sort > "$R/verdicts.tsv"
  s="$tag $lang: $(grep -c $'\tpass$' "$R/verdicts.tsv")/$(wc -l < "$R/verdicts.tsv") pass; $(cut -f2 "$R/verdicts.tsv" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
  echo "$s" > "$R/summary.txt"
  log "$s"
  echo "$s"
done
