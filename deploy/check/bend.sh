#!/usr/bin/env bash
# deploy/check/bend.sh: Bend checks Bend units (deploy/check/lib.sh has the
# input and output formats).
#
#   BEND=bend BEND_SRC=~/src deploy/check/bend.sh UNITS.nul RESULTS.nul [JOBS]
#
# A unit's file id is `own:<path under BEND_SRC>`. Bend imports are paths
# relative to the file, so each worker copies the .bend files of the unit's
# repository (the path's first component) once, and writes every variant
# as Unit.bend beside the original: the head, the declaration's first part
# (a law, or a def's header), the variant. The tail is left out: a def may
# only call the defs above it.
#
#   check    bend Unit.bend --check-only (it reports the first error only)
#   hole     the body replaced by `?goal`: the error shows the goal and
#            the context
#   Context  for each name the body uses, the header of its definition:
#            `bend base NAME` for a name of Base, else the file's own
#            `def NAME(...) -> T` or `law NAME:` line
#   type     none
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEND=${BEND:-bend}
BEND_SRC=$(realpath "${BEND_SRC:-$HOME/src}")
declare -A BASE=()

bend_check() {
  local d=$1 body=$2 e
  printf '%s%s%s' "${F[5]}" "${F[6]}" "$body" > "$UNIT_DIR/Unit.bend"
  (cd "$UNIT_DIR" && timeout "$TIMEOUT" "$BEND" Unit.bend --check-only > "$d/out" 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(clean "$d" < "$d/out")")
  return "$e"
}

# the header of NAME's definition, as Context
bend_sig() {
  local n=$1 line
  line=$(grep -m 1 -E "^(def|law) $(sed 's/[.[\*^$]/\\&/g' <<< "$n")[(:]" <<< "${F[5]}")
  if [[ -n $line ]]; then printf '%s\n' "${line%:}"; return; fi
  if [[ -z ${BASE[$n]+set} ]]; then
    BASE[$n]=$("$BEND" base "$n" 2>/dev/null | head -n 1 | grep -E '^(def|law|type) ')
  fi
  [[ -n ${BASE[$n]} ]] && printf '%s\n' "${BASE[$n]%:}"
}

check_unit() {
  local d=$1 e j n rel repo ctx="" hole=""
  rel=${UNIT_ID#own:}
  rel=${rel%"#${F[2]}@"*}
  repo=${rel%%/*}
  if [[ ! -f $BEND_SRC/$rel ]]; then stat skipped_no_source; return 1; fi
  if [[ ! -d $d/src/$repo ]]; then
    (cd "$BEND_SRC" && find "$repo" -name '*.bend' -not -path '*/node_modules/*' -print0 \
      | while IFS= read -r -d '' f; do mkdir -p "$d/src/${f%/*}"; cp "$f" "$d/src/$f"; done)
  fi
  UNIT_DIR=$d/src/${rel%/*}

  bend_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then stat "original_exit_$e"; return 1; fi
  local verdict=$CHECK

  ctx=$(for n in ${F[9]}; do bend_sig "$n"; done | head -n "$CAP_LINES")
  [[ -n $ctx ]] && stat context
  if [[ -n ${F[10]} ]]; then
    bend_check "$d" "${F[10]}"
    e=$?
    if (( e == 1 )); then hole=$CHECK; stat hole; else stat "hole_exit_$e"; fi
  fi
  local muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    bend_check "$d" "${F[j]}"
    e=$?
    if (( e == 0 )); then stat mutant_checks
    elif (( e == 124 )); then stat mutant_timeout
    else stat mutant_kept; muts+=("${F[j]}" "$CHECK"); fi
  done
  rm -f "$UNIT_DIR/Unit.bend"
  result "$verdict" "$ctx" "$hole" "" "${muts[@]}"
}

check_main "$@"
