#!/usr/bin/env bash
# pull-stages.sh — run on the LOCAL machine (olimpo), not the instance.
#
# Pulls the training checkpoint at each 1/N of the corpus (N=4 by default:
# snapshots at ~25%, 50%, 75%, 100% of shards), each saved under a distinct
# name. This gives milestone weights you can compare with wiki-generate to watch
# the model sharpen across training, and it doubles as eviction insurance —
# without the noise of a continuous pull.
#
# Progress is measured by the *.done shard markers train-cloud.sh writes on the
# instance, so a "stage" is a genuine fraction of the corpus consumed, not a
# wall-clock guess. Start it around when training starts (a late start labels
# early stages with whatever weights exist at that moment).
#
# Snapshots land as run/wiki-<size>-global.stage-<k>of<N>.checkpoint. They match
# wiki-generate's run/*.checkpoint discovery, so the newest stage is picked
# automatically; generate from an earlier stage with
#   WIKI_CHECKPOINT=run/wiki-bpe10m-global.stage-1of4.checkpoint nix run .#wiki-generate
#
# Usage:  deploy/pull-stages.sh USER@HOST
#         vast.ai: SSH_PORT=<port> deploy/pull-stages.sh root@<host>
# Env:    SSH_KEY SSH_PORT REMOTE_DIR SIZE LOCAL_DIR TOTAL_SHARDS STAGES INTERVAL
set -euo pipefail

HOST="${1:?usage: pull-stages.sh USER@HOST}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/xpsoasis-ed25519}"
SSH_PORT="${SSH_PORT:-}"
REMOTE_DIR="${REMOTE_DIR:-formalTransformer}"
SIZE="${SIZE:-bpe10m}"
LOCAL_DIR="${LOCAL_DIR:-run}"
TOTAL_SHARDS="${TOTAL_SHARDS:-1465}"
STAGES="${STAGES:-4}"
INTERVAL="${INTERVAL:-300}"

mkdir -p "$LOCAL_DIR"
ssh_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "$SSH_PORT" ] && ssh_opts+=(-p "$SSH_PORT")
remote_run="$REMOTE_DIR/run/wiki-$SIZE"
remote_ckpt="$REMOTE_DIR/run/wiki-$SIZE-global.checkpoint"

pull() { # $1 = stage label, e.g. stage-2of4
  local dest="$LOCAL_DIR/wiki-$SIZE-global.$1.checkpoint"
  if rsync -az --partial -e "ssh ${ssh_opts[*]}" "$HOST:$remote_ckpt" "$dest" 2>/dev/null; then
    echo "pull-stages: $1 -> $dest ($(stat -c %s "$dest" 2>/dev/null || echo '?') bytes)"
    return 0
  fi
  echo "pull-stages: $1 pull failed (will retry next tick)"
  return 1
}

echo "pull-stages: watching $HOST — one snapshot per 1/$STAGES of $TOTAL_SHARDS shards"
echo "  (Ctrl-C to stop)"
last=0
while true; do
  done=$(ssh "${ssh_opts[@]}" "$HOST" \
    "ls $remote_run/shard-*-$SIZE.done 2>/dev/null | wc -l" 2>/dev/null || echo -1)
  if ! [[ "$done" =~ ^[0-9]+$ ]]; then
    echo "pull-stages: $HOST unreachable — retry in ${INTERVAL}s"
    sleep "$INTERVAL"; continue
  fi
  quarter=$(( done * STAGES / TOTAL_SHARDS ))
  [ "$quarter" -gt "$STAGES" ] && quarter="$STAGES"
  while [ "$quarter" -gt "$last" ]; do
    next=$(( last + 1 ))
    echo "pull-stages: reached stage $next/$STAGES ($done/$TOTAL_SHARDS shards done)"
    if pull "stage-${next}of${STAGES}"; then last="$next"; else break; fi
  done
  if [ "$done" -ge "$TOTAL_SHARDS" ]; then
    echo "pull-stages: training complete — final snapshot saved. Done."
    break
  fi
  sleep "$INTERVAL"
done
