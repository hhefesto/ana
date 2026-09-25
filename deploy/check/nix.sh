#!/usr/bin/env bash
# deploy/check/nix.sh: Nix checks Nix units (deploy/check/lib.sh has the
# input and output formats).
#
#   deploy/check/nix.sh UNITS.nul RESULTS.nul [JOBS]
#
# A Nix unit is a whole file, written as Unit.nix and evaluated with
#
#   nix-instantiate --eval --strict Unit.nix
#
# under an empty NIX_PATH, so the check is the value (a function prints as
# <LAMBDA>) or the evaluation error. A file that imports <nixpkgs> or a
# path beside it fails its original check and is dropped. Nix has no types
# and no holes: Context, hole and type are empty.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT=${TIMEOUT:-30}

nix_check() {
  local d=$1 body=$2 e
  printf '%s' "$body" > "$d/Unit.nix"
  (cd "$d" && NIX_PATH= timeout "$TIMEOUT" nix-instantiate --eval --strict Unit.nix > out 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(clean "$d" < "$d/out")")
  return "$e"
}

check_unit() {
  local d=$1 e j
  nix_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then stat "original_exit_$e"; return 1; fi
  local verdict=$CHECK muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    nix_check "$d" "${F[j]}"
    e=$?
    if (( e == 0 )); then stat mutant_checks
    elif (( e == 124 )); then stat mutant_timeout
    else stat mutant_kept; muts+=("${F[j]}" "$CHECK"); fi
  done
  result "$verdict" "" "" "" "${muts[@]}"
}

check_main "$@"
