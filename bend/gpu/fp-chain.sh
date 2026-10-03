#!/usr/bin/env bash
# A chain of runs on one box without a person present, then the scores, the
# pull and the DESTROY. Runs on this machine, outside any session, from a
# copy (bash reads a script as it runs, so the file it runs from must not
# change):
#   cp bend/gpu/fp-chain.sh run/fp-chain.sh
#   systemd-run --user --unit=ft-fp-chain /usr/bin/env bash run/fp-chain.sh HOST PORT INSTANCE DEST STAGES
#
# STAGES is a file, one stage a line, in order:
#   NAME BINARY EVERY [PLAN RUN_DIR SHARD_SIZE]
# A stage's log is NAME.log on the box (the first stage's may be named by
# LOG0, default train.log) and its saves out/NAME-step<N>.checkpoint. A stage
# whose log is not on the box is started with `fp.sh again` from the last
# save of the stage before it (TRAIN_NEXT: the state carries over, the
# schedule restarts on PLAN), so the relay can be restarted at any point.
# The first stage must already be running (it has no PLAN).
#
# Stages may be appended to STAGES while the chain runs: at the end of the
# list it waits WAIT seconds (7200) for another line, and a stage whose PLAN
# is not on the box yet waits WAIT for it, before going on to the scores.
# Every POLL seconds (120) it looks at the running stage, pulls its saved checkpoints
# whose step is a multiple of the stage's EVERY (only once the log says
# `saved`: a save writes in place) and deletes, on the box, its others but
# the newest. A stage is dead when no trainer runs and its log has been still
# for 20 minutes: DEST/DIED says which, and no later stage starts. Then
# `fp.sh eval` scores every pulled checkpoint and each stage's last on
# run/eval/transcript-fp.corpus and run/eval/transcript-next.corpus (eval.log,
# eval-next.log), the last checkpoints are pulled, every pulled file is held to
# the box's sha256 (a mismatch leaves the box up and exits 1), and the box is
# destroyed: after DEST/HOLD's epoch deadline if that file exists, never if
# DEST/CONTINUED exists (someone took the box over).
set -u
host="${1:?usage: fp-chain.sh HOST PORT INSTANCE DEST STAGES}"
port="${2:?}"
inst="${3:?}"
dest="${4:?}"
stages="${5:?}"
V=$HOME/.local/share/vastai-venv/bin/vastai
SSH="ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port $host"
mkdir -p "$dest/out"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] $*" | tee -a "$dest/chain.log"; }

# the saved checkpoints of a log, oldest first, as "STEP FILE"
saved() { $SSH "cd formalTransformer && grep -o 'saved out/[^ ]*\\.checkpoint' $1 2>/dev/null" 2>/dev/null | sed -n 's#^saved out/\(.*-step\([0-9]*\)\.checkpoint\)$#\2 \1#p' | sort -n; }
pull_one() { rsync -a --partial-dir=.partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$host:formalTransformer/out/$1" "$dest/out/" >/dev/null 2>&1 && log "pulled $1"; }
have() { [ -f "$dest/out/$1" ] && [ ! -f "$dest/out/.partial/$1" ]; }
pull_new() { for f in $(saved "$1" | awk -v e="$2" '$1 % e == 0 { print $2 }'); do have "$f" || pull_one "$f"; done; }
prune() { for f in $(saved "$1" | head -n -1 | awk -v e="$2" '$1 % e != 0 { print $2 }'); do $SSH "rm -f formalTransformer/out/$f" 2>/dev/null; done; }
last_of() { saved "$1" | tail -1 | cut -d' ' -f2; }
on_box() { [ "$($SSH "[ -f formalTransformer/$1 ] && echo yes" 2>/dev/null)" = yes ]; }

# follow one stage until its log says done (returns 0) or it died (1)
follow() {
  local lg=$1 bin=$2 every=$3 last_size=0 quiet=0 state=running r size procs tail
  while [ $state = running ]; do
    sleep ${POLL:-120}
    r=$($SSH "cd formalTransformer && stat -c %s $lg 2>/dev/null; pgrep -c -x '$bin'; tail -c 200 $lg 2>/dev/null | tr '\n' ' '" 2>/dev/null) || { log "ssh failed; retrying"; continue; }
    size=$(echo "$r" | sed -n 1p); procs=$(echo "$r" | sed -n 2p); tail=$(echo "$r" | sed -n 3p)
    if echo "$tail" | grep -q "done at step"; then state=done
    elif [ "${procs:-0}" = 0 ]; then
      if [ "$size" = "$last_size" ]; then quiet=$((quiet + ${POLL:-120})); else quiet=0; fi
      [ $quiet -ge 1200 ] && state=died
    else quiet=0; fi
    last_size=$size
    log "$lg $state: $size bytes, $procs trainer(s); ${tail: -100}"
    pull_new "$lg" "$every"; prune "$lg" "$every"
  done
  log "$lg: $state"
  [ $state = done ]
}

# the k-th stage line of the file (comments and blank lines skipped), empty past the end
stage_at() { grep -v '^[[:space:]]*\(#\|$\)' "$stages" | sed -n "${1}p"; }
# wait up to WAIT seconds (7200) for a condition, polling every minute
wait_for() { local until_t=$(( $(date +%s) + ${WAIT:-7200} )); while ! "$@"; do [ "$(date +%s)" -ge $until_t ] && return 1; sleep 60; done; }
has_stage() { [ -n "$(stage_at "$1")" ]; }

prev=""; logs=""; lasts=""; k=1; ok=1
while [ $ok = 1 ]; do
  # a stage appended to STAGES while the chain runs is taken up; at the end
  # of the list the chain waits WAIT for another before it goes to the scores
  if ! has_stage $k; then
    log "no stage $k yet; waiting up to ${WAIT:-7200} s for one to be appended to $stages"
    wait_for has_stage $k || { log "no more stages"; break; }
  fi
  read -r name bin every plan rdir ssz <<< "$(stage_at $k)"
  lg="$name.log"; [ $k = 1 ] && lg="${LOG0:-train.log}"
  k=$((k + 1))
  if ! on_box "$lg"; then
    if [ -z "$prev" ] || [ -z "${plan:-}" ]; then log "stage $name: nothing to start from"; ok=0; break; fi
    if ! on_box "$plan"; then
      log "stage $name: waiting up to ${WAIT:-7200} s for $plan on the box"
      wait_for on_box "$plan" || { log "stage $name: $plan never came"; ok=0; break; }
    fi
    log "stage $name: from out/$prev on $plan"
    $SSH "cd formalTransformer && ./fp.sh again out/$prev $plan $rdir $ssz $name" 2>&1 | tail -1 | tee -a "$dest/chain.log"
    sleep 60
  fi
  logs="$logs $lg:$every"
  follow "$lg" "$bin" "$every" || { echo "$lg: the trainer died" >> "$dest/DIED"; ok=0; }
  l=$(last_of "$lg"); [ -n "$l" ] && { prev=$l; lasts="$lasts $l"; }
done

# scores
evals=""
for le in $logs; do lg=${le%%:*}; ev=${le##*:}; evals="$evals $(saved "$lg" | awk -v e="$ev" '$1 % e == 0 { print "out/" $2 }' | tr '\n' ' ')"; done
for l in $lasts; do case " $evals " in *" out/$l "*) ;; *) evals="$evals out/$l";; esac; done
log "eval:$evals"
$SSH "cd formalTransformer && ./fp.sh eval $evals > eval.log 2>&1; [ -f run/eval/transcript-next.corpus ] && ECORPUS=run/eval/transcript-next.corpus ./fp.sh eval $evals > eval-next.log 2>&1; grep -E '^==|bits_per_byte' eval.log; echo next:; grep -E '^==|bits_per_byte' eval-next.log 2>/dev/null" | tee -a "$dest/chain.log"

# pull, verify, destroy
for le in $logs; do pull_new "${le%%:*}" "${le##*:}"; done
for l in $lasts; do have "$l" || pull_one "$l"; done
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
$V destroy instance "$inst" -y 2>&1 | tee -a "$dest/chain.log"
sleep 10
if $V show instances --raw 2>/dev/null | grep -q "\"id\": $inst\b"; then log "WARNING: instance $inst still listed after destroy"; exit 1; fi
date > "$dest/DESTROYED"
log "finished"
