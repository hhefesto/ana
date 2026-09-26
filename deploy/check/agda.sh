#!/usr/bin/env bash
# deploy/check/agda.sh: Agda checks Agda units (deploy/check/lib.sh has the
# input and output formats).
#
#   deploy/check/agda.sh UNITS.nul RESULTS.nul [JOBS]
#
# Run deploy/check/agda-libs.sh precompile first: it writes the library file
# (run/check-cache/agda/libraries) this script passes to Agda, pins every
# library's standard library, and leaves every library's interfaces built.
#
# A unit is checked inside its own library, where its file lives: the unit's
# file id (repo:NAME/path, own:NAME/path, curated:NAME/path) names a file
# under run/code-sources; the nearest .agda-lib above it is its library, and
# the include directory holding it is where the variant is written, as
# FTUnit<worker>.agda (the head's top-level module renamed to match), so the
# library's flags and dependencies apply and its other modules load from
# their interfaces. A file in no library is written at its module's root
# with standard-library-2.3 in scope; a unit whose file is not on disk (a
# Hackage package's data file) is written in the work directory the same
# way. Every output names the file Unit.agda, as the pilot's did.
#
# Every variant is the head, the declaration's signature, the variant. The
# tail is left out: Agda checks top-down, so nothing above a declaration
# depends on what follows it. Literate files arrive as the plain Agda
# bend-units made of them (bend/Units.bend, "Literate Agda").
#
#   check    agda FILE (status 42 on an error)
#   hole     the last one-line equation's right side replaced by `?`: in
#            interaction mode, Cmd_load then Cmd_goal_type_context, whose
#            display (the goal, a rule, the local context) is the check
#   Context  Cmd_infer_toplevel for each name the body uses, in the same
#            session: `name : type` for each name Agda can type
#   type     none
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CS=$ROOT/run/code-sources
LIBS=${AGDA_LIBS:-$ROOT/run/check-cache/agda/libraries}
WRAPPER=$(command -v "${AGDA:-agda}")
AGDA_BIN=$(grep -o '"/nix/store/[^"]*/bin/agda"' "$WRAPPER" | head -n 1 | tr -d '"')
[[ -n $AGDA_BIN ]] || AGDA_BIN=$WRAPPER
[[ -f $LIBS ]] || { echo "agda.sh: $LIBS missing: run deploy/check/agda-libs.sh" >&2; exit 1; }
TIMEOUT=${TIMEOUT:-120}

# where the unit's variants go: DIR (the include root, or the work
# directory), NAME (the module name the file must carry), EXTRA (the flags
# for a file in no library)
locate() {
  local d=$1 fid=${UNIT_ID%%#*} g rel base src dir lib inc incs mod mpath
  g=${fid%%/*}
  rel=${fid#*/}
  case $g in
    repo:*) base=$CS/repos/${g#repo:} ;;
    own:*) base=$CS/own/${g#own:} ;;
    curated:*) base=$CS/curated/${g#curated:} ;;
    *) base="" ;;
  esac
  NAME=FTUnit$(basename "$d")
  EXTRA=(-l standard-library-2.3)
  DIR=$d
  src=$base/$rel
  [[ -n $base && -f $src ]] || { stat placed_workdir; return; }
  dir=$(dirname "$src")
  lib=""
  while [[ $dir == "$base"* ]]; do
    local found=("$dir"/*.agda-lib)
    if [[ -f ${found[0]} && ${#found[@]} == 1 ]]; then lib=${found[0]}; break; fi
    dir=$(dirname "$dir")
  done
  if [[ -n $lib ]]; then
    incs=$(awk '/^include:/ { sub(/^include:[[:space:]]*/, ""); on = 1 } on && /^[a-z-]+:/ && !/^include:/ { on = 0 } on { print }' "$lib" | tr ' ' '\n' | sed '/^$/d')
    for inc in $incs; do
      inc=$(realpath -m "$(dirname "$lib")/$inc")
      if [[ $src == "$inc"/* ]]; then DIR=$inc; EXTRA=(); stat placed_library; return; fi
    done
  fi
  # no library: the root the module's name implies
  mod=$(grep -m 1 -oE '^module[[:space:]]+[^[:space:]]+' <<< "${F[5]}" | awk '{ print $2 }')
  if [[ -n $mod ]]; then
    mpath=${mod//./\/}
    local stem=${src%%.agda*}
    stem=${stem%.lagda}
    if [[ $stem == */"$mpath" ]]; then
      DIR=${stem%/"$mpath"}
      stat placed_root
      return
    fi
  fi
  stat placed_workdir
}

agda_clean() { sed -e "s|$DIR/||g; s|$1/||g; s|$NAME|Unit|g" | head -n "$CAP_LINES"; }

agda_write() {
  printf '%s%s%s' "$HEAD" "$PRE" "$1" > "$DIR/$NAME.agda"
}

agda_check() {
  local d=$1 e
  agda_write "$2"
  (cd "$DIR" && timeout "$TIMEOUT" "$AGDA_BIN" --library-file="$LIBS" "${EXTRA[@]}" "$NAME.agda" > "$d/out" 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(agda_clean "$d" < "$d/out")")
  return "$e"
}

# the string argument of the responses titled $1, one per line, decoded
# (Agda writes it as an Emacs Lisp string: \" \\ and \n escaped)
agda_info() {
  sed -e 's/^\(Agda2> \)*//' | grep -F "(agda2-info-action \"$1\" " \
    | sed -e 's/^(agda2-info-action "[^"]*" \(".*"\) [a-z]*)$/\1/' | jq -r . 2>/dev/null
}

# the head with its top-level module named $1 (a file without a module
# header is the module its file name says, so it is left as it is)
agda_head() {
  if grep -q '^module[[:space:]]' <<< "${F[5]}"; then
    printf '%s' "${F[5]}" | sed -E "0,/^module[[:space:]]+[^[:space:]]+/s//module $1/"
  else
    printf '%s' "${F[5]}"
  fi
}

# the response of the session's command $2 (1-based): the text after the
# $2-th prompt of the session output $1
agda_seg() { gawk -v RS='Agda2> ' -v k="$(( $2 + 1 ))" 'NR == k { printf "%s", $0; exit }' "$1"; }

# the first message of a response: its first info action other than
# progress, decoded
agda_msg() {
  grep -E '^\(agda2-info-action "' | grep -v -E '^\(agda2-info-action "\*(Type-checking|All Done)\*"' | head -n 1 \
    | sed -e 's/^(agda2-info-action "[^"]*" \(".*"\) [a-z]*)$/\1/' | jq -r . 2>/dev/null
}

check_unit() {
  local d=$1 e j n c=0 session="" goal="" ctx="" names=() seg line
  locate "$d"
  HEAD=$(agda_head "$NAME"; printf x)
  HEAD=${HEAD%x}
  PRE=${F[6]}

  # the original in batch mode: its output and exit status are the verdict
  agda_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then stat "original_exit_$e"; rm -f "$DIR/$NAME.agda"; return 1; fi
  local verdict=$CHECK

  # the rest in one interaction session, so the imports load once: the hole
  # (Cmd_load, then Cmd_goal_type_context), the names (Cmd_infer_toplevel),
  # then each mutant as a file of its own (module $NAME.m<j>, whose name is
  # printed as Unit like the others)
  read -r -a names <<< "${F[9]}"
  if [[ -n ${F[10]} ]]; then agda_write "${F[10]}"; fi
  session+="IOTCM \"$NAME.agda\" None Indirect (Cmd_load \"$NAME.agda\" [])"$'\n'; (( c++ ))
  local goal_at=0 names_at=$(( c + 1 ))
  if [[ -n ${F[10]} ]]; then
    session+="IOTCM \"$NAME.agda\" None Indirect (Cmd_goal_type_context Simplified 0 noRange \"\")"$'\n'; (( c++ ))
    goal_at=$c; names_at=$(( c + 1 ))
  fi
  for n in "${names[@]}"; do
    session+="IOTCM \"$NAME.agda\" None Indirect (Cmd_infer_toplevel Simplified \"$n\")"$'\n'; (( c++ ))
  done
  local mut_at=$(( c + 1 )) mfiles=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    local m=${NAME}m$j
    { agda_head "$m"; printf '%s%s' "$PRE" "${F[j]}"; } > "$DIR/$m.agda"
    mfiles+=("$DIR/$m.agda")
    session+="IOTCM \"$m.agda\" None Indirect (Cmd_load \"$m.agda\" [])"$'\n'; (( c++ ))
  done
  (cd "$DIR" && timeout "$(( TIMEOUT * 3 ))" "$AGDA_BIN" --library-file="$LIBS" "${EXTRA[@]}" --interaction <<< "$session" > "$d/session" 2>&1)
  rm -f "$DIR/$NAME.agda" "${mfiles[@]}"

  if (( goal_at > 0 )); then
    goal=$(agda_seg "$d/session" "$goal_at" | grep -F '(agda2-info-action "*Goal type etc.*" ' | agda_msg | sed -e "s/${NAME}m[0-9]*/Unit/g" | agda_clean "$d")
    if [[ -n $goal ]]; then goal=$(check_of - "$goal"); stat hole; else stat hole_no_goal; fi
  fi
  for (( j = 0; j < ${#names[@]}; j++ )); do
    line=$(agda_seg "$d/session" "$(( names_at + j ))" | grep -F '(agda2-info-action "*Inferred Type*" ' | agda_msg)
    [[ -n $line ]] && ctx+="${names[j]} : $line"$'\n'
  done
  ctx=$(printf '%s' "$ctx" | agda_clean "$d")
  [[ -n $ctx ]] && stat context

  # a mutant is kept when its load did not end "Checked": its check is the
  # first message Agda gave (status "-": interaction mode has no exit status)
  local muts=()
  for (( j = 11; j < ${#F[@]}; j++ )); do
    seg=$(agda_seg "$d/session" "$(( mut_at + j - 11 ))")
    if [[ -z $seg ]]; then stat mutant_no_response
    elif grep -qF '(agda2-status-action "Checked")' <<< "$seg"; then stat mutant_checks
    else
      line=$(agda_msg <<< "$seg" | sed -e "s/${NAME}m[0-9]*/Unit/g" | agda_clean "$d")
      if [[ -n $line ]]; then stat mutant_kept; muts+=("${F[j]}" "$(check_of - "$line")")
      else stat mutant_no_message; fi
    fi
  done
  result "$verdict" "$ctx" "$goal" "" "${muts[@]}"
}

check_main "$@"
