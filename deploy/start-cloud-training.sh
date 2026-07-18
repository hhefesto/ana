#!/usr/bin/env bash
# start-cloud-training.sh - idempotently start train-cloud.sh on an instance.
#
# Run from the remote repository root, either directly or over SSH:
#   ssh host 'cd formalTransformer && bash -s' < deploy/start-cloud-training.sh
#
# The PID check and launch lock make this safe for a local watchdog to invoke
# repeatedly. A stale PID file is repaired when a trainer is already running.
set -euo pipefail

repo_root="${REMOTE_REPO_ROOT:-$PWD}"
cd "$repo_root"

if [ -f "${TRAIN_ENV_FILE:-run/train-cloud.env}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${TRAIN_ENV_FILE:-run/train-cloud.env}"
  set +a
fi

: "${TOKENIZER_FILE:?set TOKENIZER_FILE to the remote .bpe artifact}"

log_file="${TRAIN_LOG:-run/train-cloud.log}"
pid_file="${TRAIN_PID_FILE:-run/train-cloud.pid}"
start_lock="${TRAIN_START_LOCK:-run/train-cloud-start.lock}"
mkdir -p run

exec 9>"$start_lock"
if ! flock -n 9; then
  echo "start-cloud-training: another launch check is active"
  exit 0
fi

running_pid=""
if [ -f "$pid_file" ]; then
  read -r candidate < "$pid_file" || true
  if [ -n "${candidate:-}" ] && kill -0 "$candidate" 2>/dev/null; then
    command_line="$(tr '\0' ' ' < "/proc/$candidate/cmdline" 2>/dev/null || true)"
    case "$command_line" in
      *deploy/train-cloud.sh*) running_pid="$candidate" ;;
    esac
  fi
fi

if [ -z "$running_pid" ]; then
  running_pid="$(pgrep -fo '[/]deploy/train-cloud.sh' || true)"
fi

if [ -n "$running_pid" ] && kill -0 "$running_pid" 2>/dev/null; then
  printf '%s\n' "$running_pid" > "$pid_file"
  echo "start-cloud-training: already running (pid $running_pid)"
  exit 0
fi

printf '\n[%s] start-cloud-training: launching trainer\n' "$(date -Is)" >> "$log_file"
nohup ./deploy/train-cloud.sh >> "$log_file" 2>&1 < /dev/null &
trainer_pid=$!
printf '%s\n' "$trainer_pid" > "$pid_file"

sleep 2
if ! kill -0 "$trainer_pid" 2>/dev/null; then
  echo "start-cloud-training: launch failed; inspect $log_file" >&2
  exit 1
fi

echo "start-cloud-training: started pid $trainer_pid; log $log_file"
