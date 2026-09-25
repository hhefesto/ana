#!/usr/bin/env bash
# deploy/check/lean.sh: Lean checks Lean units (deploy/check/lib.sh has the
# input and output formats).
#
#   MATHLIB=run/harness/mathlib4 deploy/check/lean.sh UNITS.nul RESULTS.nul [JOBS]
#
# MATHLIB is a mathlib4 checkout with its build cache (`lake exe cache get`);
# the Lean that runs is the toolchain it pins (lean-toolchain, from elan's
# ~/.elan/toolchains), and imports resolve through its LEAN_PATH, so a unit
# whose file imports anything outside mathlib and its dependencies fails
# its original check and is dropped.
#
# deploy/check/Harness.lean does the work: one Lean process per unit
# elaborates the file's head once and each variant from the state it left,
# printing the messages `lean` would print for head ++ variant (the tail is
# never needed: nothing above a declaration depends on what follows it).
#
#   check    the declaration with the variant for its body
#   hole     the body replaced by `_`: the error shows the goal and context
#   Context  `#check NAME` for each name the body uses, from the head's
#            state; a name Lean cannot resolve (a local) is left out
#   type     none (a tactic proof does not determine its statement)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MATHLIB=$(realpath "${MATHLIB:-run/harness/mathlib4}")
HARNESS=$(realpath "$(dirname "${BASH_SOURCE[0]}")/Harness.lean")
TIMEOUT=${TIMEOUT:-300}
toolchain=$(sed 's|/|--|; s|:|---|' "$MATHLIB/lean-toolchain")
[[ -d $HOME/.elan/toolchains/$toolchain/bin ]] && PATH=$HOME/.elan/toolchains/$toolchain/bin:$PATH
LEAN_PATH=$(cd "$MATHLIB" && lake env printenv LEAN_PATH) || { echo "lean.sh: lake env failed in $MATHLIB" >&2; exit 1; }
export LEAN_PATH

check_unit() {
  local d=$1 e j n v cmds="" hole="" ctx="" pre=${F[6]}
  local vs=("$pre${F[7]}") hole_at=-1 ctx_at=-1
  if [[ -n ${F[10]} ]]; then hole_at=${#vs[@]}; vs+=("$pre${F[10]}"); fi
  for n in ${F[9]}; do cmds+="#check $n"$'\n'; done
  if [[ -n $cmds ]]; then ctx_at=${#vs[@]}; vs+=("$cmds"); fi
  local m0=${#vs[@]}
  for (( j = 11; j < ${#F[@]}; j++ )); do vs+=("$pre${F[j]}"); done

  { printf '%s' "${F[5]}"; for v in "${vs[@]}"; do printf '%s%s' "$FS" "$v"; done; } > "$d/job"
  rm -f "$d/out"
  (cd "$d" && timeout "$TIMEOUT" lean --run "$HARNESS" job out > log 2>&1)
  e=$?
  if (( e != 0 )) || [[ ! -f $d/out ]]; then stat "driver_exit_$e"; return 1; fi
  local C=()
  readarray -t -d "$FS" C < "$d/out"
  if (( ${#C[@]} != ${#vs[@]} )); then stat driver_short; return 1; fi

  e=${C[0]%%"$US"*}
  if [[ $e != 0 ]]; then stat "original_exit_$e"; return 1; fi
  if (( hole_at >= 0 )); then
    e=${C[hole_at]%%"$US"*}
    if [[ $e == 1 ]]; then hole=${C[hole_at]}; stat hole; else stat "hole_exit_$e"; fi
  fi
  if (( ctx_at >= 0 )); then
    ctx=$(printf '%s' "${C[ctx_at]#*"$US"}" | head -n "$CAP_LINES")
    [[ -n $ctx ]] && stat context
  fi
  local muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    v=${C[m0 + j - 11]}
    if [[ ${v%%"$US"*} == 1 ]]; then stat mutant_kept; muts+=("${F[j]}" "$(check_of 1 "$(printf '%s' "${v#*"$US"}" | head -n "$CAP_LINES")")")
    else stat mutant_checks; fi
  done
  result "${C[0]}" "$ctx" "$hole" "" "${muts[@]}"
}

check_main "$@"
