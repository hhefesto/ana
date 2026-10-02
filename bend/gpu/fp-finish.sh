#!/usr/bin/env bash
# Finish a box run without a person present: wait for the trainer to end,
# score every checkpoint on the held-out transcripts, pull everything, and
# DESTROY the instance (a box bills until it is destroyed; the rule is
# destroy, never stop). Runs on this machine, outside any session:
#   systemd-run --user --unit=ft-fp-finish bend/gpu/fp-finish.sh HOST PORT INSTANCE DEST
# Every 5 minutes it looks at the box. The run is over when train.log says
# `done at step`; it is dead when no traind process exists and the log has
# not grown for 20 minutes (then there is nothing more to wait for: the
# logs and whatever checkpoints exist are pulled and the box destroyed all
# the same, and DEST/DIED says so). DEST gets out/, the logs, eval.log and
# sha256.txt (the last KEEP, 8, checkpoints are pulled; the rest stay on the
# box and die with it, their scores in eval.log); DEST/DESTROYED is written
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
done
log "trainer $state"
[ $state = died ] && echo "the trainer died; see train.log" > "$dest/DIED"
log "eval"
$SSH 'cd formalTransformer && ./fp.sh eval > eval.log 2>&1; tail -40 eval.log' | tee -a "$dest/finish.log"
log "pull the last ${KEEP:-8} checkpoints (every one is scored in eval.log; this disk has room for about that many)"
mkdir -p "$dest/out"
for f in $($SSH 'cd formalTransformer/out && ls *.checkpoint' | sed 's/.*-step\([0-9]*\)\.checkpoint/\1 &/' | sort -n | tail -n "${KEEP:-8}" | cut -d" " -f2); do
  rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$host:formalTransformer/out/$f" "$dest/out/" 2>&1 | tail -1 | tee -a "$dest/finish.log"
done
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
