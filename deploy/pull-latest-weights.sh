#!/usr/bin/env bash
# One-shot, read-only pull of the newest atomically published checkpoint from a
# training box.  This only copies a file off the box; it never writes remote
# state or touches the training process.  The polling variant is
# deploy/pull-checkpoint.sh; `ana --pull` does the same thing inline.
#
# Usage:
#   deploy/pull-latest-weights.sh --host user@host [--port N] [--key PATH]
#                                 [--remote PATH] [--dest PATH]
#
# There is no default host: training boxes are ephemeral, and a stale default
# only ever produces a confusing timeout.  Env fallbacks (arguments win):
# TRAIN_SSH_HOST, TRAIN_SSH_PORT, TRAIN_SSH_KEY, TRAIN_REMOTE_CHECKPOINT.
#
# The destination is never overwritten in place.  A multi-day run's only copy
# can be sitting there; pass FORCE=1 if replacing it is genuinely what you want.
set -euo pipefail

HOST="${TRAIN_SSH_HOST:-}"
PORT="${TRAIN_SSH_PORT:-22}"
KEY="${TRAIN_SSH_KEY:-}"
REMOTE="${TRAIN_REMOTE_CHECKPOINT:-/root/formalTransformer/run/wiki-bpe100m-global.checkpoint}"
DEST=

while [ $# -gt 0 ]; do
  case "$1" in
    --host)   HOST="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --key)    KEY="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --dest)   DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" >&2; exit 0 ;;
    -*) echo "pull-latest-weights: unknown option $1" >&2; exit 1 ;;
    *)  DEST="$1"; shift ;;
  esac
done

if [ -z "$HOST" ]; then
  echo "pull-latest-weights: --host user@host is required" >&2
  exit 1
fi
case "$PORT" in
  ""|*[!0-9]*) echo "pull-latest-weights: --port must be an integer (got '$PORT')" >&2; exit 1 ;;
esac
case "$HOST" in
  *@*) ;;
  *) HOST="root@$HOST" ;;
esac
if [ -n "$KEY" ] && [ ! -f "$KEY" ]; then
  echo "pull-latest-weights: ssh key not found: $KEY" >&2
  exit 1
fi

# Default to a per-host directory rather than the shared run/ root, so pulls
# from different boxes cannot overwrite one another.
if [ -z "$DEST" ]; then
  slug="$(printf '%s-%s' "$HOST" "$PORT" | tr -c 'A-Za-z0-9._-' '-')"
  DEST="run/pulled-$slug-checkpoints/$(basename "$REMOTE")"
fi

if [ -e "$DEST" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "pull-latest-weights: refusing to overwrite $DEST" >&2
  echo "  it holds $(sha256sum "$DEST" | awk '{print $1}')" >&2
  echo "  choose another --dest, or re-run with FORCE=1" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
scp_options=(-o BatchMode=yes -P "$PORT")
[ -n "$KEY" ] && scp_options+=(-i "$KEY")

tmp="$(mktemp "$(dirname "$DEST")/.pull-weights-XXXXXX")"
trap 'rm -f "$tmp"' EXIT
scp "${scp_options[@]}" "$HOST:$REMOTE" "$tmp"
mv -f "$tmp" "$DEST"
trap - EXIT
echo "pulled $(stat -c%s "$DEST") bytes -> $DEST"
echo "sha256 $(sha256sum "$DEST" | awk '{print $1}')"
