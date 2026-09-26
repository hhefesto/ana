#!/usr/bin/env bash
# deploy/check/agda-libs.sh: the Agda libraries deploy/check/agda.sh checks
# units against, set up once (idempotent).
#
#   deploy/check/agda-libs.sh [precompile]
#
# 1. Fetches what the sources need and the corpus does not hold, into
#    run/check-cache/agda/: standard library v2.4 (agda-categories pins it)
#    and the formal ledger's dependencies at the revisions its flake.lock
#    pins (agda-stdlib-classes, agda-stdlib-meta, agda-sets, iog-agda-prelude).
# 2. Pins, in the checkouts under run/code-sources (never in ~/src): every
#    unversioned `standard-library` dependency becomes standard-library-2.3,
#    the one Agda 2.8.0 ships with in nixpkgs (prebuilt in the store), except
#    for the libraries built on agda-categories, which take its 2.4; the
#    corpus's own agda-stdlib is 3.0 and serves its own units. HoTT-Agda's
#    three .agda-lib files, which share one directory (Agda refuses that),
#    move into their include directories.
# 3. Writes run/check-cache/agda/libraries, the --library-file agda.sh passes.
# 4. With `precompile`: type-checks every module of every library once, in
#    one interaction session per library (interfaces stay in memory between
#    files), so a unit's check loads interfaces instead of checking its
#    imports. Libraries run one after another; a module that fails is left
#    without an interface and every unit importing it fails later.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
CS=run/code-sources
C=run/check-cache/agda
mkdir -p "$C"
# the nixpkgs wrapper (AGDA, else agda on the PATH) execs the real binary
# with its own --library-file, which holds the prebuilt standard-library-2.3;
# the checker runs the real binary with its own library file instead
WRAPPER=$(command -v "${AGDA:-agda}")
AGDA_BIN=$(grep -o '"/nix/store/[^"]*/bin/agda"' "$WRAPPER" | head -n 1 | tr -d '"')
STDLIB23=$(dirname "$(grep -o '/nix/store/[^ ]*standard-library-2.3/standard-library.agda-lib' "$(grep -o -- '--library-file=[^ "]*' "$WRAPPER" | cut -d= -f2)" | head -n 1)")
log() { printf '%s %s\n' "$(TZ='<-06>6' date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

fetch() {
  local dir=$1 url=$2 rev=$3
  [[ -d $C/$dir ]] && return
  git init -q "$C/$dir"
  git -C "$C/$dir" fetch -q --depth 1 "$url" "$rev"
  git -C "$C/$dir" checkout -q FETCH_HEAD
}
fetch stdlib-2.4 https://github.com/agda/agda-stdlib v2.4
fetch stdlib-classes https://github.com/agda/agda-stdlib-classes e732956fb01eb616bb3429f290d9434f4ab59b6a
fetch stdlib-meta https://github.com/agda/agda-stdlib-meta ba0159a198c99185bda86541362f8e0a4a82538a
fetch agda-sets https://github.com/input-output-hk/agda-sets bc721845dba3208ce0aca59b09242f06d659fd97
fetch iog-prelude https://github.com/input-output-hk/iog-agda-prelude c6d5b0a46c60680e1ac11cec8b3a7749e9943839

# HoTT-Agda: one library per directory
h=$CS/repos/HoTT-Agda
for lib in core theorems test; do
  if [[ -f $h/hott-$lib.agda-lib ]]; then
    sed "s|^include: *$lib *\$|include: .|" "$h/hott-$lib.agda-lib" > "$h/$lib/hott-$lib.agda-lib"
    rm "$h/hott-$lib.agda-lib"
  fi
done

# every library file the checker may meet (the corpus's, the fetched ones)
libs=$(find "$CS/repos" "$CS/own" "$CS/curated" "$C" -name '*.agda-lib' \
  -not -path '*/.git/*' -not -path '*/_build/*' -not -path "$CS/repos/agda/*" \
  -not -path "$CS/repos/1lab/*" -not -path '*/tests/_config/*' -not -path '*stdlib*/dev/*' -not -path '*stdlib*/doc/*' -not -path "$CS/repos/cubical/*" -not -path '*/standard-library/*' \
  -exec grep -l '^name:' {} + | sort)   # a library without a name breaks the whole file

# the pins: an unversioned standard-library becomes 2.3, or 2.4 for the
# libraries on agda-categories (one program cannot hold two stdlibs)
for f in $libs; do
  case $f in
    */agda-stdlib/*|*/stdlib-2.4/*) continue ;;
  esac
  want=standard-library-2.3
  grep -q 'agda-categories' "$f" && want=standard-library-2.4
  sed -i -E "s/(^|[[:space:]:])standard-library([[:space:]]|\$)/\1$want\2/" "$f"
done

{ printf '%s\n' "$STDLIB23/standard-library.agda-lib"; for f in $libs; do realpath "$f"; done; } > "$C/libraries"
log "agda-libs: $(wc -l < "$C/libraries") libraries in $C/libraries"

# the modules of a library: every Agda source under its include directories
modules() {
  local f=$1 d inc
  d=$(dirname "$f")
  awk '/^include:/ { sub(/^include:[[:space:]]*/, ""); inc = 1 } inc && /^[a-z-]+:/ && !/^include:/ { inc = 0 } inc { print }' "$f" \
    | tr ' ' '\n' | sed '/^$/d' | while read -r inc; do
        find "$d/$inc" -type f \( -name '*.agda' -o -name '*.lagda.md' -o -name '*.lagda' -o -name '*.lagda.tex' \) \
          -not -path '*/_build/*' -not -name 'FTUnit*' 2>/dev/null
      done | sort -u
}

precompile() {
  local f n ok out
  for f in $(sed 1d "$C/libraries"); do
    case $f in */stdlib-2.4/*|*/tests/*|*/dev/*|*/doc/*) continue ;; esac
    out=$C/precompile-$(basename "$f" .agda-lib).log
    [[ -s $out ]] && { log "precompile: $(basename "$f") done already"; continue; }
    n=$(modules "$f" | wc -l)
    log "precompile: $(basename "$f"): $n modules"
    modules "$f" | while read -r m; do
      printf 'IOTCM "%s" None Indirect (Cmd_load "%s" [])\n' "$(realpath "$m")" "$(realpath "$m")"
    done > "$out.cmds"
    # sessions of 300 files: a session that runs out of heap loses only its
    # batch's remainder, and interfaces written so far are kept on disk
    rm -f "$out.tmp" "$out".batch.*
    split -l 300 -d -a 3 "$out.cmds" "$out.batch."
    for b in "$out".batch.*; do
      (cd "$(dirname "$f")" && "$AGDA_BIN" --library-file="$repo/$C/libraries" --interaction +RTS -M10G -RTS < "$repo/$b" >> "$repo/$out.tmp" 2>&1) || true
    done
    rm -f "$out".batch.*
    ok=$(grep -c '(agda2-status-action "Checked")' "$out.tmp" || true)
    mv "$out.tmp" "$out"
    log "precompile: $(basename "$f"): $ok of $n modules checked"
  done
}

[[ ${1:-} == precompile ]] && precompile
exit 0
