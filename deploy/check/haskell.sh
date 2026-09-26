#!/usr/bin/env bash
# deploy/check/haskell.sh: GHC checks Haskell units (deploy/check/lib.sh has
# the input and output formats).
#
#   deploy/check/haskell.sh UNITS.nul RESULTS.nul [JOBS]
#
# GHC (default run/check-cache/ghc-harness/bin/ghc, `nix build
# .#ghc-harness -o run/check-cache/ghc-harness`) is GHC 9.10.3 with the
# packages in deploy/check/ghc-packages.txt.
#
# A unit is checked inside its own package. Its file id names a file: a
# Hackage package's (hackage:PKG/path, unpacked from its tarball under
# run/check-cache/hs/src) or a repository's (repo:, own:, curated: under
# run/code-sources). The package is the nearest directory above the file
# holding a .cabal file (else the repository). Two ways to see it:
#
#   installed  the package, at the source's version, is in GHC's database
#              (GHC's own libraries, whose sources carry a .cabal.in, and
#              any Hackage package the harness has): the unit's imports
#              come from it, -package NAME
#   tree       otherwise: the package's source directories are the import
#              path (-i: the .cabal's hs-source-dirs, and the root the
#              file's own module name implies), with the .cabal's
#              default-extensions, default-language, include-dirs and
#              cpp-options. Once per package, before its first unit, GHC
#              type-checks the package's unit files with -fwrite-interface
#              into run/check-cache/hs/hi/<package>, so a unit's check
#              reads its imports' interfaces instead of checking them.
#
# Every unit of a package goes to one worker (lib.sh's KEYS), so a
# package's interfaces are written by one process.
#
# Every variant is written as Unit.hs in the worker's directory: the file
# with its module renamed Unit (GHC wants the file name to match), the
# variant in the body's place.
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
# a write to a GHCi that died must fail, not kill the worker with SIGPIPE
trap '' PIPE

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CS=$ROOT/run/code-sources
HC=${HC:-$ROOT/run/check-cache/hs}
GHC=${GHC:-$ROOT/run/check-cache/ghc-harness/bin/ghc}
GHC_PKG=$(dirname "$GHC")/ghc-pkg
FLAGS=(-fno-code -w -fdiagnostics-color=never -fno-show-valid-hole-fits +RTS -M2G -RTS)
SESSION_TIMEOUT=${SESSION_TIMEOUT:-7200}
mkdir -p "$HC/src" "$HC/hi" "$HC/info"

# a Hackage package name -> its tarball
declare -A TARBALL=()
for t in "$CS"/tarballs/*.tar.gz; do
  b=${t##*/}; b=${b%.tar.gz}
  TARBALL[${b%-*}]=$b
done
# the packages GHC has, as name-version and as name
declare -A HAVE=()
for p in $("$GHC_PKG" list --simple-output --names-only 2>/dev/null) $("$GHC_PKG" list --simple-output 2>/dev/null); do
  HAVE[$p]=1
done

# packages that export modules other packages also export (a real clash,
# not a re-export): hidden unless a package's .cabal asks for them
HIDE=()
for p in rerebase relude monads-tf crypton base-compat-batteries ghc-lib-parser ghc-lib ram \
         regex-pcre-builtin skylighting-core; do
  [[ -n ${HAVE[$p]:-} ]] && HIDE+=(-hide-package "$p")
done

# the directory of a group (empty: a Hackage package, unpacked on demand)
group_dir() {
  case $1 in
    repo:*) printf '%s' "$CS/repos/${1#repo:}" ;;
    own:*) printf '%s' "$CS/own/${1#own:}" ;;
    curated:*) printf '%s' "$CS/curated/${1#curated:}" ;;
    hackage:*) local b=${TARBALL[${1#hackage:}]:-}; [[ -n $b ]] && printf '%s' "$HC/src/$b" ;;
  esac
}

# KEYS: every unit's package (a Hackage package, or the nearest .cabal /
# .cabal.in directory under its repository, or the repository)
make_keys() {
  local in=$1 keys=$2
  find "$CS/repos" "$CS/own" "$CS/curated" \( -name '*.cabal' -o -name '*.cabal.in' \) \
    -not -path '*/.git/*' -not -path '*/dist-newstyle/*' -printf '%h\n' 2>/dev/null | sort -u > "$HC/cabal-dirs"
  gawk -v RS='\0' -v cs="$CS" -v dirs="$HC/cabal-dirs" '
    BEGIN { RS = "\n"; while ((getline d < dirs) > 0) has[d] = 1; RS = "\0" }
    NR % 2 == 0 { next }
    {
      id = $0; f = id; sub(/#.*/, "", f)
      g = f; sub(/\/.*/, "", g); rel = substr(f, length(g) + 2)
      if (g ~ /^hackage:/) { print id "\t" g; next }
      base = g; sub(/^repo:/, cs "/repos/", base); sub(/^own:/, cs "/own/", base); sub(/^curated:/, cs "/curated/", base)
      p = base "/" rel; key = base
      while ((i = match(p, /\/[^\/]*$/)) > 0) { p = substr(p, 1, i - 1); if (p in has) { key = p; break }; if (length(p) <= length(base)) break }
      print id "\t" key
    }' "$in" > "$keys"
}

# PKG_* for the package of the current unit: its directory, mode, flags
declare -A DONE=()
pkg_setup() {
  local d=$1 fid=${UNIT_ID%%#*} g rel key src cabal name ver info
  g=${fid%%/*}; rel=${fid#*/}
  PKG_DIR=$(group_dir "$g")
  [[ -n $PKG_DIR ]] || { PKG_MODE=none; return; }
  if [[ $g == hackage:* && ! -d $PKG_DIR ]]; then
    tar xzf "$CS/tarballs/${PKG_DIR##*/}.tar.gz" -C "$HC/src" 2>/dev/null || { PKG_MODE=none; return; }
  fi
  src=$PKG_DIR/$rel
  [[ -f $src ]] || { PKG_MODE=none; return; }
  # the package directory: the nearest .cabal above the file
  local dir=${src%/*}
  cabal=""
  while :; do
    local c=("$dir"/*.cabal "$dir"/*.cabal.in)
    for x in "${c[@]}"; do [[ -f $x ]] && { cabal=$x; break; }; done
    [[ -n $cabal || $dir == "$PKG_DIR" || $dir != "$PKG_DIR"/* ]] && break
    dir=${dir%/*}
  done
  [[ -n $cabal ]] && PKG_DIR=${cabal%/*}
  key=$(printf '%s' "$PKG_DIR" | sha256sum | cut -c1-16)
  PKG_KEY=$key
  PKG_HI=$HC/hi/$key
  info=$HC/info/$key
  if [[ ! -f $info ]]; then
    name=""; ver=""
    if [[ -n $cabal ]]; then
      # a .cabal written on Windows ends its lines in CR: deleted
      name=$(awk '{ gsub(/\r/, "") } tolower($1) == "name:" { print $2; exit }' "$cabal")
      ver=$(awk '{ gsub(/\r/, "") } tolower($1) == "version:" { print $2; exit }' "$cabal")
    fi
    local mode=tree
    if [[ -n $name && ( $cabal == *.cabal.in || -n ${HAVE[$name-$ver]:-} ) && -n ${HAVE[$name]:-} ]]; then mode=installed; fi
    {
      printf 'mode\t%s\nname\t%s\n' "$mode" "$name"
      if [[ -n $cabal ]]; then
        # every stanza's fields, conditionals ignored; a field's value runs
        # over the indented lines after it
        awk '
          function flush() { if (f != "") print f "\t" v; f = ""; v = "" }
          { gsub(/\r/, "") }
          /^[[:space:]]*--/ { next }
          match($0, /^[[:space:]]*[A-Za-z-]+:/) {
            flush(); k = tolower(substr($0, RSTART, RLENGTH)); gsub(/[[:space:]:]/, "", k)
            if (k == "hs-source-dirs" || k == "default-extensions" || k == "extensions" || k == "default-language" || k == "include-dirs" || k == "cpp-options" || k == "build-depends") { f = k; v = substr($0, RSTART + RLENGTH) }
            next
          }
          f != "" && /^[[:space:]]/ { v = v " " $0; next }
          { flush() }
          END { flush() }' "$cabal" | while IFS=$'\t' read -r k v; do
            if [[ $k == build-depends ]]; then
              # a dependency is the first word of each comma-separated item
              tr ',' '\n' <<< "$v" | awk 'match($1, /^[A-Za-z][A-Za-z0-9-]*/) { print substr($1, 1, RLENGTH) }' | sed "s/^/$k\t/"
            else
              for w in $(tr ',' ' ' <<< "$v"); do printf '%s\t%s\n' "$k" "$w"; done
            fi
          done | sort -u
      fi
    } > "$info"
  fi
  PKG_MODE=$(awk -F'\t' '$1 == "mode" { print $2 }' "$info")
  PKG_NAME=$(awk -F'\t' '$1 == "name" { print $2 }' "$info")
  PKG_FLAGS=()
  if [[ $PKG_MODE == installed ]]; then
    PKG_FLAGS=("${HIDE[@]}" -package "$PKG_NAME")
    return
  fi
  # tree: one set of flags for the whole package (GHC fingerprints them into
  # each interface, and a check with other flags would recheck its imports)
  if [[ -z ${DONE[$key]:-} ]]; then
    DONE[$key]=1
    if ! grep -q '^root' "$info"; then
      # the unit files of the package, and the roots their module names imply
      local pkey files f mod stem
      pkey=$(awk -F'\t' -v id="$UNIT_ID" '$1 == id { print $2; exit }' "$KEYS")
      files=$(awk -F'\t' -v k="$pkey" '$2 == k { print $1 }' "$KEYS" | sed -e 's/#.*//' -e 's|^[^/]*/||' | sort -u \
        | while read -r f; do [[ -f $(group_dir "$g")/$f ]] && printf '%s\n' "$(group_dir "$g")/$f"; done)
      printf '%s\n' "$files" | sed '/^$/d' | sed 's/^/file\t/' >> "$info"
      for f in $files; do
        mod=$(grep -m 1 -oE "^module[[:space:]]+[A-Za-z0-9_.']+" "$f" | awk '{ print $2 }')
        stem=${f%.hs}
        [[ -n $mod && $stem == */"${mod//.//}" ]] && printf 'root\t%s\n' "${stem%/"${mod//.//}"}"
      done | sort -u >> "$info"
      printf 'root\t%s\n' "$PKG_DIR" >> "$info"
    fi
  fi
  local r k v deps=()
  while IFS=$'\t' read -r k v; do
    case $k in
      build-depends) [[ $v != "$PKG_NAME" && -n ${HAVE[$v]:-} ]] && deps+=(-package "$v") ;;
      root) PKG_FLAGS+=("-i$v") ;;
      hs-source-dirs) r=$(realpath -m "$PKG_DIR/$v"); PKG_FLAGS+=("-i$r") ;;
      default-extensions|extensions|default-language) PKG_FLAGS+=("-X$v") ;;
      include-dirs) PKG_FLAGS+=("-I$(realpath -m "$PKG_DIR/$v")") ;;
      cpp-options) PKG_FLAGS+=("$v") ;;
    esac
  done < "$info"
  # as cabal would: only the package's own dependencies are visible (with no
  # .cabal to say which, all of GHC's but the clashing ones)
  if (( ${#deps[@]} > 0 )); then PKG_FLAGS+=(-hide-all-packages "${deps[@]}"); else PKG_FLAGS+=("${HIDE[@]}"); fi
  PKG_FLAGS+=(-hidir "$PKG_HI")
}

# ghc on HEAD ++ PRE ++ $2 ++ TAIL, extra flags after $2; CHECK is the check.
# -fwrite-interface: the first batch check of a package leaves its imports'
# interfaces in the package's -hidir, so every later one reads them.
# Unit's own interface is removed first, so Unit is always compiled (and
# says so); the lines about the package's other modules are left out.
hs_check() {
  local d=$1 body=$2 e
  printf '%s%s%s%s' "$HEAD" "$PRE" "$body" "$TAIL" > "$d/Unit.hs"
  [[ -n ${PKG_HI:-} ]] && rm -f "$PKG_HI/Unit.hi"
  rm -f "$d/Unit.hi"
  (cd "$d" && timeout "$TIMEOUT" "$GHC" "${FLAGS[@]}" -fwrite-interface "${PKG_FLAGS[@]}" "${@:3}" Unit.hs > out 2>&1)
  e=$?
  CHECK=$(check_of "$e" "$(grep -v -E '^\[ *[0-9]+ of [0-9]+\] (Compiling|Skipping) +[^U ]|^\[ *[0-9]+ of [0-9]+\] (Compiling|Skipping) +U[^n]|^\[ *[0-9]+ of [0-9]+\] (Compiling|Skipping) +Un[^i]|^\[ *[0-9]+ of [0-9]+\] (Compiling|Skipping) +Uni[^t]|^\[ *[0-9]+ of [0-9]+\] (Compiling|Skipping) +Unit[^ ]' "$d/out" | clean "$d")")
  return "$e"
}

# One GHCi session per package (a worker holds all of a package's units):
# every variant but the original's verdict is a :load of Unit.hs into it, so
# the package's modules are type-checked once per session, not once per
# check. GHCi prints the errors ghc prints; its progress lines and its
# closing "Ok, ..."/"Failed, ..." line are left out of a check, and a check
# made here has status "-" (GHCi has no exit status).
SESSION_KEY=""
session_stop() {
  if [[ -n ${GH_PID:-} ]]; then
    [[ -n ${GH[1]:-} ]] && printf ':quit\n' >&"${GH[1]}" 2>/dev/null
    kill "$GH_PID" 2>/dev/null
    wait "$GH_PID" 2>/dev/null
  fi
  GH_PID=""; SESSION_KEY=""
}
session_start() {
  local d=$1
  session_stop
  cd "$d" || return 1
  coproc GH { exec timeout "$SESSION_TIMEOUT" "$GHC" --interactive -ignore-dot-ghci -v1 "${FLAGS[@]}" "${PKG_FLAGS[@]}" 2>&1; }
  GH_PID=$GH_PID
  cd - > /dev/null
  SESSION_KEY=$PKG_KEY
  session ':set prompt ""' && session ':set prompt-cont ""'
}
# send $1; SOUT is what came back. Status 1 (and the session stopped) when
# nothing came back in time. Never called in a subshell: a subshell has no
# access to the coprocess.
session() {
  local line ok=1
  SOUT=""
  [[ -n ${GH_PID:-} && -n ${GH[1]:-} ]] || return 1
  printf '%s\n:!echo @@@END\n' "$1" >&"${GH[1]}" 2>/dev/null || { session_stop; return 1; }
  while IFS= read -r -t "$TIMEOUT" line <&"${GH[0]}"; do
    if [[ $line == *@@@END ]]; then line=${line%@@@END}; [[ -n $line ]] && SOUT+=$line$'\n'; ok=0; break; fi
    SOUT+=$line$'\n'
  done
  if (( ok != 0 )); then session_stop; return 1; fi
  return 0
}
# load a variant: LOADED is the session's answer, LOAD_OK whether it loaded
session_load() {
  local d=$1
  printf '%s%s%s%s' "$HEAD" "$PRE" "$2" "$TAIL" > "$d/Unit.hs"
  LOAD_OK=0
  session ':load Unit.hs' || return 1
  LOADED=$SOUT
  grep -q '^Ok, ' <<< "$LOADED" && LOAD_OK=1
  return 0
}
session_text() {
  grep -v -E '^\[ *[0-9]+ of [0-9]+\] Compiling |^(Ok|Failed), .* loaded\.$' <<< "$LOADED" | clean "$1"
}

check_unit() {
  local d=$1 e j n cmds="" ctx="" hole="" typ="" block
  if ! grep -q '^module[[:space:]]' <<< "${F[5]}"; then stat skipped_no_module; return 1; fi
  pkg_setup "$d"
  [[ $PKG_MODE == none ]] && { stat placed_no_source; PKG_FLAGS=(); PKG_KEY=none; }
  stat "mode_$PKG_MODE"
  HEAD=$(printf '%s' "${F[5]}" | sed -E "0,/^module[[:space:]]+[A-Za-z0-9_.']+/s//module Unit/"; printf x)
  HEAD=${HEAD%x}
  PRE=${F[6]}
  TAIL=${F[8]}

  if [[ $SESSION_KEY != "$PKG_KEY" || -z ${GH_PID:-} ]]; then
    session_start "$d" || { stat session_start_failed; return 1; }
  fi
  if ! session_load "$d" "${F[7]}"; then stat original_session_timeout; return 1; fi
  if (( LOAD_OK == 0 )); then
    if grep -q 'Could not \(find\|load\) module' <<< "$LOADED"; then stat original_missing_module
    else stat original_fails; fi
    return 1
  fi
  # the Context, from the original as loaded
  for n in ${F[9]}; do cmds+=":type $n"$'\n'; done
  if [[ -n $cmds ]]; then
    session "${cmds%$'\n'}"
    ctx=$(printf '%s' "$SOUT" | awk '/^<interactive>/ { keep = 0; next } /^[^ \t]/ { keep = ($0 ~ / :: /) } keep' | clean "$d")
    [[ -n $ctx ]] && stat context
  fi

  # the verdict: ghc itself, in batch mode, on the original
  hs_check "$d" "${F[7]}"
  e=$?
  if (( e != 0 )); then stat "original_batch_exit_$e"; return 1; fi
  local verdict=$CHECK

  if [[ -n ${F[10]} ]]; then
    if session_load "$d" "${F[10]}" && (( LOAD_OK == 0 )); then hole=$(check_of - "$(session_text "$d")"); stat hole
    else stat hole_not_failing; fi
  fi

  # the type: the original without its signature, -Wmissing-signatures on
  PRE=""
  session ':set -Wmissing-signatures'
  if session_load "$d" "${F[7]}" && (( LOAD_OK == 1 )); then
    block=$(awk -v name="${F[2]}" '
      /^Unit\.hs:/ { if (keep) printf "%s", blk; blk = ""; keep = 0 }
      /^\[ *[0-9]+ of [0-9]+\] Compiling |^(Ok|Failed), .* loaded\.$/ { next }
      { blk = blk $0 "\n"; if (index($0, name " ::") > 0 && blk ~ /missing-signatures/) keep = 1 }
      END { if (keep) printf "%s", blk }' <<< "$LOADED" | clean "$d")
    if [[ -n $block ]]; then typ=$(check_of - "$block"); stat type; else stat type_no_warning; fi
  else
    stat type_not_loaded
  fi
  session ':set -w'
  PRE=${F[6]}

  # mutants: the first two the checker rejects, from a start the unit's id
  # picks (a transcript uses at most two)
  local muts=() nm=$(( ${#F[@]} - 11 )) start i kept=0
  if (( nm > 0 )); then
    start=$(( $(cksum <<< "$UNIT_ID" | cut -d' ' -f1) % nm ))
    for (( i = 0; i < nm && kept < 2; i++ )); do
      j=$(( 11 + (start + i) % nm ))
      if ! session_load "$d" "${F[j]}"; then stat mutant_timeout; session_start "$d" || break; continue; fi
      if (( LOAD_OK == 1 )); then stat mutant_checks
      else stat mutant_kept; muts+=("${F[j]}" "$(check_of - "$(session_text "$d")")"); (( kept++ )); fi
    done
  fi
  result "$verdict" "$ctx" "$hole" "$typ" "${muts[@]}"
}

KEYS=$(mktemp)
make_keys "${1:?usage: $0 UNITS.nul RESULTS.nul [JOBS]}" "$KEYS"
export KEYS
check_main "$@"
rm -f "$KEYS"
