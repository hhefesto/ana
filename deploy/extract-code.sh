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
# The group carries its source as a namespace -- hackage:foo, repo:foo, own:foo
# -- because the three pools share bare names: the Hackage PACKAGE cubical and
# the Agda REPOSITORY cubical are different projects, and a bare name in
# HOLDOUT_GROUPS once matched both, putting seven Haskell files into the Agda
# repo's holdout.  (The percent bucket still hashes the BARE name, so the
# sampled 2% is the same population it was before the namespacing.)
#
# Usage: deploy/extract-code.sh OUT.jsonl [SOURCES_DIR]
set -euo pipefail

OUT="${1:?usage: extract-code.sh OUT.jsonl [SOURCES_DIR]}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
SOURCES="${2:-run/code-sources}"
WORK="$(mktemp -d)"
# Extracted packages can contain mode-555 directories, so make the tree
# writable before removing it or the trap itself fails.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true' EXIT

# Source extensions. Everything else in a package -- READMEs, changelogs,
# generated C, test fixtures -- stays out.
EXTENSIONS='\.(hs|lhs|nix|agda|lagda|lagda\.md|lagda\.tex|lagda\.rst|lean|idr|ipkg|bend)$'

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

emitted=0; skipped_license=0; skipped_binary=0; considered=0; held=0
processed=0; unreadable=0; tarball_count=0; undecodable=0

# Held-out evaluation sources are chosen WHOLE, by a hash of the package or
# repository name, and never by document position. The trainer's own
# train/validation split is a hash of position (FormalTransformer.Data), so a
# position-based holdout of code would put files from the same package -- often
# the same file, vendored -- on both sides of it. Holding out entire projects
# is the only split that means anything for code.
#
# The user's own repositories are never held out: they are the point of the
# corpus, there are only a few MB of them, and 2% of that is too little to
# measure anything with anyway.
HOLDOUT_OUT="${HOLDOUT_OUT:-}"
HOLDOUT_PERCENT="${HOLDOUT_PERCENT:-2}"

# A percentage alone cannot hold out the non-Haskell languages. Hackage has
# 19,418 packages, so 2% of it is a healthy Haskell eval; but Lean, Agda, Nix
# and Idris live in about eight repositories between them, and 2% of eight is
# zero. The first version of this produced a held-out set that was 100% Haskell
# and would have silently yielded four empty evaluation corpora.
#
# So those languages name their holdout explicitly. Entries are id prefixes, so
# a whole repository (cubical) or a subtree of one (nixpkgs/nixos) both work.
# Whole repositories are preferred where a language has more than one, because
# holding out cubical while training on agda-stdlib tests generalization across
# projects; holding out a subtree of a single repository is a weaker claim, and
# is used only where the language has just one source.
HOLDOUT_GROUPS="${HOLDOUT_GROUPS:-repo:cubical repo:batteries repo:nixpkgs/nixos repo:idris2/tests}"

# Decided once per source, not once per file: hashing the group name for each
# of ~200,000 files would cost more than the extraction itself.
current_holdout=0
set_holdout() {
  local group="$1" spare="$2" bucket named bare
  current_holdout=0
  { [ -z "$HOLDOUT_OUT" ] || [ "$spare" = spare ]; } && return 0
  for named in $HOLDOUT_GROUPS; do
    case "$named" in
      */*) : ;;                                  # a subtree; decided per file
      "$group") current_holdout=1; return 0 ;;   # a whole repository
    esac
  done
  # The bucket hashes the bare name, not the namespaced group, so the sampled
  # holdout population is unchanged by the namespacing of the ids.
  bare="${group#*:}"
  bucket=$(printf '%s' "$bare" | sha256sum | cut -c1-6)
  [ $(( 0x$bucket % 100 )) -lt "$HOLDOUT_PERCENT" ] && current_holdout=1
  return 0
}

# For a named subtree (nixpkgs/nixos) the decision is per file, not per source,
# so it is applied where the relative path is known.
holdout_path() {
  local group="$1" rel="$2" named
  # Without a holdout destination there is no holdout: the H stream lands in
  # /dev/null, so routing anything there would silently DELETE those files
  # from the corpus rather than hold them out.
  [ -z "$HOLDOUT_OUT" ] && return 1
  for named in $HOLDOUT_GROUPS; do
    case "$named" in
      */*) [ "$group/${rel%%/*}" = "$named" ] && return 0 ;;
    esac
  done
  return 1
}

# Everything below writes `hash<TAB>jsonline` to stdout; the tail of the script
# drops duplicate content in one pass.  Measured on the full 2026-08 pull: 6.8%
# duplicates (299,966 files, 279,452 unique).  The "tens of percent" the plan
# predicted assumed sdists vendor heavily; they do not -- Hackage tarballs ship
# their own source, and the vendoring lives in build products this extraction
# never sees.  A rate NEAR ZERO would still mean broken hashing.
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
  tr -d '\000' < "$path" | iconv -f UTF-8 -t UTF-8 -c > "$clean" 2>/dev/null \
    || { undecodable=$((undecodable+1)); return 0; }
  [ -s "$clean" ] || { undecodable=$((undecodable+1)); return 0; }
  local hash
  hash=$(sha256sum < "$clean" | cut -d' ' -f1)
  # Held-out records carry the same hash prefix so the dedup pass sees both
  # streams and a file present in a training package cannot reappear in the
  # eval set under another name.
  if [ "$current_holdout" = 1 ] || holdout_path "$group" "$rel"; then
    printf 'H\t%s\t' "$hash"
    held=$((held+1))
  else
    printf 'T\t%s\t' "$hash"
    emitted=$((emitted+1))
  fi
  jq -c -Rs --arg id "$group/$rel" '{id:$id, text:.}' < "$clean"
}

echo "extract-code: Hackage tarballs" >&2
if [ -d "$SOURCES/tarballs" ]; then
  # find, not `ls | wc`: on an empty directory ls exits 2 and pipefail turns
  # the count itself into a script death with no message.
  tarball_count=$(find "$SOURCES/tarballs" -maxdepth 1 -name '*.tar.gz' | wc -l)
  for tarball in "$SOURCES"/tarballs/*.tar.gz; do
    [ -e "$tarball" ] || continue
    considered=$((considered+1))
    pv="$(basename "$tarball" .tar.gz)"
    package="${pv%-*}"
    # Some Hackage tarballs carry directories with mode 555, and rm then fails.
    # Under `set -e` that killed the whole loop at the first such package
    # (bgzf, alphabetically early) and the script still exited 0 with a corpus
    # holding a* through bg* -- silent truncation of exactly the kind the
    # completeness check at the bottom now refuses to allow.
    chmod -R u+rwX "$WORK/pkg" 2>/dev/null || true
    rm -rf "$WORK/pkg" || true
    mkdir -p "$WORK/pkg"
    tar xzf "$tarball" -C "$WORK/pkg" 2>/dev/null || { unreadable=$((unreadable+1)); continue; }
    processed=$((processed+1))
    cabal="$(find "$WORK/pkg" -maxdepth 2 -name '*.cabal' -print -quit 2>/dev/null || true)"
    [ -n "$cabal" ] || { skipped_license=$((skipped_license+1)); continue; }
    # awk with an early exit, not `sed | head`: head closing the pipe can
    # SIGPIPE sed, and pipefail then kills the whole extraction mid-corpus.
    license="$(awk 'sub(/^[Ll]icense:[[:space:]]*/, "") { print; exit }' "$cabal" | tr -d '\r')"
    permissive "$license" || { skipped_license=$((skipped_license+1)); continue; }
    set_holdout "hackage:$package" keep
    while IFS= read -r file; do
      emit_file "hackage:$package" "$file" "${file#$WORK/pkg/$pv/}"
    done < <(find "$WORK/pkg" -type f 2>/dev/null | grep -Ei "$EXTENSIONS" || true)
  done
fi

echo "extract-code: cloned repositories" >&2
for tree in "$SOURCES"/repos/*/ "$SOURCES"/own/*/ "$SOURCES"/curated/*/; do
  [ -d "$tree" ] || continue
  considered=$((considered+1))
  name="$(basename "$tree")"
  class="$(basename "$(dirname "${tree%/}")")"
  # Repository licenses are prose, not a field, so match on the text. The
  # user's own repositories are included regardless: they are the whole point
  # of the corpus and their licensing is theirs to decide. So are the curated
  # ones (curated/): repositories the user chose by name for the corpus, the
  # user's decision of 2026-09-25 (Conal Elliott's, most of whose Agda carries
  # no license file at all, which the gate would read as exclusion).
  if [ "$class" = repos ]; then
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
    # Creative Commons: Attribution alone passes (PLFA is CC-BY-4.0); the
    # ShareAlike, NonCommercial and NoDerivatives variants do not.
    if printf '%s' "$licensetext" | grep -qEi 'GNU (GENERAL|(LESSER|AFFERO) GENERAL) PUBLIC LICENSE|GNU (L|A)?GPL|SPDX-License-Identifier:.*(GPL|AGPL|LGPL)|ShareAlike|NonCommercial|NoDerivatives'; then
      skipped_license=$((skipped_license+1)); continue
    fi
    if ! printf '%s' "$licensetext" | grep -qEi \
        'Permission is hereby granted, free of charge|Redistribution and use in source|Apache License|ISC License|Mozilla Public License|CC0|public domain|MIT License|Attribution 4\.0 International'; then
      skipped_license=$((skipped_license+1)); continue
    fi
  fi
  # The user's own repositories are spared the holdout: they are the point of
  # the corpus and there is far too little of them to measure with.
  if [ "$class" = own ] || [ "$class" = curated ]; then
    group="$class:$name"
    set_holdout "$group" spare
  else
    group="repo:$name"
    set_holdout "$group" keep
  fi
  while IFS= read -r file; do
    emit_file "$group" "$file" "${file#$tree}"
  done < <(find "$tree" -type f -not -path '*/.git/*' 2>/dev/null | grep -Ei "$EXTENSIONS" || true)
done

echo "extract-code: $considered sources considered, $skipped_license dropped on license, $skipped_binary files skipped by size, $undecodable undecodable, $emitted train / $held held-out files" >&2
  # Refuse to hand back a partial corpus quietly. Every tarball must have been
  # opened, whatever its license said afterwards; a shortfall here means the
  # loop died early and the result is a prefix of the alphabet.
  if [ "$tarball_count" -gt 0 ] && [ "$(( processed + unreadable ))" -lt "$tarball_count" ]; then
    echo "extract-code: INCOMPLETE -- opened $processed of $tarball_count tarballs ($unreadable unreadable). The loop died early; the corpus is a prefix." >&2
    exit 1
  fi
}

# Write to temporaries and rename on success: the completeness check inside
# generate fires only after every surviving record has already been written,
# so a detected truncation must not leave a partial corpus under the name
# downstream tooling trusts.
out_tmp="$OUT.tmp"
if [ -n "$HOLDOUT_OUT" ]; then hout_tmp="$HOLDOUT_OUT.tmp"; else hout_tmp=/dev/null; fi
generate | awk -F'\t' -v out="$out_tmp" -v hout="$hout_tmp" '
  # Field 1 routes (T train, H held out), field 2 is the content hash, and the
  # JSON is everything after. Deduplication keys on the hash across BOTH
  # streams, so a file vendored into a held-out package cannot reappear there
  # after being seen in training.
  { total++ }
  !seen[$2]++ {
    line = $0
    sub(/^[^\t]*\t[^\t]*\t/, "", line)
    if ($1 == "H") { print line > hout; heldkept++ } else { print line > out; kept++ }
  }
  END {
    printf "extract-code: %d files, %d unique (%d train, %d held out), %d duplicates dropped (%.1f%%)\n",
      total, kept + heldkept, kept, heldkept, total - kept - heldkept,
      total ? 100 * (total - kept - heldkept) / total : 0 > "/dev/stderr"
  }'
test -s "$out_tmp" || { echo "extract-code: produced nothing" >&2; exit 1; }
mv "$out_tmp" "$OUT"
[ -n "$HOLDOUT_OUT" ] && mv "$hout_tmp" "$HOLDOUT_OUT"
echo "extract-code: wrote $OUT ($(wc -l < "$OUT") documents, $(du -h "$OUT" | cut -f1))" >&2
