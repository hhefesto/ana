#!/usr/bin/env bash
# Finish a box run without a person present: wait for the trainer to end,
# score every checkpoint on the held-out transcripts, pull everything, and
# DESTROY the instance (a box bills until it is destroyed; the rule is
# destroy, never stop). Runs on this machine, outside any session:
#   systemd-run --user --unit=ft-fp-finish bend/gpu/fp-finish.sh HOST PORT INSTANCE DEST
# Every 5 minutes it looks at the box and pulls, while the run goes on, every
# checkpoint whose step is a multiple of EVERY (1000) that it does not have
# yet, so the slow link is used during training instead of after it (a box
# bills by the hour). The run is over when train.log says
# `done at step`; it is dead when no traind process exists and the log has
# not grown for 20 minutes (then there is nothing more to wait for: the
# logs and whatever checkpoints exist are pulled and the box destroyed all
# the same, and DEST/DIED says so). DEST gets out/, the logs, eval.log and
# sha256.txt (the multiples of EVERY and the last checkpoint are pulled and
# scored in eval.log; the others die with the box); DEST/DESTROYED is written
# after `vastai destroy`. Pulled files are verified against the box's sha256
# before the destroy; a mismatch leaves the box up and exits 1.
set -u
host="${1:?usage: fp-finish.sh HOST PORT INSTANCE DEST}"
port="${2:?}"
inst="${3:?}"
dest="${4:?}"
V=$HOME/.local/share/vastai-venv/bin/vastai
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port $host"
mkdir -p "$dest"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] $*" | tee -a "$dest/finish.log"; }
EVERY=${EVERY:-1000}
# the checkpoints whose step is a multiple of EVERY and whose save the log
# reports finished (a save writes in place: a file is whole only once the
# trainer says `saved`), oldest first
wanted() { $SSH 'cd formalTransformer && grep -o "saved out/[^ ]*\.checkpoint" train.log 2>/dev/null' 2>/dev/null | sed -n 's#^saved out/\(.*-step\([0-9]*\)\.checkpoint\)$#\2 \1#p' | sort -n | awk -v e="$EVERY" '$1 % e == 0 { print $2 }'; }
pull_one() { rsync -a --partial-dir=.partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$host:formalTransformer/out/$1" "$dest/out/" >/dev/null 2>&1 && log "pulled $1"; }
pull_new() { mkdir -p "$dest/out"; for f in $(wanted); do [ -f "$dest/out/$f" ] && [ ! -f "$dest/out/.partial/$f" ] || pull_one "$f"; done; }
last_size=0; quiet=0; state=running
while [ $state = running ]; do
  sleep 300
  r=$($SSH 'cd formalTransformer && stat -c %s train.log 2>/dev/null; pgrep -c -x traind; tail -c 200 train.log 2>/dev/null | tr "\n" " "' 2>/dev/null) || { log "ssh failed; retrying"; continue; }
  size=$(echo "$r" | sed -n 1p); procs=$(echo "$r" | sed -n 2p); tail=$(echo "$r" | sed -n 3p)
  if echo "$tail" | grep -q "done at step"; then state=done
  elif [ "${procs:-0}" = 0 ]; then
    if [ "$size" = "$last_size" ]; then quiet=$((quiet + 300)); else quiet=0; fi
    [ $quiet -ge 1200 ] && state=died
  else quiet=0; fi
  last_size=$size
  log "$state: log $size bytes, $procs trainer process(es); ${tail: -120}"
  pull_new
done
log "trainer $state"
[ $state = died ] && echo "the trainer died; see train.log" > "$dest/DIED"
last=$($SSH 'cd formalTransformer && grep -o "saved out/[^ ]*\.checkpoint" train.log' 2>/dev/null | sed -n 's#^saved out/\(.*-step\([0-9]*\)\.checkpoint\)$#\2 \1#p' | sort -n | tail -1 | cut -d" " -f2)
evals="$(wanted | sed 's#^#out/#' | tr '\n' ' ') ${last:+out/$last}"
log "eval: $evals"
$SSH "cd formalTransformer && ./fp.sh eval $evals > eval.log 2>&1; tail -60 eval.log" | tee -a "$dest/finish.log"
log "pull the rest: the multiples of $EVERY not yet here and the last checkpoint ($last)"
pull_new
[ -n "$last" ] && [ ! -f "$dest/out/$last" ] && pull_one "$last"
rsync -a -e "ssh -o StrictHostKeyChecking=no -p $port" --include='*.log*' --include='*.txt' --exclude='*' "$host:formalTransformer/" "$dest/" 2>&1 | tail -2 | tee -a "$dest/finish.log"
remote=$($SSH 'cd formalTransformer/out && sha256sum *.checkpoint' 2>/dev/null)
echo "$remote" > "$dest/sha256.box.txt"
(cd "$dest/out" && sha256sum *.checkpoint) > "$dest/sha256.txt" 2>/dev/null
if [ -n "$remote" ] && [ -s "$dest/sha256.txt" ] && [ -z "$(grep -vxF -f <(echo "$remote") "$dest/sha256.txt")" ]; then
  log "pulled: every pulled checkpoint's sha256 matches the box's ($(wc -l < "$dest/sha256.txt") of $(echo "$remote" | wc -l) files)"
else
  log "WARNING: the pulled checkpoints do not all match the box's; the box is NOT destroyed"; exit 1
fi
log "destroy instance $inst"
$V destroy instance "$inst" -y 2>&1 | tee -a "$dest/finish.log"
sleep 10
if $V show instances --raw 2>/dev/null | grep -q "\"id\": $inst\b"; then log "WARNING: instance $inst still listed after destroy"; exit 1; fi
date > "$dest/DESTROYED"
log "finished"
