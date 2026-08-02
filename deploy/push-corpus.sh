#!/usr/bin/env bash
# push-corpus.sh — stream the sharded corpus to a rented box, in the order the
# trainer consumes it, while that box is already training.
#
# The 15 GB corpus is the largest thing that has to reach a billing card, and
# nothing shipped it: push-prebuilt.sh sends the 1.22 GB runtime closure and
# push-bench.sh sends a single shard. Uploading all of it before starting is
# dead time on hardware charged by the hour.
#
# It does not have to be dead time. Both launch modes stop *cleanly* at the
# first absent shard — backend/gpu/Main.hs:822 in persistent mode,
# deploy/train-cloud.sh:121 in the per-shard loop — and resume from the
# checkpoint's own Adam step, while deploy/watch-cloud-training.sh re-invokes
# the idempotent launcher every 60 s. So training starts on shard 0 and this
# script feeds it. Segment 0 alone is 4,940 steps, ~92 minutes at the measured
# 1.117 s/step: that is the head start the remaining 14.8 GB gets, and it needs
# only ~22 Mbit/s to stay ahead.
#
# This script only uploads. Restarting the trainer is watch-cloud-training.sh's
# job, and it already does it.
#
# usage: ./deploy/push-corpus.sh [user@]host [port]
#
#   TRAIN_ENV_FILE=deploy/bpe100m.env ./deploy/push-corpus.sh root@HOST 22
#
# Env:
#   TRAIN_ENV_FILE   settings sourced first (default run/train-cloud.env)
#   RUN_DIR SIZE TRAIN_BATCH SHARD_ARTICLES PLAN TOKENIZER_FILE
#                    exactly as deploy/train-cloud.sh derives them
#   REMOTE_DIR       remote repo path      (default formalTransformer)
#   MAX_SHARDS       0 = all; N = send only the first N shards still missing
#   COMPRESS         1 = rsync -z --compress-level=1  (default 0, see below)
#   SKIP_LINK_CHECK  1 = skip deploy/check-link.sh
#   DRY_RUN          1 = print the transfer order and exit, touching no network
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 [user@]host [port]" >&2
  exit 1
fi

host=$1
port=${2:-22}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Read the same settings file train-cloud.sh reads, so the uploader and the
# trainer cannot disagree about which corpus, plan or tokenizer is in play.
if [ -f "${TRAIN_ENV_FILE:-run/train-cloud.env}" ]; then
  # shellcheck disable=SC1090
  . "${TRAIN_ENV_FILE:-run/train-cloud.env}"
fi

size=${SIZE:-bpe100m}
run_dir=${RUN_DIR:-run/mixed-bpe100m-s32000}
batch=${TRAIN_BATCH:-64}
shard_articles=${SHARD_ARTICLES:-32000}
plan=${PLAN:-$run_dir/plan-$size-b$batch-s$shard_articles.tsv}
tokenizer=${TOKENIZER_FILE:-run/enwiki-fineweb-32k.bpe}
remote_dir=${REMOTE_DIR:-formalTransformer}
max_shards=${MAX_SHARDS:-0}

# Remote paths are built as $remote_dir/$run_dir and resolved against the login
# home directory, so an absolute RUN_DIR would scatter the corpus outside the
# repo on the box and leave the trainer unable to find any of it.
case "$run_dir" in
  /*) echo "push-corpus: RUN_DIR must be relative to the repo root: $run_dir" >&2; exit 1 ;;
esac

test -d "$run_dir" || { echo "push-corpus: run dir not found: $run_dir" >&2; exit 1; }
test -f "$plan" || { echo "push-corpus: plan not found: $plan" >&2; exit 1; }
test -f "$tokenizer" || { echo "push-corpus: tokenizer not found: $tokenizer" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Transfer order comes from the plan, never from a glob: `ls` sorts
# shard-100 before shard-10, which is not the order the trainer wants and would
# strand it behind a gap. Field 2 of each segment row is the shard index --
# the same parse as deploy/train-cloud.sh:116.
# ---------------------------------------------------------------------------
shards=()
while read -r tag k _rest; do
  [ "$tag" = segment ] || continue
  shards+=("$k")
done < "$plan"

[ "${#shards[@]}" -gt 0 ] || { echo "push-corpus: no segment rows in $plan" >&2; exit 1; }

for k in "${shards[@]}"; do
  test -f "$run_dir/shard-$k-$size.corpus" || {
    echo "push-corpus: local corpus missing: $run_dir/shard-$k-$size.corpus" >&2
    echo "  The local corpus is incomplete; rebuild it before pushing." >&2
    exit 1
  }
done

total_bytes=0
for k in "${shards[@]}"; do
  total_bytes=$((total_bytes + $(stat -c %s "$run_dir/shard-$k-$size.corpus")))
done

printf 'push-corpus: %s shards, %.1f GB, plan order from %s\n' \
  "${#shards[@]}" "$(awk -v b="$total_bytes" 'BEGIN{print b/1073741824}')" "$plan"

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "push-corpus: DRY_RUN — transfer order:"
  echo "  1. $plan"
  echo "  2. $tokenizer"
  n=2
  for k in "${shards[@]}"; do
    n=$((n + 1))
    printf '  %d. %s (%s bytes)\n' "$n" \
      "$run_dir/shard-$k-$size.corpus" "$(stat -c %s "$run_dir/shard-$k-$size.corpus")"
  done
  exit 0
fi

if [ "${SKIP_LINK_CHECK:-0}" != 1 ]; then
  "$repo_root/deploy/check-link.sh" "$host" "$port" || {
    echo "push-corpus: aborting — this box cannot carry 15 GB." >&2
    exit 1
  }
fi

# One multiplexed connection for the whole run: 304 shards would otherwise pay
# 304 SSH handshakes, plus one more per size check.
control_dir="$(mktemp -d)"
ssh_cmd="ssh -p $port -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
ssh_cmd="$ssh_cmd -o ControlMaster=auto -o ControlPersist=60 -o ControlPath=$control_dir/%r@%h:%p"
cleanup() {
  $ssh_cmd -O exit "$host" 2>/dev/null || true
  rm -rf "$control_dir"
}
trap cleanup EXIT

# rsync's -z is off by default here, unlike push-bench.sh. Measured on
# shard-150: 40 MB of corpus compresses to 29.8 MB, a 25% saving, and gzip -1
# manages ~47 MB/s on one core -- rsync's default level 6 is far slower. On a
# link faster than the compressor that trades a 25% smaller payload for a CPU
# bottleneck. COMPRESS=1 turns it on at level 1 for genuinely slow links.
rsync_opts=(-a --timeout=120 --info=progress2)
if [ "${COMPRESS:-0}" = 1 ]; then
  rsync_opts+=(-z --compress-level=1)
fi

# --partial-dir, NOT the --partial that push-bench.sh uses.  Both launch modes
# admit a shard on nothing but its existence (backend/gpu/Main.hs:828,
# deploy/train-cloud.sh:121), and that is only safe if a name appears when the
# file is whole.
#
# MEASURED, 400 MB shard over a throttled link interrupted with SIGINT:
#   --partial      -> 59,834,368 bytes sitting under the FINAL name
#   --partial-dir  -> final name absent, 59,277,312 bytes held in .rsync-partial
# The first is a corpus the trainer would happily open.  loadCorpus validates,
# so it is a crash rather than silent corruption -- but it crash-loops against
# watch-cloud-training.sh until the transfer finishes.  (Under SIGKILL neither
# leaves a final name, because the receiver never gets to finalize; a dropped
# peer, which is the failure these boxes actually exhibit, behaves like the
# graceful case.)  --partial-dir keeps resume data and the atomic rename both.
rsync_opts+=(--partial-dir=.rsync-partial)

retry_rsync() {
  local attempt=1
  until rsync "${rsync_opts[@]}" -e "$ssh_cmd" "$@"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 8 ]; then
      echo "push-corpus: transfer failed after 8 attempts" >&2
      return 1
    fi
    echo "push-corpus: interrupted, resuming ($attempt/8)..." >&2
    sleep 5
  done
}

# The acceptance test is the byte count on the box, never rsync's exit status:
# rsync has reported success on a missing file through a pipeline before.
verify_remote() { # $1 = local path, $2 = remote path
  local expected actual
  expected=$(stat -c %s "$1")
  actual=$($ssh_cmd "$host" "stat -c %s '$2' 2>/dev/null || echo 0" | tr -d '\r')
  if [ "$expected" != "$actual" ]; then
    echo "push-corpus: $2 is $actual bytes on the box, expected $expected" >&2
    return 1
  fi
}

remote_run="$remote_dir/$run_dir"
remote_tok_dir="$remote_dir/$(dirname "$tokenizer")"
$ssh_cmd "$host" "mkdir -p '$remote_run' '$remote_tok_dir'"

# The plan and the tokenizer go first, so the box can start the moment shard 0
# lands. train-cloud.sh refuses to start without both.
echo "push-corpus: plan + tokenizer -> $remote_run"
retry_rsync "$plan" "$host:$remote_run/"
retry_rsync "$tokenizer" "$host:$remote_tok_dir/"
verify_remote "$plan" "$remote_run/$(basename "$plan")"
verify_remote "$tokenizer" "$remote_tok_dir/$(basename "$tokenizer")"

# One stat sweep for every shard already delivered, rather than a round trip
# per shard. A resumed push then costs one connection, not 304.
# find, not a shell glob: the login shell on the box is not necessarily bash,
# and zsh aborts an unmatched glob with an error instead of passing it through,
# which is exactly the case on a box that has received nothing yet.
declare -A have=()
while read -r name bytes; do
  [ -n "${name:-}" ] || continue
  have["$name"]="$bytes"
done < <($ssh_cmd "$host" \
  "find '$remote_run' -maxdepth 1 -name 'shard-*-$size.corpus' -printf '%f %s\n' 2>/dev/null || true" \
  | tr -d '\r')

sent=0
sent_bytes=0
skipped=0
for k in "${shards[@]}"; do
  local_path="$run_dir/shard-$k-$size.corpus"
  base="shard-$k-$size.corpus"
  bytes=$(stat -c %s "$local_path")

  if [ "${have[$base]:-0}" = "$bytes" ]; then
    skipped=$((skipped + 1))
    sent_bytes=$((sent_bytes + bytes))
    continue
  fi

  if [ "$max_shards" -gt 0 ] && [ "$sent" -ge "$max_shards" ]; then
    echo "push-corpus: reached MAX_SHARDS=$max_shards — stopping."
    break
  fi

  printf 'push-corpus: shard %s (%s of %s, %.1f of %.1f GB)\n' \
    "$k" "$((sent + skipped + 1))" "${#shards[@]}" \
    "$(awk -v b="$sent_bytes" 'BEGIN{print b/1073741824}')" \
    "$(awk -v b="$total_bytes" 'BEGIN{print b/1073741824}')"
  retry_rsync "$local_path" "$host:$remote_run/"
  verify_remote "$local_path" "$remote_run/$base"

  # Say this as soon as the first shard lands, not at the end: the whole point
  # is that training overlaps the remaining hours of transfer.
  if [ "$sent" -eq 0 ]; then
    echo "push-corpus: shard $k has landed — start training now, in another shell:"
    echo "  ssh -p $port $host 'cd $remote_dir && TRAIN_ENV_FILE=deploy/bpe100m.env ./deploy/train-cloud.sh'"
  fi

  sent=$((sent + 1))
  sent_bytes=$((sent_bytes + bytes))
done

echo "push-corpus: done — $sent shard(s) sent, $skipped already present."

cat <<EOF

On the box, if it is not training yet:

  cd $remote_dir
  BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh
  TRAIN_ENV_FILE=deploy/bpe100m.env ./deploy/train-cloud.sh

and from here, so it restarts as later shards land:

  SSH_PORT=$port ./deploy/watch-cloud-training.sh $host
EOF
