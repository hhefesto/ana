#!/usr/bin/env bash
# extract-code.sh — build a {id, text} JSONL code corpus from Hackage tarballs
# and cloned repositories.
#
# This replaces The Stack. That dataset pre-computed two things for us --
# permissive-license filtering and near-duplicate removal -- and both are done
# here explicitly instead, which is why they are gates that report their counts
# rather than silent filters. What it cannot replace is currency: its snapshots
# are from 2022 and pre-date the Lean 4 ecosystem entirely.
#
# Ids are `group/path`, so `plan-corpus.sh`'s PACK_GROUP packs within a package
# or repository and a training window never straddles two unrelated projects.
#
# Usage: deploy/extract-code.sh OUT.jsonl [SOURCES_DIR]
set -euo pipefail

OUT="${1:?usage: extract-code.sh OUT.jsonl [SOURCES_DIR]}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
SOURCES="${2:-run/code-sources}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source extensions. Everything else in a package -- READMEs, changelogs,
# generated C, test fixtures -- stays out.
EXTENSIONS='\.(hs|lhs|nix|agda|lagda|lean|idr|ipkg)$'

# A permissive license, by the names Cabal and SPDX actually use. Anything
# GPL-family, unstated, or unrecognized is dropped: the default is exclusion,
# because a wrong guess here ends up in model weights.
permissive() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' ')" in
    bsd3|bsd-3-clause|bsd2|bsd-2-clause|bsd-2-clause-patent|mit|isc|\
    apache-2.0|apache2.0|apache|mpl-2.0|mpl2.0|publicdomain|cc0-1.0|unlicense|\
    bsd3clause|0bsd|zlib|bsd) return 0 ;;
    *) return 1 ;;
  esac
}

emitted=0; skipped_license=0; skipped_binary=0; considered=0

# Everything below writes `hash<TAB>jsonline` to stdout; the tail of the script
# drops duplicate content in one pass. Vendored copies are rampant in this
# ecosystem -- every vendored Setup.hs, every re-released package version -- so
# a collision rate in the tens of percent is expected, and a rate near zero
# means the hashing is broken rather than the corpus being clean.
generate() {

# One record per file: id, then the text, hashed so duplicates can be dropped
# downstream in a single pass. NUL bytes and invalid UTF-8 are removed here
# rather than in jq, which would abort the whole stream on one bad byte.
emit_file() {
  local group="$1" path="$2" rel="$3" size
  size=$(stat -c %s "$path" 2>/dev/null || echo 0)
  # Skip empty files and anything over 1 MB, which at this point is generated
  # code or a vendored blob rather than something a person wrote.
  [ "$size" -gt 0 ] && [ "$size" -le 1000000 ] || { skipped_binary=$((skipped_binary+1)); return 0; }
  local clean="$WORK/clean"
  tr -d '\000' < "$path" | iconv -f UTF-8 -t UTF-8 -c > "$clean" 2>/dev/null || return 0
  [ -s "$clean" ] || return 0
  local hash
  hash=$(sha256sum < "$clean" | cut -d' ' -f1)
  printf '%s\t' "$hash"
  jq -c -Rs --arg id "$group/$rel" '{id:$id, text:.}' < "$clean"
  emitted=$((emitted+1))
}

echo "extract-code: Hackage tarballs" >&2
if [ -d "$SOURCES/tarballs" ]; then
  for tarball in "$SOURCES"/tarballs/*.tar.gz; do
    [ -e "$tarball" ] || continue
    considered=$((considered+1))
    pv="$(basename "$tarball" .tar.gz)"
    package="${pv%-*}"
    rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg"
    tar xzf "$tarball" -C "$WORK/pkg" 2>/dev/null || continue
    cabal="$(find "$WORK/pkg" -maxdepth 2 -name '*.cabal' -print -quit 2>/dev/null || true)"
    [ -n "$cabal" ] || { skipped_license=$((skipped_license+1)); continue; }
    license="$(sed -n 's/^[Ll]icense:[[:space:]]*//p' "$cabal" | head -1 | tr -d '\r')"
    permissive "$license" || { skipped_license=$((skipped_license+1)); continue; }
    while IFS= read -r file; do
      emit_file "$package" "$file" "${file#$WORK/pkg/$pv/}"
    done < <(find "$WORK/pkg" -type f 2>/dev/null | grep -Ei "$EXTENSIONS" || true)
  done
fi

echo "extract-code: cloned repositories" >&2
for tree in "$SOURCES"/repos/*/ "$SOURCES"/own/*/; do
  [ -d "$tree" ] || continue
  considered=$((considered+1))
  name="$(basename "$tree")"
  # Repository licenses are prose, not a field, so match on the text. The
  # user's own repositories are included regardless: they are the whole point
  # of the corpus and their licensing is theirs to decide.
  if [ "$(dirname "${tree%/}")" != "$SOURCES/own" ]; then
    # Read the whole file, not a window: MIT and BSD both open with a
    # copyright roll and only reach the grant clause further down, which is how
    # an earlier version of this gate rejected agda and agda-stdlib. Match the
    # grant text rather than the license's name, and accept LICENCE as well as
    # LICENSE -- agda-stdlib uses the British spelling.
    # The PRIMARY license file only. A repository's own terms live in
    # LICENSE/LICENCE/COPYING; a file like lean4's LICENSES is an 82 KB bundle
    # of its third-party dependencies' terms, four of them GPL-family, and
    # reading it condemned Lean's own Apache-2.0 source.
    licensetext=""
    for candidate in LICENSE LICENCE COPYING LICENSE.md LICENCE.md LICENSE.txt LICENCE.txt COPYING.md; do
      if [ -f "$tree$candidate" ]; then
        licensetext="$(cat "$tree$candidate")"
        break
      fi
    done
    # Copyleft is checked first and wins: a file can name MIT in passing while
    # actually being AGPL, and the safe direction of a wrong guess is exclusion.
    if printf '%s' "$licensetext" | grep -qEi 'GNU (GENERAL|LESSER|AFFERO) PUBLIC LICENSE'; then
      skipped_license=$((skipped_license+1)); continue
    fi
    if ! printf '%s' "$licensetext" | grep -qEi \
        'Permission is hereby granted, free of charge|Redistribution and use in source|Apache License|ISC License|Mozilla Public License|CC0|public domain|MIT License'; then
      skipped_license=$((skipped_license+1)); continue
    fi
  fi
  while IFS= read -r file; do
    emit_file "$name" "$file" "${file#$tree}"
  done < <(find "$tree" -type f -not -path '*/.git/*' 2>/dev/null | grep -Ei "$EXTENSIONS" || true)
done

echo "extract-code: $considered sources considered, $skipped_license dropped on license, $skipped_binary files skipped by size, $emitted files emitted" >&2
}

generate | awk -F'\t' -v out="$OUT" '
  { total++ }
  !seen[$1]++ { sub(/^[^\t]*\t/, ""); print > out; kept++ }
  END {
    printf "extract-code: %d files, %d unique, %d duplicates dropped (%.1f%%)\n",
      total, kept, total - kept, total ? 100 * (total - kept) / total : 0 > "/dev/stderr"
  }'
test -s "$OUT" || { echo "extract-code: produced nothing" >&2; exit 1; }
echo "extract-code: wrote $OUT ($(wc -l < "$OUT") documents, $(du -h "$OUT" | cut -f1))" >&2
