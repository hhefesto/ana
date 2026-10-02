#!/usr/bin/env bash
# The box's runs without a person present: fp100m, then (when it is staged)
# the continuation on the next plan, then the scores, the pull and the
# DESTROY. Runs on this machine, outside any session, from a copy (bash reads
# a script as it runs, so the file it runs from must not change):
#   cp bend/gpu/fp-relay.sh run/fp-relay.sh
#   systemd-run --user --unit=ft-fp-relay run/fp-relay.sh HOST PORT INSTANCE DEST
#
# Every 5 minutes it looks at the box, pulls every saved checkpoint whose step
# is a multiple of EVERY (1000) of the run that is going on (only once the
# log says `saved`: a save writes in place) and deletes, on the box, the
# others but the newest.
#   1. fp100m (train.log, out/fp100m-step<N>). When it is done: if the box
#      holds the next plan (run/next/plan-next-b16-windows.tsv, every shard it
#      names, run/next/STAGED written after the push, traind-next.c), within
#      GRACE seconds (1800) of the end, `fp.sh next` starts the continuation
#      from fp100m's last save, and fp100m's last checkpoint is pulled while
#      it trains. Otherwise the continuation is skipped.
#   2. the continuation (next.log, out/next-step<N>), until done.
#   3. `fp.sh eval` scores the pulled checkpoints and each run's last on the
#      held-out transcripts (run/eval/transcript-fp.corpus, and
#      run/eval/transcript-next.corpus when the box has it) into eval.log.
#   4. the last checkpoints are pulled, every pulled file is held to the
#      box's sha256 (a mismatch leaves the box up and exits 1), and the box is
#      destroyed: after DEST/HOLD's epoch deadline if that file exists, never
#      if DEST/CONTINUED exists (someone took the box over).
# A run is dead when no trainer runs and its log has been still for 20
# minutes: DEST/DIED says which, and the relay goes on to the next stage.
set -u
host="${1:?usage: fp-relay.sh HOST PORT INSTANCE DEST}"
port="${2:?}"
inst="${3:?}"
dest="${4:?}"
EVERY=${EVERY:-1000}
V=$HOME/.local/share/vastai-venv/bin/vastai
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port $host"
mkdir -p "$dest/out"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] $*" | tee -a "$dest/relay.log"; }

# the saved checkpoints of a log, oldest first, as "STEP FILE"
saved() { $SSH "cd formalTransformer && grep -o 'saved out/[^ ]*\\.checkpoint' $1 2>/dev/null" 2>/dev/null | sed -n 's#^saved out/\(.*-step\([0-9]*\)\.checkpoint\)$#\2 \1#p' | sort -n; }
pull_one() { rsync -a --partial-dir=.partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$host:formalTransformer/out/$1" "$dest/out/" >/dev/null 2>&1 && log "pulled $1"; }
have() { [ -f "$dest/out/$1" ] && [ ! -f "$dest/out/.partial/$1" ]; }
pull_new() { for f in $(saved "$1" | awk -v e="$EVERY" '$1 % e == 0 { print $2 }'); do have "$f" || pull_one "$f"; done; }
prune() { for f in $(saved "$1" | head -n -1 | awk -v e="$EVERY" '$1 % e != 0 { print $2 }'); do $SSH "rm -f formalTransformer/out/$f" 2>/dev/null; done; }
last_of() { saved "$1" | tail -1 | cut -d' ' -f2; }

# watch one run until its log says done (or it died)
follow() {
  local lg=$1 name=$2 last_size=0 quiet=0 state=running r size procs tail
  while [ $state = running ]; do
    sleep 300
    r=$($SSH "cd formalTransformer && stat -c %s $lg 2>/dev/null; pgrep -c -x '$name'; tail -c 200 $lg 2>/dev/null | tr '\n' ' '" 2>/dev/null) || { log "ssh failed; retrying"; continue; }
    size=$(echo "$r" | sed -n 1p); procs=$(echo "$r" | sed -n 2p); tail=$(echo "$r" | sed -n 3p)
    if echo "$tail" | grep -q "done at step"; then state=done
    elif [ "${procs:-0}" = 0 ]; then
      if [ "$size" = "$last_size" ]; then quiet=$((quiet + 300)); else quiet=0; fi
      [ $quiet -ge 1200 ] && state=died
    else quiet=0; fi
    last_size=$size
    log "$lg $state: $size bytes, $procs trainer(s); ${tail: -110}"
    pull_new "$lg"; prune "$lg"
  done
  [ $state = died ] && echo "$lg: the trainer died" >> "$dest/DIED"
  log "$lg: $state"
}

# 1. fp100m
follow train.log traind
fp_last=$(last_of train.log)
is_staged() { $SSH 'cd formalTransformer && p=run/next/plan-next-b16-windows.tsv; [ -f $p ] && [ -f traind-next.c ] && [ -f run/next/STAGED ] || exit 1; for k in $(awk "\$1 == \"segment\" { print \$2 }" $p); do [ -f run/next/shard-$k-next.corpus ] || exit 1; done; echo yes' 2>/dev/null; }
# the next plan may still be on its way: wait up to GRACE seconds (1800) for it
until_t=$(( $(date +%s) + ${GRACE:-1800} ))
staged=$(is_staged)
while [ "$staged" != yes ] && [ "$(date +%s)" -lt $until_t ]; do
  have "$fp_last" || pull_one "$fp_last"
  sleep 60; staged=$(is_staged)
done
if [ "$staged" = yes ] && [ -n "$fp_last" ]; then
  log "continuation: from out/$fp_last"
  $SSH "cd formalTransformer && ./fp.sh next out/$fp_last" 2>&1 | tail -1 | tee -a "$dest/relay.log"
  have "$fp_last" || pull_one "$fp_last"
  pull_new train.log
  # 2. the continuation
  follow next.log traind-next
  next_last=$(last_of next.log)
else
  log "no continuation staged (plan, shards or traind-next.c missing); going on to the scores"
  next_last=""
fi

# 3. scores
evals="$( (saved train.log; saved next.log) | awk -v e="$EVERY" '$1 % e == 0 { print "out/" $2 }' | tr '\n' ' ') ${fp_last:+out/$fp_last} ${next_last:+out/$next_last}"
log "eval: $evals"
$SSH "cd formalTransformer && ./fp.sh eval $evals > eval.log 2>&1; [ -f run/eval/transcript-next.corpus ] && ECORPUS=run/eval/transcript-next.corpus ./fp.sh eval $evals > eval-next.log 2>&1; tail -40 eval.log; tail -40 eval-next.log 2>/dev/null" | tee -a "$dest/relay.log"

# 4. pull, verify, destroy
pull_new train.log; pull_new next.log
for f in $fp_last $next_last; do have "$f" || pull_one "$f"; done
rsync -a -e "ssh -o StrictHostKeyChecking=no -p $port" --include='*.log*' --include='*.txt' --exclude='*' "$host:formalTransformer/" "$dest/" >/dev/null 2>&1
remote=$($SSH 'cd formalTransformer/out && sha256sum *.checkpoint' 2>/dev/null)
echo "$remote" > "$dest/sha256.box.txt"
(cd "$dest/out" && sha256sum *.checkpoint) > "$dest/sha256.txt" 2>/dev/null
if [ -n "$remote" ] && [ -s "$dest/sha256.txt" ] && [ -z "$(grep -vxF -f <(echo "$remote") "$dest/sha256.txt")" ]; then
  log "pulled: $(wc -l < "$dest/sha256.txt") checkpoints, each matching the box's sha256"
else
  log "WARNING: the pulled checkpoints do not all match the box's; the box is NOT destroyed"; exit 1
fi
while [ -f "$dest/HOLD" ] && [ "$(date +%s)" -lt "$(cat "$dest/HOLD" 2>/dev/null || echo 0)" ] && [ ! -f "$dest/CONTINUED" ]; do sleep 30; done
if [ -f "$dest/CONTINUED" ]; then log "someone took the box over; not destroying it"; exit 0; fi
log "destroy instance $inst"
$V destroy instance "$inst" -y 2>&1 | tee -a "$dest/relay.log"
sleep 10
if $V show instances --raw 2>/dev/null | grep -q "\"id\": $inst\b"; then log "WARNING: instance $inst still listed after destroy"; exit 1; fi
date > "$dest/DESTROYED"
log "finished"
