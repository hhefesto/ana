#!/usr/bin/env bash
# watch-cloud-training.sh - restart a remote cloud trainer after interruption.
#
# Runs locally and sends the idempotent launcher over SSH on every poll. This
# survives a remote container restart because the watchdog itself is off-box.
# It cannot recover an instance whose address or writable filesystem changes.
#
# Usage:
#   SSH_PORT=16309 deploy/watch-cloud-training.sh root@HOST [interval_seconds]
#
# Env paths are remote paths. SSH_KEY is optional; normal SSH configuration is
# used by default.
set -u

host="${1:?usage: watch-cloud-training.sh USER@HOST [interval_seconds]}"
interval="${2:-60}"
ssh_key="${SSH_KEY:-}"
ssh_port="${SSH_PORT:-}"
remote_dir="${REMOTE_DIR:-formalTransformer}"
tokenizer_file="${TOKENIZER_FILE:-/root/datasets/wikipedia-en/enwiki-8k.bpe}"
train_log="${TRAIN_LOG:-run/train-cloud.log}"
launcher="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/start-cloud-training.sh"

shell_quote() {
  local value="${1//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[ -n "$ssh_key" ] && ssh_opts+=(-i "$ssh_key")
[ -n "$ssh_port" ] && ssh_opts+=(-p "$ssh_port")

remote_command="cd $(shell_quote "$remote_dir") && env"
remote_command+=" TOKENIZER_FILE=$(shell_quote "$tokenizer_file")"
remote_command+=" TRAIN_BATCH=$(shell_quote "${TRAIN_BATCH:-8}")"
remote_command+=" MICRO_BATCH=$(shell_quote "${MICRO_BATCH:-1}")"
remote_command+=" CHECKPOINT_EVERY=$(shell_quote "${CHECKPOINT_EVERY:-500}")"
remote_command+=" VALIDATE_EVERY=$(shell_quote "${VALIDATE_EVERY:-2000}")"
remote_command+=" VALIDATION_WINDOWS=$(shell_quote "${VALIDATION_WINDOWS:-1}")"
remote_command+=" TRAIN_LOG=$(shell_quote "$train_log")"
[ -z "${TRAINER:-}" ] || remote_command+=" TRAINER=$(shell_quote "$TRAINER")"
remote_command+=" bash -s"

echo "watch-cloud-training: ensuring trainer on $host every ${interval}s"
echo "  remote=$remote_dir checkpoint_every=${CHECKPOINT_EVERY:-500} log=$train_log"
while true; do
  if ! ssh "${ssh_opts[@]}" "$host" "$remote_command" < "$launcher"; then
    echo "watch-cloud-training: $(date -Is) instance unreachable or launch failed; retrying"
  fi
  sleep "$interval"
done
