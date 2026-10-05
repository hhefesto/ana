#!/usr/bin/env bash
# py2bend.sh: the Bend translations of the project's old one-off Python scripts
# (run/code-sources-py2bend/own/py2bend/run/..., the user 2026-10-04: "Translate
# them to bend and add them to the corpus, then delete") into corpus v2 as one
# more Bend source, `own:py2bend` (not held out: sha256 rule, 764 >= 20):
#   1. the translations as JSONL (bend-extract; the library copies under
#      py2bend/bend/ left out: they are the repository's own modules)
#   2. units, checks, clean, rendered in format 2 with 4 presentations a unit
#      (bend-transcripts, BEND_SRC the translations' tree; every definition a
#      unit: MAX and MAX_HI high; no per-declaration holdout)
#   3. appended to corpus v2's Bend transcripts and filler (and filler.keys),
#      once (run/v2/transcripts/bend/.py2bend marks it)
# Then rebuild the transcript windows (windows.sh) and the plans (combine).
set -euo pipefail
W=run/transcripts-py2bend; J=run/raw-new/py2bend.jsonl; D=run/v2/transcripts/bend
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] py2bend: $*"; }
[ -f "$D/.py2bend" ] && { log "already in corpus v2 ($D/.py2bend)"; exit 0; }
nix run .#deploy -- extract "$J.all" run/code-sources-py2bend
grep -v '"own:py2bend/bend/' "$J.all" > "$J"; rm -f "$J.all"
log "$(wc -l < "$J") translations"
CORPUS=$J OUT=$W BEND_SRC=run/code-sources-py2bend/own MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 \
  TRANSCRIPT_FORMAT=2 COPIES=4 nix run .#deploy -- transcripts all bend
cat "$W/bend/transcripts.train.nul" >> "$D/transcripts.train.nul"
cat "$W/bend/files-hi.nul" "$W/bend/files-lo.nul" >> "$D/files-hi.nul"
nix run .#deploy -- corpus-v2 keys "$W/bend/files-hi.nul" | cut -f4 > "$W/keys"
nix run .#deploy -- corpus-v2 keys "$W/bend/files-lo.nul" | cut -f4 >> "$W/keys"
LC_ALL=C sort -u run/v2/transcripts/filler.keys "$W/keys" -o run/v2/transcripts/filler.keys
date > "$D/.py2bend"
log "added: $(tr -cd '\0' < "$W/bend/transcripts.train.nul" | wc -c | awk '{print $1 / 2}') transcripts"
