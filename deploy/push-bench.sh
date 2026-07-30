#!/usr/bin/env bash
# push-bench.sh — transfer exactly what a benchmark box needs, and nothing else.
#
# The source tree goes to ~/formalTransformer (~35 MB: no run/, no weights/, no
# .git, no build outputs). The corpus shard and tokenizer go to ~/bench-data,
# deliberately OUTSIDE the repo: `nix build` on a non-git tree copies the whole
# working directory into the store, so a 25 MB corpus sitting in run/ would be
# copied on every build.
#
# `bench` needs only the corpus — not the tokenizer, not the plan, not a
# checkpoint. The tokenizer goes along anyway because the step-gate and
# train-segment paths do want it and it costs 471 KB.
#
# usage: ./deploy/push-bench.sh [user@]host [port]
#
# Env:
#   SHARD     corpus shard to send (default run/mixed-bpe100m/shard-0-bpe100m.corpus)
#   TOKENIZER .bpe artifact        (default run/enwiki-fineweb-32k.bpe)
#   REMOTE_DIR                     (default formalTransformer)
#   DATA_DIR                       (default bench-data)
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 [user@]host [port]" >&2
  exit 1
fi

host=$1
port=${2:-22}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# A typical mid-corpus shard (44 MB) rather than shard 0 (180 MB): the dump is
# article-ordered, so the early shards hold the long articles and are ~4x the
# average. bench only samples windows, so a representative shard is the right
# one and it uploads faster.
shard=${SHARD:-run/mixed-bpe100m-s32000/shard-150-bpe100m.corpus}
tokenizer=${TOKENIZER:-run/enwiki-fineweb-32k.bpe}
remote_dir=${REMOTE_DIR:-formalTransformer}
data_dir=${DATA_DIR:-bench-data}

test -f "$shard" || { echo "push-bench: shard not found: $shard" >&2; exit 1; }
test -f "$tokenizer" || { echo "push-bench: tokenizer not found: $tokenizer" >&2; exit 1; }

ssh_cmd="ssh -p $port -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# Rented boxes reset long transfers: the rate bursts, collapses, and the peer
# drops the connection partway.  One rsync invocation is therefore not a
# transfer -- --partial keeps what arrived so each attempt resumes, and the
# caller checks the result by size rather than trusting an exit code.
retry_rsync() {
  local attempt=1
  until rsync -az --partial --timeout=120 --info=progress2 -e "$ssh_cmd" "$@"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 8 ]; then
      echo "push-bench: transfer failed after 8 attempts" >&2
      return 1
    fi
    echo "push-bench: interrupted, resuming ($attempt/8)..." >&2
    sleep 5
  done
}

echo "push-bench: target $host:$port"
echo "push-bench: source tree -> ~/$remote_dir"
retry_rsync \
  --exclude='run/' \
  --exclude='weights/' \
  --exclude='.git/' \
  --exclude='result' \
  --exclude='result-*' \
  --exclude='dist-newstyle/' \
  --exclude='_build/' \
  --exclude='data/' \
  --exclude='.direnv/' \
  --exclude='.claude/' \
  ./ "$host:$remote_dir/"

echo "push-bench: corpus + tokenizer -> ~/$data_dir"
$ssh_cmd "$host" "mkdir -p '$data_dir'"
# Rented links drop mid-transfer often enough that one attempt is not a
# transfer.  --partial keeps what arrived so a retry resumes rather than
# restarts, and the size check below is the actual acceptance test: rsync
# exiting 0 through a pipeline has reported success on a missing file before.
retry_rsync "$shard" "$tokenizer" "$host:$data_dir/"

expected=$(stat -c %s "$shard")
actual=$($ssh_cmd "$host" "stat -c %s '$data_dir/$(basename "$shard")' 2>/dev/null || echo 0" | tr -d '\r')
if [ "$expected" != "$actual" ]; then
  echo "push-bench: corpus is $actual bytes on the box, expected $expected" >&2
  exit 1
fi
echo "push-bench: corpus verified ($actual bytes)"

shard_base="$(basename "$shard")"
tokenizer_base="$(basename "$tokenizer")"

cat <<EOF

push-bench: done. On the box:

  cd $remote_dir
  BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh

  # then, with the peak TFLOPS auto-detected for known cards:
  PRICE_PER_HOUR=<the box's \$/hr> \\
    ./deploy/sweep-cuda.sh ~/$data_dir/$shard_base bpe100m

  # tokenizer, if a later step wants it:
  #   TOKENIZER_FILE=~/$data_dir/$tokenizer_base

Pull the results back with:

  rsync -avz -e 'ssh -p $port' \\
    '$host:$remote_dir/run/sweep-*.tsv' '$host:$remote_dir/run/sweep-logs' \\
    run/sweep-results-$(echo "$host" | tr -cd 'A-Za-z0-9.-')/
EOF
