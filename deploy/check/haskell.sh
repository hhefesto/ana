#!/usr/bin/env bash
# deploy/check/haskell.sh: GHC checks Haskell units (deploy/check/lib.sh has
# the input and output formats).
#
#   GHC=ghc deploy/check/haskell.sh UNITS.nul RESULTS.nul [JOBS]
#
# GHC must know the packages the units import: the flake's `ghc-harness`
# (`nix build .#ghc-harness`) is GHC 9.10 with the common Hackage packages;
# a unit importing anything else fails its original check and is dropped.
#
# Every variant is written as Unit.hs: the file with its module renamed
# Unit (GHC wants the file name to match), the variant in the body's place.
#
#   check    ghc -fno-code -w -fdiagnostics-color=never
#                -fno-show-valid-hole-fits Unit.hs
#            (type checking only, so the verdict reads `( Unit.hs, nothing )`;
#            warnings off, so a check shows only what failed; hole fits off,
#            because they often name the answer)
#   Context  `:type NAME` in GHCi on the original, for each name the body
#            uses; a name GHCi cannot type (a local variable) is left out
#   type     the original without its signature, checked with
#            -Wmissing-signatures: the warning for the name is GHC's own
#            type for it
#
# A file without a `module` line is skipped: a Main module needs `main`.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GHC=${GHC:-ghc}
FLAGS=(-fno-code -w -fdiagnostics-color=never -fno-show-valid-hole-fits)

# ghc on HEAD ++ PRE ++ $2 ++ TAIL, extra flags after $2; CHECK is the check
hs_check() {
  local d=$1 body=$2 e
  printf '%s%s%s%s' "$HEAD" "$PRE" "$body" "$TAIL" > "$d/Unit.hs"
  (cd "$d" && timeout "$TIMEOUT" "$GHC" "${FLAGS[@]}" "${@:3}" Unit.hs > out 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(clean "$d" < "$d/out")")
  return "$e"
}

check_unit() {
  local d=$1 e j n cmds="" ctx="" hole="" typ="" block
  if ! grep -q '^module[[:space:]]' <<< "${F[5]}"; then stat skipped_no_module; return 1; fi
  HEAD=$(printf '%s' "${F[5]}" | sed -E "0,/^module[[:space:]]+[A-Za-z0-9_.']+/s//module Unit/"; printf x)
  HEAD=${HEAD%x}
  PRE=${F[6]}
  TAIL=${F[8]}

  hs_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then
    if grep -q 'Could not \(find\|load\) module' "$d/out"; then stat original_missing_module
    else stat "original_exit_$e"; fi
    return 1
  fi
  local verdict=$CHECK

  # Unit.hs is the original now
  for n in ${F[9]}; do cmds+=":type $n"$'\n'; done
  if [[ -n $cmds ]]; then
    ctx=$(cd "$d" && timeout "$TIMEOUT" "$GHC" --interactive -v0 -w -fdiagnostics-color=never Unit.hs <<< "$cmds" 2>&1 \
      | awk '/^<interactive>/ { keep = 0; next } /^[^ \t]/ { keep = ($0 ~ / :: /) } keep' | clean "$d")
    [[ -n $ctx ]] && stat context
  fi

  if [[ -n ${F[10]} ]]; then
    hs_check "$d" "${F[10]}"
    e=$?
    if (( e == 1 )); then hole=$CHECK; stat hole; else stat "hole_exit_$e"; fi
  fi

  PRE=""
  hs_check "$d" "${F[7]}" -Wmissing-signatures
  e=$?
  PRE=${F[6]}
  if (( e == 0 )); then
    block=$(awk -v name="${F[2]}" '
      /^Unit\.hs:/ { if (keep) printf "%s", blk; blk = ""; keep = 0 }
      { blk = blk $0 "\n"; if (index($0, name " ::") > 0 && blk ~ /missing-signatures/) keep = 1 }
      END { if (keep) printf "%s", blk }' <<< "${CHECK#*"$US"}")
    if [[ -n $block ]]; then typ=$(check_of 0 "$block"); stat type; else stat type_no_warning; fi
  else
    stat "type_exit_$e"
  fi

  local muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    hs_check "$d" "${F[j]}"
    e=$?
    if (( e == 0 )); then stat mutant_checks
    elif (( e == 124 )); then stat mutant_timeout
    else stat mutant_kept; muts+=("${F[j]}" "$CHECK"); fi
  done
  result "$verdict" "$ctx" "$hole" "$typ" "${muts[@]}"
}

check_main "$@"
