#!/usr/bin/env bash
# Finalize a transcript wave and put it ahead of the raw slices not yet
# started: run the agents' finalize scripts (they stop their checks and
# render what is kept), build and push the wave, and insert its stage in
# STAGES before the first raw stage whose log is not on the box yet (or at
# the end when every raw stage has started).
#   wave-driver.sh NAME HOST PORT STAGES FINALIZE_SCRIPT... -- LABEL=DIR ...
set -u
name="${1:?usage: wave-driver.sh NAME HOST PORT STAGES FINALIZE... -- LABEL=DIR ...}"; host="$2"; port="$3"; stages="$4"; shift 4
fins=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do fins+=("$1"); shift; done; shift
new="$*"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] wave-driver $name: $*"; }
for f in "${fins[@]}"; do log "finalize $f"; bash "$f" > "run/$name-$(basename "$f").log" 2>&1 || log "$f exited $?"; done
# a language whose wave came out empty is left out
keep=""; for e in $new; do d=${e#*=}; [ -s "$d/transcripts.train.nul" ] && keep="$keep $e" || log "no transcripts in $d"; done
[ -z "$keep" ] && { log "nothing to train"; exit 0; }
NAME=$name NEW="$keep" bend/gpu/next-stage.sh build > "run/$name-build.log" 2>&1 || { log "build failed"; exit 1; }
NAME=$name bend/gpu/next-stage.sh push "$host" "$port" > "run/$name-push.log" 2>&1 || { log "push failed"; exit 1; }
line="$name traind-next 1000 run/$name/plan-$name-b16-windows.tsv run/$name $name"
ssh="ssh -n -o StrictHostKeyChecking=no -p $port $host"
# the stage the chain last reported starting may not have its log yet: never insert before it
started=$(grep -o 'stage [a-z0-9]*:' "${CHAINLOG:-run/pulled-vast-53909778/chain.log}" 2>/dev/null | tail -1 | sed 's/stage \(.*\):/\1/')
at=$(grep -n '^raw[0-9]* ' "$stages" | while IFS=: read -r n rest; do s=${rest%% *}; [ "$s" = "$started" ] && continue; [ "$($ssh "[ -f formalTransformer/$s.log ] && echo y" 2>/dev/null)" = y ] || { echo "$n"; break; }; done)
if [ -n "$at" ]; then sed -i "${at}i $line" "$stages"; log "inserted before line $at"; else echo "$line" >> "$stages"; log "appended"; fi
log "staged: $(head -1 run/$name/plan-fp100m-b16-windows.tsv | awk '{ print $3 }') steps"
