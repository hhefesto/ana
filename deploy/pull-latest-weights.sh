#!/usr/bin/env bash
# One-shot, read-only pull of the newest atomically published checkpoint from
# the live cloud trainer.  This only copies a file off the box; it never
# writes remote state or touches the training process.  The polling variant
# is deploy/pull-checkpoint.sh.
set -euo pipefail
HOST="${TRAIN_SSH_HOST:-root@154.9.228.248}"
PORT="${TRAIN_SSH_PORT:-21300}"
REMOTE="${TRAIN_REMOTE_CHECKPOINT:-/root/formalTransformer-5070ti/run/wiki-bpe10m-global.checkpoint}"
DEST="${1:-run/wiki-bpe10m-global.checkpoint}"
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp "$(dirname "$DEST")/.pull-weights-XXXXXX")"
trap 'rm -f "$tmp"' EXIT
scp -o BatchMode=yes -P "$PORT" "$HOST:$REMOTE" "$tmp"
mv "$tmp" "$DEST"
trap - EXIT
echo "pulled $(stat -c%s "$DEST") bytes -> $DEST"
