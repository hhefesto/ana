#!/usr/bin/env bash
# deploy/check/agda.sh: Agda checks Agda units (deploy/check/lib.sh has the
# input and output formats).
#
#   AGDA=agda deploy/check/agda.sh UNITS.nul RESULTS.nul [JOBS]
#
# AGDA must know the libraries the units import (the dev shell's agda has
# the standard library); a unit importing anything else fails its original
# check and is dropped.
#
# Every variant is written as Unit.agda: the file's head with its top-level
# module renamed Unit (Agda wants the file name to match), the declaration's
# signature, the variant. The tail is left out: Agda checks top-down, so
# nothing above a declaration depends on what follows it.
#
#   check    agda Unit.agda (status 42 on an error)
#   hole     the last one-line equation's right side replaced by `?`: in
#            interaction mode, Cmd_load then Cmd_goal_type_context, whose
#            display (the goal, a rule, the local context) is the check
#   Context  Cmd_infer_toplevel for each name the body uses, in the same
#            session: `name : type` for each name Agda can type
#   type     none
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGDA=${AGDA:-agda}
TIMEOUT=${TIMEOUT:-120}

agda_check() {
  local d=$1 body=$2 e
  printf '%s%s%s' "$HEAD" "$PRE" "$body" > "$d/Unit.agda"
  (cd "$d" && timeout "$TIMEOUT" "$AGDA" Unit.agda > out 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(clean "$d" < "$d/out")")
  return "$e"
}

# the string argument of the responses titled $1, one per line, decoded
# (Agda writes it as an Emacs Lisp string: \" \\ and \n escaped)
agda_info() {
  sed -e 's/^\(Agda2> \)*//' | grep -F "(agda2-info-action \"$1\" " \
    | sed -e 's/^(agda2-info-action "[^"]*" \(".*"\) [a-z]*)$/\1/' | jq -r . 2>/dev/null
}

check_unit() {
  local d=$1 e j n session goal="" ctx="" names=()
  if ! grep -q '^module[[:space:]]' <<< "${F[5]}"; then stat skipped_no_module; return 1; fi
  HEAD=$(printf '%s' "${F[5]}" | sed -E '0,/^module[[:space:]]+[^[:space:]]+/s//module Unit/'; printf x)
  HEAD=${HEAD%x}
  PRE=${F[6]}

  agda_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then stat "original_exit_$e"; return 1; fi
  local verdict=$CHECK

  # one session: the hole's goal (when there is a hole), then the names
  read -r -a names <<< "${F[9]}"
  session='IOTCM "Unit.agda" None Indirect (Cmd_load "Unit.agda" [])'$'\n'
  if [[ -n ${F[10]} ]]; then
    printf '%s%s%s' "$HEAD" "$PRE" "${F[10]}" > "$d/Unit.agda"
    session+='IOTCM "Unit.agda" None Indirect (Cmd_goal_type_context Simplified 0 noRange "")'$'\n'
  fi
  for n in "${names[@]}"; do
    session+="IOTCM \"Unit.agda\" None Indirect (Cmd_infer_toplevel Simplified \"$n\")"$'\n'
  done
  (cd "$d" && timeout "$TIMEOUT" "$AGDA" --interaction <<< "$session" > session 2>&1)
  if [[ -n ${F[10]} ]]; then
    goal=$(agda_info '*Goal type etc.*' < "$d/session")
    if [[ -n $goal ]]; then goal=$(check_of - "$goal"); stat hole; else stat hole_no_goal; fi
  fi
  # each Cmd_infer_toplevel answers an *Inferred Type* or an *Error*, in order
  ctx=$(sed -e 's/^\(Agda2> \)*//' "$d/session" \
    | grep -E '^\(agda2-info-action "\*(Inferred Type|Error)\*" ' | tail -n "${#names[@]}" \
    | while IFS= read -r line; do
        n=${names[0]}; names=("${names[@]:1}")
        if [[ $line == '(agda2-info-action "*Inferred Type*" '* ]]; then
          printf '%s : %s\n' "$n" "$(agda_info '*Inferred Type*' <<< "$line")"
        fi
      done | head -n "$CAP_LINES")
  [[ -n $ctx ]] && stat context

  local muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    agda_check "$d" "${F[j]}"
    e=$?
    if (( e == 0 )); then stat mutant_checks
    elif (( e == 124 )); then stat mutant_timeout
    else stat mutant_kept; muts+=("${F[j]}" "$CHECK"); fi
  done
  result "$verdict" "$ctx" "$goal" "" "${muts[@]}"
}

check_main "$@"
