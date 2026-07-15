#!/usr/bin/env bash
# pull-checkpoint.sh — run on the LOCAL machine (olimpo), not the instance.
#
# Continuously rsyncs the evolving global checkpoint (and its .best) off the
# Verda instance so the trained weights are always safe locally. This is the
# core "shut down cost ASAP" safety net: because the latest weights are already
# home, you can destroy the instance the instant you are satisfied — or lose
# almost nothing if a spot instance is evicted.
#
# The trainer writes checkpoints atomically (temp + rename), so each pull gets a
# complete file, never a torn one.
#
# Usage:
#   deploy/pull-checkpoint.sh USER@HOST [interval_seconds]
# Env:
#   SSH_KEY      identity file (default: ~/.ssh/xpsoasis-ed25519 = hhefesto@olimpo)
#   REMOTE_DIR   remote repo path (default: formalTransformer)
#   SIZE         model size (default: bpe10m)
#   LOCAL_DIR    where to drop the checkpoint locally (default: run)
set -euo pipefail

HOST="${1:?usage: pull-checkpoint.sh USER@HOST [interval_seconds]}"
INTERVAL="${2:-120}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/xpsoasis-ed25519}"
REMOTE_DIR="${REMOTE_DIR:-formalTransformer}"
SIZE="${SIZE:-bpe10m}"
LOCAL_DIR="${LOCAL_DIR:-run}"

mkdir -p "$LOCAL_DIR"
ssh_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
remote_glob="$REMOTE_DIR/run/wiki-$SIZE-global.checkpoint"

echo "pull-checkpoint: $HOST:$remote_glob* -> $LOCAL_DIR/ every ${INTERVAL}s"
echo "  (Ctrl-C to stop; safe to run alongside training)"
while true; do
  if rsync -az --partial --inplace -e "ssh ${ssh_opts[*]}" \
       "$HOST:$remote_glob" "$HOST:$remote_glob.best" "$LOCAL_DIR/" 2>/dev/null; then
    ckpt="$LOCAL_DIR/wiki-$SIZE-global.checkpoint"
    if [ -f "$ckpt" ]; then
      echo "pulled $(date -u +%H:%M:%S)  $(stat -c %s "$ckpt") bytes  -> $ckpt"
    fi
  else
    echo "pull-checkpoint: nothing yet / instance unreachable — retrying in ${INTERVAL}s"
  fi
  sleep "$INTERVAL"
done
